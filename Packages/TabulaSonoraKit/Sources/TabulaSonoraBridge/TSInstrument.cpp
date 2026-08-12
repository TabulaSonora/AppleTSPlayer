#include "TSInstrument.hpp"

#include <algorithm>
#include <cmath>
#include <span>

namespace ts::apple {

namespace {

/// Four-point cubic interpolation, the Catmull-Rom form.
///
/// The engine's output is already band-limited well inside 16 kHz, so going up to 44.1 or 48 kHz
/// asks nothing of the kernel beyond not adding anything of its own -- there is no image to filter
/// out that the module did not already leave behind. A host running *below* 32 kHz is the case this
/// does not cover: the fold-back would need a decimating filter, and no host does it.
inline float interpolate(const float* frames, float fraction) noexcept
{
    const float y0 = frames[0];
    const float y1 = frames[1];
    const float y2 = frames[2];
    const float y3 = frames[3];

    const float c1 = 0.5F * (y2 - y0);
    const float c2 = y0 - (2.5F * y1) + (2.0F * y2) - (0.5F * y3);
    const float c3 = (0.5F * (y3 - y0)) + (1.5F * (y1 - y2));

    return (((((c3 * fraction) + c2) * fraction) + c1) * fraction) + y1;
}

} // namespace

Instrument::Instrument()
    : session_{std::make_unique<Session>()}
{
    // A rate and a block the host will replace at `allocateRenderResources`. Sized now so an
    // instance that is rendered before it is prepared -- which should not happen, and does -- has
    // buffers rather than a null pointer.
    prepare(engine_rate, 4096);
}

Instrument::~Instrument() = default;

void Instrument::load_rom(const std::string& path, bool verify_fully)
{
    // A whole second session, built with no lock held. The 27 MB of tables and the parse that reads
    // them are the entire cost of this call, and holding the render thread out for it would be
    // heard as the plugin dying at the moment it was inserted.
    TSEngineSettings wanted;
    int rate = 0;
    {
        const std::lock_guard<std::mutex> guard{lock_};
        wanted = settings_;
        rate = static_cast<int>(output_rate_);
    }

    auto next = std::make_unique<Session>();
    next->set_settings(wanted);

    // Carried onto the new session, which starts at the engine's own rate and would otherwise
    // stamp live messages against it. A host prepares long before the tables have finished
    // reading, so by the time this runs the rate is known and the session that will answer for it
    // does not exist yet.
    next->set_host_rate(rate);

    next->load_rom(path, verify_fully);

    std::unique_ptr<Session> previous;
    {
        const std::lock_guard<std::mutex> guard{lock_};
        previous = std::move(session_);
        session_ = std::move(next);
        has_rom_.store(session_->has_rom(), std::memory_order_relaxed);
    }
    // Outside the lock: freeing the outgoing tables is the same 27 MB going the other way.
}

void Instrument::set_settings(const TSEngineSettings& settings)
{
    const std::lock_guard<std::mutex> guard{lock_};
    settings_ = settings;
    session_->set_settings(settings);
    event_frames_.store(session_->event_latency_frames(), std::memory_order_relaxed);
    gain_.store(settings.outputGain, std::memory_order_relaxed);
    gain_changed_.store(false, std::memory_order_release);
}

TSEngineSettings Instrument::settings() const
{
    const std::lock_guard<std::mutex> guard{lock_};
    return settings_;
}

std::string Instrument::rom_name() const
{
    const std::lock_guard<std::mutex> guard{lock_};
    return session_->rom_name();
}

void Instrument::prepare(double output_rate, std::uint32_t max_frames)
{
    const std::lock_guard<std::mutex> guard{lock_};

    output_rate_ = output_rate > 0.0 ? output_rate : engine_rate;
    ratio_ = static_cast<double>(engine_rate) / output_rate_;

    // The worst case for one block: the read position starts just short of 2, walks `max_frames`
    // steps of `ratio_`, and the interpolator wants a frame past the end of that. The slack covers
    // the rounding rather than being a guess.
    const double span = 2.0 + (static_cast<double>(max_frames) * ratio_);
    const std::size_t capacity = static_cast<std::size_t>(span) + history + 4;

    input_left_.assign(capacity, 0.0F);
    input_right_.assign(capacity, 0.0F);
    position_ = 1.0;

    // The module's stage, for when it is the one converting, and the rate the generator stamps
    // live messages against. Both are construction-time facts, which is why they are set here and
    // not per block; `set_host_rate` rebuilds the generator when the rate actually moves.
    filter_.set_host_rate(static_cast<int>(output_rate_));
    filter_.reset();
    filter_primed_ = false;

    session_->set_host_rate(static_cast<int>(output_rate_));
    event_frames_.store(session_->event_latency_frames(), std::memory_order_relaxed);
}

double Instrument::latency_seconds() const noexcept
{
    // What the resampler costs, and the two cost different amounts.
    //
    // Measured rather than derived, by where a note's first sound lands: render one note and find
    // the first non-zero output frame, at 32, 44.1 and 48 kHz. In engine frames the answer is flat
    // across the three -- 133 for the Hermite, 130 for the module's stage -- of which 128 is the
    // engine's own event pipeline, four chunks of 32 that both paths sit behind and that this has
    // never reported.
    //
    // So the Hermite is five frames and the module's stage two. The two are the priming frame the
    // filter needs before it can interpolate at all, and the frame it reads behind: its output
    // frame `n` is at input position `n * ratio - 1`, at every ratio. The Hermite's five are its
    // four carried frames and the generator's own copy of the output filter, which runs at 1:1 in
    // that mode and is a sample of delay.
    //
    // Reported because an unreported delay is how a plugin drifts against a click, and the figure
    // was one frame for both until the two paths existed to be told apart.
    //
    // The larger of the two rather than whichever is running, because `AUAudioUnit.latency` says a
    // latency that moves with a parameter "is generally not useful to hosts" -- a host adds its
    // delay once, before it starts rendering, and is not prepared to track a change. Three frames,
    // a tenth of a millisecond, is not worth handing a host something it cannot use. The module's
    // stage is therefore declared two frames later than it is.
    constexpr double resampler = 5.0;

    // And the 128 as well, which no version of this declared. Both paths sit behind the module's
    // event staging and so does the module, so a host that compensates for it puts this plugin
    // where the hardware would be; leaving it out is what made a bounce land four milliseconds
    // late against everything that was compensated.
    const auto staged = static_cast<double>(event_frames_.load(std::memory_order_relaxed));

    // Not counted, and not fixable: the generator renders in whole 32-frame chunks and hands out
    // what was asked for, so between calls it holds what is left of the last one -- audio computed
    // before any event that has since arrived, and which no event can now reach. Measured at 32
    // kHz, a note sent between calls sounds after a flat 133 frames when the host's block is a
    // multiple of 32, and anywhere from 133 to 164 when it is not.
    //
    // Off the engine's own rate there is no block size that avoids it: 512 frames at 44.1 kHz want
    // 371.5 of input. Pulling in multiples of 32 and keeping the surplus here does not help either,
    // because the surplus is the same already-rendered audio, merely held on this side of the
    // generator -- it would make `buffered_frames` read zero while changing nothing audible.
    //
    // It is the module's own millisecond event grid, which `drain_events` runs on there too, so it
    // is inherited rather than introduced. Under 1 ms, one-sided, and jitter rather than offset,
    // which a fixed delay cannot compensate for anyway.
    return (staged + resampler) / static_cast<double>(engine_rate);
}

void Instrument::pull(std::size_t offset, std::size_t frames)
{
    if (frames == 0) {
        return;
    }

    // `render_live`, not `render`: there is no song here and never will be, and the sequencer path
    // would step a transport that does not exist.
    session_->render_live(std::span<float>{input_left_.data() + offset, frames},
                          std::span<float>{input_right_.data() + offset, frames});
}

void Instrument::render_through_module(float* left, float* right, std::uint32_t frames) noexcept
{
    // The module's arrangement: one output stage, running at the ratio between the engine's rate
    // and the host's, pulling a 32 kHz frame whenever the phase says it needs one. The generator's
    // own copy of this filter is bypassed while this runs -- see `Session::options`.
    //
    // Input comes a frame at a time rather than a block at a time, which is not how the generator
    // likes to be asked, so it is pulled into the front of the same buffer the Hermite path uses.
    // A frame costs a call into the session; the alternative is a second buffer and a count of
    // what is left in it, and this path exists to be compared against the module rather than to be
    // the fast one.
    for (std::uint32_t frame = 0; frame < frames; ++frame) {
        if (!filter_primed_) {
            pull(0, 1);
            filter_.push(input_left_[0], input_right_[0]);
            filter_primed_ = true;
        }

        const auto [out_left, out_right] = filter_.at();
        left[frame] = out_left;
        right[frame] = out_right;

        for (int wanted = filter_.advance(); wanted > 0; --wanted) {
            pull(0, 1);
            filter_.push(input_left_[0], input_right_[0]);
        }
    }

    voices_.store(session_->active_voices(), std::memory_order_relaxed);
    capacity_.store(session_->voice_capacity(), std::memory_order_relaxed);
    xg_.store(session_->xg_mode(), std::memory_order_relaxed);
}

void Instrument::render(float* left, float* right, std::uint32_t frames) noexcept
{
    if (frames == 0) {
        return;
    }

    const auto silence = [&] {
        std::fill_n(left, frames, 0.0F);
        std::fill_n(right, frames, 0.0F);
    };

    const std::unique_lock<std::mutex> guard{lock_, std::try_to_lock};
    if (!guard.owns_lock()) {
        // A rebuild is in progress. One block of silence, and it is the same block whose voices the
        // rebuild was going to take anyway.
        silence();
        return;
    }

    if (gain_changed_.exchange(false, std::memory_order_acquire)) {
        session_->set_output_gain(gain_.load(std::memory_order_relaxed));
    }

    if (!settings_.extendedOutputResampler) {
        render_through_module(left, right, frames);
        return;
    }

    const double last = position_ + (static_cast<double>(frames - 1) * ratio_);
    const double end = position_ + (static_cast<double>(frames) * ratio_);

    // Two demands on the input, and the larger wins: the last output frame interpolates over
    // `floor(last) - 1` to `floor(last) + 2`, so the buffer has to reach the last of those; and
    // the next call must start reading at a position of at least 1 once the tail has been shifted
    // to the front, which bounds how far ahead this call may pull.
    const std::size_t required = std::max(static_cast<std::size_t>(last) + 3,
                                          static_cast<std::size_t>(end) + history - 1);

    if (required > input_left_.size()) {
        // The host asked for more than it declared as its maximum. Nothing to do but stay silent;
        // growing the buffer here is the one thing an audio thread must not do.
        silence();
        return;
    }

    pull(history, required - history);

    for (std::uint32_t frame = 0; frame < frames; ++frame) {
        const double read = position_ + (static_cast<double>(frame) * ratio_);
        const auto index = static_cast<std::size_t>(read);
        const auto fraction = static_cast<float>(read - static_cast<double>(index));

        left[frame] = interpolate(input_left_.data() + index - 1, fraction);
        right[frame] = interpolate(input_right_.data() + index - 1, fraction);
    }

    // What the panel shows, published rather than asked for -- see the comment on `has_rom`.
    voices_.store(session_->active_voices(), std::memory_order_relaxed);
    capacity_.store(session_->voice_capacity(), std::memory_order_relaxed);
    xg_.store(session_->xg_mode(), std::memory_order_relaxed);

    // Carry the last frames the engine produced to the front, and bring the read position back
    // with them, so the buffer never has to be longer than one block.
    //
    // `required - history`, and nothing else: the engine's output is a stream, and whatever is not
    // carried here is never seen again. Taking the tail from `floor(end) - 1` instead is right only
    // when the block ends past an input frame boundary; when it does not -- which at 44.1 kHz is
    // about a quarter of blocks, and more the higher the host's rate -- it leaves the last frame
    // pulled behind, and the next call resumes one frame further on than it should. One sample of
    // the engine's output dropped, tens of times a second, which on a sustained note is heard as a
    // steady clicking. It is inaudible in the app because nothing resamples there: the graph runs
    // at the engine's own rate and CoreAudio's mixer does the conversion.
    const std::size_t shift = required - history;
    std::copy_n(input_left_.begin() + static_cast<std::ptrdiff_t>(shift), history,
                input_left_.begin());
    std::copy_n(input_right_.begin() + static_cast<std::ptrdiff_t>(shift), history,
                input_right_.begin());
    position_ = end - static_cast<double>(shift);
}

void Instrument::send_channel(int port, int status, int data1, int data2) noexcept
{
    const std::unique_lock<std::mutex> guard{lock_, std::try_to_lock};
    if (!guard.owns_lock()) {
        return;
    }
    session_->send_channel(port, status, data1, data2);
}

void Instrument::send_sysex(int port, const std::uint8_t* bytes, std::size_t size) noexcept
{
    if (bytes == nullptr || size == 0) {
        return;
    }

    const std::unique_lock<std::mutex> guard{lock_, std::try_to_lock};
    if (!guard.owns_lock()) {
        return;
    }
    session_->send_sysex(port, std::span<const std::uint8_t>{bytes, size});
}

void Instrument::set_output_gain(double gain) noexcept
{
    gain_.store(gain, std::memory_order_relaxed);
    gain_changed_.store(true, std::memory_order_release);
}

} // namespace ts::apple
