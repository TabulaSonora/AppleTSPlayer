#include "TSPlayer.hpp"

#include <pthread.h>

#include <algorithm>
#include <chrono>
#include <utility>

namespace ts::apple {

namespace {

/// Sized once, for the largest lead that can ever be asked for.
///
/// The lead is adjustable but the ring is not: reallocating it would mean swapping the buffer the
/// audio callback is reading from, and there is no safe moment to do that. Sizing for the maximum
/// and moving the target fill inside it costs a few hundred kilobytes and no synchronisation at all.
std::size_t ring_frames()
{
    const auto largest = std::max<std::int64_t>(
        static_cast<std::int64_t>(Player::block_frames) * 4,
        static_cast<std::int64_t>(Player::max_latency_ms) * Session::sample_rate / 1000);
    return 2 * static_cast<std::size_t>(largest);
}

} // namespace

Player::Player() : ring_(ring_frames())
{
    midi_inbox_.reserve(256);

    // Nothing is loaded yet, so an empty ring is intended rather than a fault.
    ring_.set_starvation_expected(true);

    renderer_ = std::thread{[this] { run(); }};
}

Player::~Player()
{
    quit_.store(true, std::memory_order_relaxed);
    if (renderer_.joinable()) {
        renderer_.join();
    }
}

void Player::load_rom(const std::string& path, bool verify_fully)
{
    // Both, and in this order: an export borrows the note renderer this is about to replace, so it
    // has to finish first. Every path that takes both takes them this way round.
    const std::lock_guard<std::mutex> exporting{export_lock_};
    const std::lock_guard<std::mutex> guard{lock_};
    session_.load_rom(path, verify_fully);
    publish();
}

void Player::load_song(const std::string& path)
{
    const std::lock_guard<std::mutex> guard{lock_};
    session_.load_song(path);
    pending_seek_ = 0;
    audible_.store(0, std::memory_order_relaxed);
    publish();
}

void Player::unload_song()
{
    const std::lock_guard<std::mutex> guard{lock_};
    session_.unload_song();
    audible_.store(0, std::memory_order_relaxed);
    publish();
}

void Player::set_settings(const TSEngineSettings& settings)
{
    const std::lock_guard<std::mutex> guard{lock_};
    session_.set_settings(settings);
    publish();
}

void Player::set_looping(bool looping)
{
    const std::lock_guard<std::mutex> guard{lock_};
    session_.set_looping(looping);
    publish();
}

void Player::seek(std::int64_t frame)
{
    const std::lock_guard<std::mutex> guard{lock_};
    pending_seek_ = std::max<std::int64_t>(0, frame);
}

void Player::panic()
{
    const std::lock_guard<std::mutex> guard{lock_};
    session_.panic();
}

void Player::set_paused(bool paused)
{
    // While paused the ring is meant to run dry, so the consumer must not count that as an
    // underrun -- the display would fill with faults that are just a stopped transport.
    //
    // Unpausing deliberately does *not* clear the flag. The ring is empty at that moment and the
    // render thread has not had a block's notice, so the first callbacks would come up short and be
    // counted as dropouts -- one every time the user pressed Play. The render loop clears it once
    // the ring is half full, which is the same prefill upstream does before starting its device.
    if (paused) {
        ring_.set_starvation_expected(true);
    }
    paused_.store(paused, std::memory_order_relaxed);
}

void Player::set_latency_ms(int milliseconds) noexcept
{
    const int clamped = std::clamp(milliseconds, min_latency_ms, max_latency_ms);
    lead_frames_.store(clamped * Session::sample_rate / 1000, std::memory_order_relaxed);
}

int Player::latency_ms() const noexcept
{
    return lead_frames_.load(std::memory_order_relaxed) * 1000 / Session::sample_rate;
}

std::string Player::rom_name() const
{
    const std::lock_guard<std::mutex> guard{lock_};
    return session_.rom_name();
}

std::string Player::song_name() const
{
    const std::lock_guard<std::mutex> guard{lock_};
    return session_.song_name();
}

void Player::export_wav(const std::string& path, const std::function<bool(double)>& progress)
{
    // Held for the whole export, and it is what keeps the borrowed note renderer alive; `lock_` is
    // taken only long enough to lift the plan out. Holding `lock_` across the render instead would
    // block the render thread for the length of the export -- which is to say, stop the audio.
    const std::lock_guard<std::mutex> exporting{export_lock_};

    Session::ExportPlan plan;
    {
        const std::lock_guard<std::mutex> guard{lock_};
        plan = session_.plan_export();
    }

    Session::run_export(plan, path, progress);
}

void Player::set_muted(int part, bool muted)
{
    session_.set_muted(part, muted);
}

void Player::set_soloed(int part, bool soloed)
{
    session_.set_soloed(part, soloed);
}

void Player::reset_channels()
{
    session_.reset_channels();
}

void Player::send_channel(int port, int status, int data1, int data2)
{
    const std::lock_guard<std::mutex> guard{midi_lock_};
    // Bounded rather than growing: a source that outruns the render thread this badly is broken,
    // and dropping the newest message is better than letting a MIDI callback allocate.
    if (midi_inbox_.size() < 4096) {
        midi_inbox_.push_back({port, status, data1, data2});
    }
}

SessionSnapshot Player::snapshot() const
{
    const std::lock_guard<std::mutex> guard{snapshot_lock_};
    return snapshot_;
}

void Player::publish()
{
    SessionSnapshot taken;
    session_.capture(taken);

    taken.paused = paused_.load(std::memory_order_relaxed);
    taken.position = audible_.load(std::memory_order_relaxed);
    taken.underruns = ring_.underruns();
    const auto [left, right] = ring_.peak();
    taken.peakLeft = left;
    taken.peakRight = right;

    const std::lock_guard<std::mutex> guard{snapshot_lock_};
    snapshot_ = std::move(taken);
}

void Player::run()
{
    pthread_setname_np("co.losno.tabula-sonora.render");

    // High, but deliberately not real-time: this thread renders whole blocks and may take a lock,
    // which is precisely what a real-time thread must not do. The audio callback below it is the
    // one with the hard deadline, and the ring is what buys it that freedom.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);

    std::vector<float> left(block_frames, 0.0F);
    std::vector<float> right(block_frames, 0.0F);
    std::vector<float> block(static_cast<std::size_t>(block_frames) * 2, 0.0F);
    std::vector<MidiMessage> midi;
    midi.reserve(256);

    int until_publish = 0;

    while (!quit_.load(std::memory_order_relaxed)) {
        // How long to wait before looking again, decided under the lock and slept *outside* it.
        // Sleeping while holding it would make an idle transport hold the session almost
        // continuously, and every control call would queue behind a nap it has nothing to do with.
        std::chrono::microseconds nap{0};

        {
            {
                const std::lock_guard<std::mutex> inbox{midi_lock_};
                midi.swap(midi_inbox_);
                midi_inbox_.clear();
            }

            const std::lock_guard<std::mutex> guard{lock_};

            for (const auto& message : midi) {
                session_.send_channel(message.port, message.status, message.data1, message.data2);
            }
            midi.clear();

            if (pending_seek_) {
                // Drop what is queued so the new position is heard now rather than a ring's worth
                // of audio later. The consumer performs the drop; nothing may be written until it
                // has.
                ring_.set_starvation_expected(true);
                ring_.request_flush();
                session_.seek(*pending_seek_);
                audible_.store(session_.position(), std::memory_order_relaxed);
                pending_seek_.reset();
            }

            const bool idle = paused_.load(std::memory_order_relaxed) || !session_.has_rom()
                              || session_.complete();

            const auto lead = static_cast<std::size_t>(lead_frames_.load(std::memory_order_relaxed));

            if (idle) {
                // Re-armed every iteration while idle, not once on the way in. Pausing leaves a
                // lead's worth of audio still queued, so a single set on the way in was undone by
                // the clear below on the very next pass -- and then the ring drained into a
                // callback that counted every empty block as a fault. A paused transport is the
                // one time an empty ring is exactly what was asked for.
                ring_.set_starvation_expected(true);
            } else if (ring_.queued() >= lead / 2) {
                // Half the lead is enough to call the ring primed: waiting for all of it would
                // leave the flag set through the first blocks after Play, which is exactly when
                // the callback is most likely to arrive early.
                ring_.set_starvation_expected(false);
            }

            if (ring_.flush_pending()) {
                nap = std::chrono::microseconds{500};
            } else if (idle) {
                nap = std::chrono::milliseconds{10};
            } else if (ring_.queued() >= lead
                       || ring_.writable() < static_cast<std::size_t>(block_frames)) {
                // The lead is reached, so wait rather than run further ahead. Napping for a
                // fraction of a block keeps the thread responsive to a seek without spinning.
                nap = std::chrono::microseconds{block_frames * 1000000 / Session::sample_rate / 4};
            } else {

                session_.render(left, right);

                // Interleaved into the ring, which is what the callback copies out of in one pass.
                for (int frame = 0; frame < block_frames; ++frame) {
                    const auto at = static_cast<std::size_t>(frame);
                    block[at * 2] = left[at];
                    block[at * 2 + 1] = right[at];
                }
                ring_.write(block);

                audible_.store(session_.position() - static_cast<std::int64_t>(ring_.queued()),
                               std::memory_order_relaxed);
            }

            // Roughly every 20 ms of audio: far finer than any display refresh, and cheap against
            // a block of synthesis.
            if (--until_publish <= 0) {
                publish();
                until_publish = std::max(1, Session::sample_rate / 50 / block_frames);
            }
        }

        if (nap.count() > 0) {
            std::this_thread::sleep_for(nap);
        }
    }
}

} // namespace ts::apple
