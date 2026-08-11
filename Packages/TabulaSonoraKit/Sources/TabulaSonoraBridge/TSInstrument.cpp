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
    {
        const std::lock_guard<std::mutex> guard{lock_};
        wanted = settings_;
    }

    auto next = std::make_unique<Session>();
    next->set_settings(wanted);
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
}

double Instrument::latency_seconds() const noexcept
{
    // One input frame: the interpolator reads a frame ahead of the pair it sits between. Small
    // enough to be a rounding error in any host, and reported because an unreported delay is how
    // a plugin drifts against a click.
    return 1.0 / static_cast<double>(engine_rate);
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

    const double last = position_ + (static_cast<double>(frames - 1) * ratio_);
    const double end = position_ + (static_cast<double>(frames) * ratio_);

    // Two demands on the input, and the larger wins: the last output frame interpolates between
    // `last` and the frame after it, and the tail carried into the next call starts one frame
    // before `end`.
    const std::size_t highest = std::max(static_cast<std::size_t>(last) + 2,
                                         static_cast<std::size_t>(end) + 1);
    const std::size_t required = highest + 1;

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

    // Carry the three frames straddling the next read position to the front, and bring the position
    // back into [1, 2) with them, so the buffer never has to be longer than one block.
    const std::size_t shift = static_cast<std::size_t>(end) - 1;
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
