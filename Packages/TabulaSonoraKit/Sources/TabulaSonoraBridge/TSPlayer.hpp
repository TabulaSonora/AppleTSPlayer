#pragma once

#include "TSSession.hpp"

#include "tabulasonora/frame_ring.hpp"

#include <atomic>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace ts::apple {

/// A session, a render thread and a ring, wired together.
///
/// The division of labour is the whole point, and it is upstream's: the render thread pulls blocks
/// from the session and writes them to a ring; the audio callback copies out of that ring and does
/// nothing else -- no allocation, no lock, no engine code. A slow block eats into the ring's lead
/// rather than glitching the device.
///
/// Two different boundaries meet here, and they are deliberately not the same mechanism:
///
///  - **Control** (load, settings, seek, transport) takes `lock_`, which the render thread also
///    holds while it renders a block. These are rare, they allocate, and they can throw, so a
///    mutex is the honest tool. It is safe *because* the render thread is not the audio callback.
///  - **Live MIDI** goes into a small inbox under its own mutex, held only long enough to append,
///    and swapped out wholesale once per block. A MIDI source must never wait on a block render.
///
/// Mute and solo take neither: `ChannelMask`'s flags are atomic exactly so a mixer can change them
/// while sound is running.
class Player {
public:
    /// Frames the render thread produces at a time.
    ///
    /// 128 frames is 4 ms at 32 kHz, which sets how finely the lead below can be controlled -- and
    /// how promptly a live note can reach the ring, since a block is the smallest unit the engine
    /// renders on this side of the MIDI inbox.
    static constexpr int block_frames = 128;

    /// How far ahead of the device the ring is kept, in milliseconds.
    ///
    /// The floor is the ring's own granularity; the ceiling is what it was sized for. Lower means
    /// a live keyboard answers sooner and a seek is heard sooner, at the cost of less room for the
    /// render thread to be descheduled in.
    static constexpr int min_latency_ms = 10;
    static constexpr int max_latency_ms = 400;

    /// A default chosen to be heard, not to be safe: the engine renders an order of magnitude
    /// faster than realtime, so the lead is covering scheduling jitter rather than synthesis.
    static constexpr int default_latency_ms = 40;

    Player();
    ~Player();

    Player(const Player&) = delete;
    Player& operator=(const Player&) = delete;
    Player(Player&&) = delete;
    Player& operator=(Player&&) = delete;

    /// What the audio callback is handed: the ring, and somewhere to report how much it asked
    /// for. The size of a device block is not ours to choose and does not stay put -- iOS enlarges
    /// it when the screen sleeps -- so the producer learns it from the consumer rather than
    /// guessing.
    struct RingHandle {
        FrameRing* ring;
        /// Frames the callback last asked for. Written by the callback, read by the render thread.
        std::atomic<std::uint32_t> last_request{0};
    };

    /// Stable for the life of the player.
    [[nodiscard]] RingHandle& handle() noexcept { return handle_; }
    [[nodiscard]] FrameRing& ring() noexcept { return ring_; }

    /// Joins the render thread to the audio device's workgroup.
    ///
    /// Without this the thread is scheduled as an ordinary high-priority thread, and the moment the
    /// system decides nothing is urgent -- an iOS device with its screen off -- it stops being
    /// scheduled in time to keep the ring fed, while the callback goes on running to its deadline.
    /// Joining is what tells the scheduler this thread has that same deadline.
    ///
    /// Safe to call repeatedly; the thread joins at its next block and leaves whatever it was in.
    /// Pass nullptr when the device goes away.
    ///
    /// Takes `void*` rather than `os_workgroup_t` on purpose. Under ARC that type is an
    /// Objective-C object and in plain C++ it is a struct pointer, so a header shared by a .mm and
    /// a .cpp would declare two different functions and the link would fail. The cast happens on
    /// each side, where the type is unambiguous.
    void set_workgroup(void* workgroup) noexcept;

    // -- Control. Safe from any one controlling thread; these may block briefly and may throw. --

    void load_rom(const std::string& path, bool verify_fully);
    void load_song(const std::string& path);
    void unload_song();
    void set_settings(const TSEngineSettings& settings);
    void set_looping(bool looping);
    void seek(std::int64_t frame);
    void panic();

    void set_paused(bool paused);
    [[nodiscard]] bool paused() const noexcept { return paused_.load(std::memory_order_relaxed); }

    /// How far ahead of the device to render, in milliseconds. Clamped to the range above.
    ///
    /// Takes effect at the render thread's next block and never reallocates: the ring is sized once
    /// for `max_latency_ms`, and this moves the fill the producer aims for inside it. Lowering it
    /// leaves the ring over-full for one lead's worth of audio, which drains rather than glitches.
    void set_latency_ms(int milliseconds) noexcept;
    [[nodiscard]] int latency_ms() const noexcept;

    [[nodiscard]] std::string rom_name() const;
    [[nodiscard]] std::string song_name() const;

    /// What the loaded file says about itself. Copied out under the lock, like every other control
    /// call: it is static for the life of a song, so nothing about it belongs on the display tick.
    [[nodiscard]] SongInfo song_info() const;

    /// Renders the loaded song to a WAV file. Runs on the calling thread, over a second generator,
    /// while playback continues.
    void export_wav(const std::string& path, const std::function<bool(double)>& progress);

    // -- Mute and solo. Lock-free by way of ChannelMask's atomics. --

    void set_muted(int part, bool muted);
    void set_soloed(int part, bool soloed);
    void reset_channels();

    // -- Live MIDI. Never blocks on a block render. --

    void send_channel(int port, int status, int data1, int data2);

    /// The render thread's most recent look at the engine.
    [[nodiscard]] SessionSnapshot snapshot() const;

private:
    void run();
    void publish();

    Session session_;
    FrameRing ring_;

    /// Guards `session_`, which the render thread owns between blocks.
    mutable std::mutex lock_;

    /// Held for the length of an export, which borrows the note renderer. Anything that would
    /// replace the renderer takes this first, then `lock_`; never the other way round.
    std::mutex export_lock_;

    struct MidiMessage {
        int port;
        int status;
        int data1;
        int data2;
    };

    mutable std::mutex midi_lock_;
    std::vector<MidiMessage> midi_inbox_;

    mutable std::mutex snapshot_lock_;
    SessionSnapshot snapshot_;

    std::optional<std::int64_t> pending_seek_;

    std::atomic<bool> quit_{false};
    std::atomic<bool> paused_{true};

    /// Frames the producer keeps queued. Read every block by the render thread, set from anywhere.
    std::atomic<int> lead_frames_{default_latency_ms * Session::sample_rate / 1000};

    RingHandle handle_{&ring_, {}};

    /// The workgroup the render thread should be in, guarded by `lock_` and retained while stored.
    /// An `os_workgroup_t`, held as `void*` for the reason given on `set_workgroup`.
    void* wanted_workgroup_ = nullptr;

    /// What is *audible*: the session's position less what is still queued in the ring.
    std::atomic<std::int64_t> audible_{0};

    std::thread renderer_;
};

} // namespace ts::apple
