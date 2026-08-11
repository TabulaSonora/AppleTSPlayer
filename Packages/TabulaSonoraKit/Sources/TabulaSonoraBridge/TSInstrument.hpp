#pragma once

#include "TSSession.hpp"

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace ts::apple {

/// A session driven from a plugin's render block, with no render thread and no ring.
///
/// A sibling of `Player`, not a variation on it, because a plugin's problem is the opposite one.
/// The app owns its device: a render thread can run ahead at wall-clock rate and a ring absorbs
/// whatever jitter the callback has. A plugin owns nothing. Its host calls it when it likes, for
/// whatever block size it likes, and during a bounce it calls far faster than realtime -- which a
/// free-running producer cannot follow, so a ring between the two would render silence for exactly
/// the operation people most need to come out right.
///
/// So the engine runs *on the host's audio thread*, in the render block, for exactly the frames
/// asked for. That is not a departure from the threading contract; it is the same contract with a
/// different thread named. `ToneGenerator` wants one owning thread, and here that thread is the
/// host's. Live MIDI arrives on it too -- the render block hands us the events before it asks for
/// the audio between them -- so the inbox and the mutex `Player` needs are simply not needed here.
///
/// What is left needing a lock is control: loading a ROM and changing settings, which come from the
/// UI. Both do their expensive work *outside* the lock, so the render block's `try_lock` finds it
/// free except for the moment a rebuild takes. A miss costs one block of silence, and the only
/// operation that can cause one already resets every sounding voice.
///
/// The engine renders at 32 kHz and a host runs at whatever its device does, so this resamples on
/// the way out -- the one job the app leaves to CoreAudio's mixer and a plugin has to do itself.
class Instrument {
public:
    /// The engine's rate. Everything the session produces is at this rate.
    static constexpr int engine_rate = Session::sample_rate;

    Instrument();
    ~Instrument();

    Instrument(const Instrument&) = delete;
    Instrument& operator=(const Instrument&) = delete;
    Instrument(Instrument&&) = delete;
    Instrument& operator=(Instrument&&) = delete;

    // -- Control. From one controlling thread; these may block briefly and may throw. --

    /// Opens a `SCCore.dll` and builds a whole new session over it, then swaps it in.
    ///
    /// The build is where the 27 MB goes, and it happens with no lock held: a plugin that fell
    /// silent for the second its tables take to read would be reported as a plugin that crashes the
    /// first time it is loaded. Only the swap is inside the lock, and the outgoing session is
    /// destroyed outside it.
    void load_rom(const std::string& path, bool verify_fully);

    /// Rebuilds the generator, under the lock, because there is nothing here to build ahead of
    /// time: the tables stay, only the generator over them is remade, and that is milliseconds.
    void set_settings(const TSEngineSettings& settings);
    [[nodiscard]] TSEngineSettings settings() const;

    [[nodiscard]] std::string rom_name() const;
    [[nodiscard]] bool has_rom() const;

    /// Everything the panel draws, taken under the lock rather than published from the render
    /// thread: there is no render thread here to publish it, and a plugin's UI asks ten times a
    /// second while its audio thread holds the lock for microseconds at a time.
    [[nodiscard]] SessionSnapshot snapshot() const;

    /// Sizes every buffer for a rate and a maximum block, and resets the resampler.
    ///
    /// Called from `allocateRenderResources`, which is the one place a plugin is allowed to
    /// allocate. Nothing below allocates after this.
    void prepare(double output_rate, std::uint32_t max_frames);

    /// What to report as the plugin's latency: the one input frame the interpolator looks ahead by.
    [[nodiscard]] double latency_seconds() const noexcept;

    // -- Real-time. The host's audio thread only, and nothing here blocks, throws or allocates. --

    /// Fills one block at the output rate, resampling from the engine's 32 kHz.
    void render(float* left, float* right, std::uint32_t frames) noexcept;

    void send_channel(int port, int status, int data1, int data2) noexcept;

    /// One complete System Exclusive message, `F0` first and `F7` last, as the engine wants it.
    /// Reassembling it is the caller's job: a host delivers it six bytes at a time and the buffer
    /// that puts it back together belongs where the packets are parsed.
    void send_sysex(int port, const std::uint8_t* bytes, std::size_t size) noexcept;

    /// Takes effect at the top of the next block. An atomic rather than a call into the session,
    /// because a host may set this from its own thread as easily as from an automation event.
    void set_output_gain(double gain) noexcept;

private:
    /// Renders `frames` of engine audio into the input buffers at `offset`, or silence if the lock
    /// could not be taken. Called only with the lock held.
    void pull(std::size_t offset, std::size_t frames);

    std::unique_ptr<Session> session_;

    /// Guards `session_`. Taken with `try_lock` on the audio thread and never held there across
    /// anything that could block.
    mutable std::mutex lock_;

    TSEngineSettings settings_ = TSEngineSettingsDefault();

    /// `engine_rate / output_rate`: input frames consumed per output frame.
    double ratio_ = 1.0;
    double output_rate_ = engine_rate;

    /// Where in the input buffer the next output frame is read from, in [1, 2).
    ///
    /// One ahead of the buffer's start because the interpolator wants a frame either side of the
    /// one it is between: indices 0, 1, 2 are the tail carried from the previous block, and the
    /// fourth point it needs is the first frame of this one.
    double position_ = 1.0;

    /// Interleaved-free: two planar buffers, because that is what the session renders into.
    std::vector<float> input_left_;
    std::vector<float> input_right_;

    /// Frames of history carried between calls -- the three the interpolator needs behind it.
    static constexpr std::size_t history = 3;

    std::atomic<double> gain_{1.0};
    std::atomic<bool> gain_changed_{false};
};

} // namespace ts::apple
