#pragma once

#include "TSTypes.h"

#include "tabulasonora/note_renderer.hpp"
#include "tabulasonora/render_options.hpp"
#include "tabulasonora/rom_image.hpp"
#include "tabulasonora/sequence_player.hpp"
#include "tabulasonora/smf_reader.hpp"
#include "tabulasonora/tone_generator.hpp"

#include <array>
#include <cstdint>
#include <functional>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace ts::apple {

/// One part's state, as of the last block rendered.
struct PartState {
    int program = 0;

    /// Bank select MSB, which carries the variation.
    int bank = 0;

    /// Bank select LSB, which on this module names the vintage: 1-4 pick one and 0 keeps the
    /// configured default. Worth carrying beside the MSB because the pair is what a patch list is
    /// indexed by, and either one alone identifies nothing.
    int bank_lsb = 0;

    int volume = 0;
    int expression = 0;
    int pan = 0x40;
    /// Voices this part is sounding, including any fading after being stolen.
    int voices = 0;
    bool muted = false;
    bool soloed = false;
    /// Whether the loaded song addresses this part at all. A mixer lists these and hides the rest.
    bool present = false;

    /// Whether this part is sounding drums *now* -- not "is this the drum channel". GS can route
    /// any part to the drum path over SysEx and XG does it from bank select alone, so comparing the
    /// channel number to a configured drum channel mislabels both directions.
    bool drums = false;

    /// The kit sounding on a drum part, or -1.
    int kit = -1;

    /// The MIDI channel this part listens on, zero-based -- **not** its slot.
    ///
    /// A mixer row has to be labelled with this. Parts are matched by their receive channel rather
    /// than indexed by it -- `dispatch_channel` walks the list looking for a match, because GS can
    /// point several parts at one channel or detach one from every channel -- so the two agree only
    /// until something moves a part, and a bulk dump moves parts by definition.
    ///
    /// -1 when no engine reported one, which is what a cleared snapshot holds; a row falls back to
    /// its slot rather than every part claiming channel 1. The module's "off" is 16, which is a
    /// part detached from every channel and hearing nothing however much the file sends.
    int rx_channel = -1;

    /// The tone map this part's program resolves against, as `ToneMap`. Per part and per moment:
    /// a bank LSB names a vintage and XG System On moves every part at once.
    int map = 0;

    /// The bank the melodic lookup is given, which is not `bank` under XG.
    int lookupBank = 0;

    /// The sounding instrument's name -- the tone's, or the kit's on a drum part.
    std::string name;
};

/// What the engine was doing when the render thread last looked.
///
/// Taken on the render thread and copied to whoever asks, rather than letting a UI thread walk the
/// engine's own state while it is being written. `ToneGenerator` is single-threaded by contract and
/// this is what keeps that true with a mixer attached.
struct SessionSnapshot {
    bool hasROM = false;
    bool hasSong = false;
    bool paused = true;
    bool looping = false;
    bool complete = false;

    /// Frames, at 32 kHz. What is *audible*, which lags what has been rendered by the ring.
    std::int64_t position = 0;
    std::int64_t length = 0;

    int activeVoices = 0;
    int voiceCapacity = 0;
    int noteCount = 0;
    int drumKit = 0;
    bool xgMode = false;
    int partCount = 16;

    std::int64_t underruns = 0;
    float peakLeft = 0.0F;
    float peakRight = 0.0F;

    std::array<PartState, TS_MAX_PARTS> parts{};
};

/// The engine chain and everything that can be done to it.
///
/// Holds the objects in the order the library builds them -- a `RomImage` over the file, one
/// `NoteRenderer` that loads the tables, a `ToneGenerator` over that, and a `SequencePlayer` over
/// that -- because each borrows the one above. Changing a setting that lives in
/// `ToneGeneratorOptions` rebuilds the generator but *not* the note renderer, so switching vintage
/// or effects costs only the sounding voices.
///
/// Not thread-safe, and does not need to be: `TSPlayer` gives it one owning thread, which is
/// exactly the contract `ToneGenerator` asks for.
class Session {
public:
    static constexpr int sample_rate = ToneGenerator::sample_rate;

    /// Seconds of release and effect tail rendered past the last event.
    static constexpr double tail_seconds = 2.2;

    /// Opens a `SCCore.dll` and builds the engine over it.
    ///
    /// Throws `RomIdentityError` if the file is not the pinned build, or `std::runtime_error` if it
    /// cannot be read. `full` hashes all 27 MB and takes a moment; `quick` checks size and PE
    /// timestamp, which is what a file already verified once needs.
    void load_rom(const std::string& path, bool verify_fully);

    void unload_rom();

    /// Parses a MIDI file and arms it for playback.
    ///
    /// Reads far more than SMF -- RIFF-MIDI, DirectMusic MIDS, DOOM MUS, Miles XMI, GMF, both HMI
    /// containers, Mobile XMF and LDS -- all converted to SMF on the way in. The name rides along
    /// because LDS has no magic and is recognised by it.
    void load_song(const std::string& path);

    void unload_song();

    [[nodiscard]] bool has_rom() const noexcept { return engine_.has_value(); }
    [[nodiscard]] bool has_song() const noexcept { return player_.has_value(); }

    [[nodiscard]] const std::string& rom_name() const noexcept { return rom_name_; }
    [[nodiscard]] const std::string& song_name() const noexcept { return song_name_; }

    /// All the generator settings at once: one rebuild, with part state carried across it.
    void set_settings(const TSEngineSettings& settings);
    [[nodiscard]] const TSEngineSettings& settings() const noexcept { return settings_; }

    /// Whether the song repeats instead of ending, at its own loop points where it declares any.
    void set_looping(bool looping);
    [[nodiscard]] bool looping() const noexcept { return looping_; }

    /// Jumps the song to a position, replaying the controllers up to it.
    void seek(std::int64_t frame);

    [[nodiscard]] std::int64_t position() const noexcept;
    [[nodiscard]] std::int64_t length() const noexcept { return song_length_; }

    /// Whether the song has been rendered past its end plus the tail.
    [[nodiscard]] bool complete() const noexcept;

    /// Silences everything and returns every part to its power-on state.
    void panic();

    /// Stops every sounding note without disturbing anything else.
    ///
    /// All Sound Off (CC 120) on every part, which is the one message defined to silence a part
    /// regardless of whether its sustain pedal is down, and which changes no controller value -- so
    /// unlike `panic` the song can resume into exactly the state it left.
    ///
    /// This is what pausing needs. A paused transport still renders, so that a keyboard stays
    /// playable, but the sequencer is not advancing: any note the song was holding would never
    /// reach its note-off and would sound until the transport started again.
    void silence();

    /// Renders the next block. Live notes sound over a running song, since one generator serves
    /// both. Fills with silence when there is no engine, rather than leaving the caller's buffer
    /// holding the previous block.
    void render(std::span<float> left, std::span<float> right);

    /// Renders the generator alone, leaving the sequencer exactly where it is.
    ///
    /// This is what makes the instrument playable while the transport is stopped. `render` above
    /// goes through the sequence player whenever a song is loaded, so using it would advance the
    /// song: a keyboard could only be heard while a file was playing, and pressing a key would
    /// start the file moving under it.
    void render_live(std::span<float> left, std::span<float> right);

    /// Voices sounding right now, including any still releasing.
    ///
    /// The render thread uses this to decide whether a stopped transport still has something to
    /// render -- a held chord, or the tail of one -- rather than going to sleep on top of it.
    [[nodiscard]] int active_voices() const noexcept;

    /// One channel voice message on a port -- live MIDI and the on-screen keyboard.
    void send_channel(int port, int status, int data1, int data2);

    /// Per-part mute and solo, addressed as `port * 16 + channel`.
    ///
    /// Lives outside the generator so it survives a rebuild, and its flags are atomic, so unlike
    /// everything else here these two are safe to call from another thread.
    void set_muted(int part, bool muted) noexcept { channels_.set_muted(part, muted); }
    void set_soloed(int part, bool soloed) noexcept { channels_.set_soloed(part, soloed); }
    void reset_channels() noexcept { channels_.reset(); }

    /// Fills in everything a redraw needs.
    void capture(SessionSnapshot& into) const;

    /// Everything an export needs, lifted out of the session so the render can run without
    /// holding it.
    ///
    /// The note renderer is borrowed rather than copied -- it is 27 MB of tables and rebuilding it
    /// would defeat the point -- so whoever holds a plan must keep the ROM loaded for its lifetime.
    struct ExportPlan {
        NoteRenderer* notes = nullptr;
        std::vector<MidiEvent> events;
        std::optional<smf::SongLoop> loop;
        ToneGeneratorOptions options;
        std::int64_t total = 0;
    };

    /// Throws `std::runtime_error` if there is nothing to export.
    [[nodiscard]] ExportPlan plan_export() const;

    /// Runs a plan to a WAV file, through a *second* generator over the same note renderer -- so
    /// exporting disturbs nothing that is playing and costs no second read of the tables.
    ///
    /// `progress` is called with a fraction in [0, 1] and returns false to abort.
    static void run_export(const ExportPlan& plan, const std::string& path,
                           const std::function<bool(double)>& progress);

private:
    [[nodiscard]] ToneGeneratorOptions options() const;
    void rebuild();
    void arm_player();
    void restore_parts(const std::vector<std::array<int, 7>>& previous);
    void send_control(int port, int channel, int controller, int value);

    std::optional<RomImage> rom_;
    std::optional<NoteRenderer> notes_;
    std::optional<ToneGenerator> engine_;
    std::optional<SequencePlayer> player_;

    std::string rom_name_;
    std::string song_name_;

    std::vector<MidiEvent> song_events_;
    std::int64_t song_length_ = 0;
    std::optional<smf::SongLoop> song_loop_;
    bool looping_ = false;

    /// Which *channel addresses* the loaded song sends on, as `port * 16 + channel`.
    ///
    /// Channels, not parts, and the distinction is the whole point: which part a channel reaches is
    /// the engine's to answer and changes while the file plays, so this holds the half that is a
    /// property of the file and `capture` asks the engine for the other half.
    std::array<bool, TS_MAX_PARTS> used_channels_{};

    TSEngineSettings settings_ = TSEngineSettingsDefault();
    ChannelMask channels_;
};

} // namespace ts::apple
