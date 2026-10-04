#include "TSSession.hpp"

#include "tabulasonora/patch_directory.hpp"
#include "tabulasonora/sequence.hpp"
#include "tabulasonora/wav_writer.hpp"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <iterator>
#include <stdexcept>

extern "C" TSEngineSettings TSEngineSettingsDefault(void)
{
    const ts::ToneGeneratorOptions defaults;
    TSEngineSettings settings;
    settings.map = static_cast<TSToneMap>(defaults.map);
    settings.polyphony = defaults.polyphony;
    settings.ports = defaults.ports;
    settings.reverb = defaults.reverb;
    settings.chorus = defaults.chorus;
    settings.delay = defaults.delay;
    settings.efx = defaults.efx;
    settings.extendedInterpolation = defaults.extended_interpolation;
    settings.flushBeforeSysEx = defaults.flush_before_sysex;

    // The Hermite here, which keeps the app and the CLI exactly as they were -- neither resamples
    // anyway, so for them this decides nothing but which branch is compiled past. The plugin, which
    // is the only thing that converts, defaults it the other way in its parameter tree.
    settings.extendedOutputResampler = true;

    settings.outputGain = defaults.output_gain;
    return settings;
}

namespace ts::apple {

namespace {

std::string trimmed(std::string_view text)
{
    const auto begin = text.find_first_not_of(" \t");
    if (begin == std::string_view::npos) {
        return {};
    }
    const auto end = text.find_last_not_of(" \t");
    return std::string{text.substr(begin, end - begin + 1)};
}

std::string file_name(const std::string& path)
{
    const auto slash = path.find_last_of('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

} // namespace

void Session::load_rom(const std::string& path, bool verify_fully)
{
    // Built before anything is torn down, so a bad file leaves the running engine alone.
    auto opened = RomImage::open(
        path, verify_fully ? RomVerification::full : RomVerification::quick);

    unload_rom();

    rom_.emplace(std::move(opened));
    notes_.emplace(*rom_);
    rom_name_ = file_name(path);
    rebuild();
}

void Session::unload_rom()
{
    // Reverse of the order they were built in: each borrows the one above it, and a player left
    // holding a pointer into a destroyed generator is the documented way to get this wrong.
    player_.reset();
    engine_.reset();
    notes_.reset();
    rom_.reset();
    rom_name_.clear();
}

void Session::load_song(const std::string& path)
{
    std::ifstream file{path, std::ios::binary};
    if (!file) {
        throw std::runtime_error("Cannot read '" + file_name(path) + "'.");
    }

    const std::vector<std::uint8_t> bytes{std::istreambuf_iterator<char>{file},
                                          std::istreambuf_iterator<char>{}};

    // The name rides along for format detection: LDS has no magic and is recognised by it.
    smf::Song parsed = smf::load(bytes, sample_rate, file_name(path));
    auto events = std::move(parsed.events);

    // Which channel addresses the file sends on. The port is folded exactly as the engine folds it,
    // because a file tagged for four ports playing on a two-port engine lands its port C traffic on
    // port A.
    //
    // Deliberately not "which parts the file touches": a part is reached by matching its receive
    // channel, not by being indexed with it, so the two are the same question only until something
    // moves a part. `capture` turns these channels into strips by asking the engine what is
    // listening to each of them.
    const int ports = std::max(1, settings_.ports);
    used_channels_.fill(false);
    for (const auto& message : events) {
        if (message.kind != MidiEventKind::channel) {
            continue;
        }
        const int address =
            ((message.port & (ports - 1)) * Sequence::channel_count) + message.channel();
        if (address >= 0 && address < TS_MAX_PARTS) {
            used_channels_[static_cast<std::size_t>(address)] = true;
        }
    }

    song_length_ = events.empty() ? 0 : events.back().position;
    song_name_ = file_name(path);
    song_events_ = std::move(events);
    song_loop_ = parsed.loop;
    song_first_note_ = parsed.first_note;

    // Taken from the same bytes, after the parse rather than before it: `smf::load` is what decides
    // whether this file is playable at all, and a file it throws on should not leave a half-filled
    // inspector behind describing something that never loaded.
    song_info_ = read_song_info(bytes, file_name(path));
    song_info_.length = song_length_;
    if (song_loop_) {
        song_info_.has_loop = true;
        song_info_.loop_start = song_loop_->start;
        song_info_.loop_end = song_loop_->end;
        song_info_.loop_soft = song_loop_->soft;
    }

    // Whatever live MIDI set up goes with the reset below: the song is the state from here on.
    live_state_.clear();

    if (engine_) {
        engine_->reset();
        arm_player();
    }
}

void Session::unload_song()
{
    player_.reset();
    song_events_.clear();
    song_name_.clear();
    song_length_ = 0;
    song_loop_.reset();
    song_first_note_ = 0;
    song_info_ = {};
    used_channels_.fill(false);
    live_state_.clear();
    if (engine_) {
        engine_->reset();
    }
}

void Session::set_settings(const TSEngineSettings& settings)
{
    // Gain is live; everything else lives in the construction options and needs a new generator.
    const bool structural = settings.map != settings_.map
                            || settings.polyphony != settings_.polyphony
                            || settings.ports != settings_.ports || settings.reverb != settings_.reverb
                            || settings.chorus != settings_.chorus || settings.delay != settings_.delay
                            || settings.efx != settings_.efx
                            || settings.extendedInterpolation != settings_.extendedInterpolation
                            || settings.flushBeforeSysEx != settings_.flushBeforeSysEx
                            // Not itself a generator setting, but it decides whether the generator
                            // runs its output stage, which is one.
                            || settings.extendedOutputResampler != settings_.extendedOutputResampler;

    settings_ = settings;

    if (!engine_) {
        return;
    }

    if (structural) {
        rebuild();
    } else {
        engine_->set_output_gain(settings_.outputGain);
    }
}

void Session::set_looping(bool looping)
{
    looping_ = looping;
    if (player_) {
        player_->set_loop_count(looping ? -1 : 1);
    }
}

void Session::seek(std::int64_t frame)
{
    if (player_) {
        player_->seek(std::max<std::int64_t>(0, frame));
    }
}

std::int64_t Session::position() const noexcept
{
    if (player_) {
        return player_->position();
    }
    if (engine_) {
        return engine_->position();
    }
    return 0;
}

bool Session::complete() const noexcept
{
    // A looping song has no completion: the position wraps rather than passing the end. Saying so
    // here is also what lets Play restart a song that finished before looping was turned on.
    if (looping_) {
        return false;
    }
    return player_.has_value()
           && player_->position()
                  >= song_length_ + static_cast<std::int64_t>(tail_seconds * sample_rate);
}

void Session::panic()
{
    live_state_.clear();
    if (engine_) {
        engine_->reset();
    }
}

void Session::silence()
{
    if (!engine_) {
        return;
    }

    constexpr int all_sound_off = 120;

    const int ports = std::max(1, settings_.ports);
    for (int port = 0; port < ports; ++port) {
        for (int channel = 0; channel < Sequence::channel_count; ++channel) {
            send_control(port, channel, all_sound_off, 0);
        }
    }
}

void Session::render(std::span<float> left, std::span<float> right)
{
    if (player_) {
        player_->render(left, right);
        return;
    }
    if (engine_) {
        engine_->render(left, right);
        return;
    }

    // The caller reuses its block, so leaving it untouched would queue the previous one again --
    // a stutter rather than the silence that is meant.
    std::fill(left.begin(), left.end(), 0.0F);
    std::fill(right.begin(), right.end(), 0.0F);
}

void Session::render_live(std::span<float> left, std::span<float> right)
{
    // The generator, not the sequence player: this is the block a stopped transport renders, and
    // going through the player would step the song forward under a keyboard.
    if (engine_) {
        engine_->render(left, right);
        return;
    }

    std::fill(left.begin(), left.end(), 0.0F);
    std::fill(right.begin(), right.end(), 0.0F);
}

int Session::active_voices() const noexcept
{
    return engine_ ? engine_->active_voices() : 0;
}

int Session::voice_capacity() const noexcept
{
    return engine_ ? engine_->voice_slots() : 0;
}

bool Session::xg_mode() const noexcept
{
    return engine_ && engine_->xg_mode();
}

void Session::send_channel(int port, int status, int data1, int data2)
{
    live_state_.record_channel(port, status, data1, data2);
    if (engine_) {
        engine_->send_channel(port, status, data1, data2);
    }
}

void Session::send_sysex(int port, std::span<const std::uint8_t> bytes)
{
    live_state_.record_sysex(port, bytes);
    if (engine_ && !bytes.empty()) {
        engine_->send_sysex(port, bytes);
    }
}

void Session::adopt_live_state(Session& from)
{
    live_state_ = std::move(from.live_state_);
    from.live_state_.clear();
    if (engine_ && !player_) {
        live_state_.replay(*engine_);
    }
}

void Session::set_output_gain(double gain) noexcept
{
    settings_.outputGain = gain;
    if (engine_) {
        engine_->set_output_gain(gain);
    }
}

void Session::send_control(int port, int channel, int controller, int value)
{
    if (engine_) {
        engine_->send_channel(port, 0xB0 | (channel & 0x0F), controller, value);
    }
}

void Session::capture(SessionSnapshot& into) const
{
    into.hasROM = has_rom();
    into.hasSong = has_song();
    into.looping = looping_;
    into.complete = complete();
    into.position = position();
    into.length = song_length_;

    // Cleared rather than overwritten: a rebuild with fewer ports leaves strips behind otherwise,
    // and they would go on showing whatever the wider engine last had on them.
    into.parts = {};

    if (!engine_) {
        into.partCount = Sequence::channel_count;
        into.activeVoices = 0;
        into.voiceCapacity = 0;
        into.noteCount = 0;
        into.drumKit = -1;
        into.xgMode = false;
        return;
    }

    into.activeVoices = active_voices();
    into.voiceCapacity = voice_capacity();
    into.noteCount = engine_->note_count();
    into.drumKit = engine_->drum_kit();
    into.xgMode = xg_mode();

    // The engine's own part count, not the mask's: `ChannelMask` is 64 wide because a four-port
    // engine has that many parts to mute, but asking this engine for one past its own reads memory
    // that is not a part.
    into.partCount = engine_->parts();

    // Per-part activity from the pool itself; there is no per-part counter, and a walk over at
    // most 64 handles ten times a second costs nothing.
    std::array<int, TS_MAX_PARTS> counts{};
    for (const auto& voice : engine_->voices().active()) {
        const int part = voice.channel();
        if (part >= 0 && part < TS_MAX_PARTS) {
            ++counts[static_cast<std::size_t>(part)];
        }
    }

    for (int index = 0; index < into.partCount && index < TS_MAX_PARTS; ++index) {
        const Part& part = engine_->part(index);
        PartState& state = into.parts[static_cast<std::size_t>(index)];

        // Asked of the engine per part, not taken from the settings: a bank LSB names a vintage and
        // XG System On moves every part onto the XG map, so one map for the whole mixer names the
        // wrong instrument as soon as a file switches mode. Drum routing moves the same way.
        const bool drums = engine_->part_is_drum(index);
        const int kit = engine_->part_drum_kit(index);

        state.program = part.program;
        state.bank = part.bank;
        state.bank_lsb = part.bank_lsb;
        state.volume = part.volume();
        state.expression = part.expression();
        state.pan = part.pan;
        state.voices = counts[static_cast<std::size_t>(index)];
        state.muted = channels_.is_muted(index);
        state.soloed = channels_.is_soloed(index);
        state.drums = drums;
        state.kit = kit;
        state.rx_channel = engine_->part_rx_channel(index);

        // Whether the file reaches this part, asked through the channel the part is *listening on*
        // rather than through its slot -- the same walk the engine does to deliver a message, which
        // is what makes this the question "will this strip make a sound".
        //
        // Matching is within a port, so the file's channel is looked up on this part's own port. A
        // receive channel outside 0-15 is the module's "off", and a part detached from every
        // channel hears nothing however much the file sends.
        const int port = index / Sequence::channel_count;
        state.present = state.rx_channel >= 0 && state.rx_channel < Sequence::channel_count
                        && used_channels_[static_cast<std::size_t>(
                            port * Sequence::channel_count + state.rx_channel)];
        state.map = static_cast<int>(engine_->part_tone_map(index));
        state.lookupBank = engine_->part_lookup_bank(index);

        state.name.clear();
        if (notes_) {
            if (drums) {
                state.name = trimmed(notes_->drums().kit_name(kit));
                if (state.name.empty() && kit >= 0) {
                    state.name = "Kit " + std::to_string(kit);
                }
            } else {
                const auto& directory = notes_->directory();
                const int tone = directory.program_to_tone(
                    part.program, engine_->part_tone_map(index), engine_->part_lookup_bank(index));
                if (tone >= 0) {
                    if (auto record = directory.tone(tone); record && record->is_defined()) {
                        state.name = trimmed(record->name());
                    }
                }
            }
        }
    }
}

Session::ExportPlan Session::plan_export() const
{
    if (!notes_ || song_events_.empty()) {
        throw std::runtime_error("Load a DLL and a song before exporting.");
    }

    ExportPlan plan;
    // const_cast because a plan borrows the renderer to build a generator over it, which is a
    // non-const use of an object this session otherwise only reads here. The renderer is owned by
    // the session and outlives the plan by contract.
    plan.notes = const_cast<NoteRenderer*>(&*notes_);
    plan.events = song_events_;
    plan.loop = song_loop_;
    plan.first_note = song_first_note_;
    plan.options = options();
    plan.total = song_length_ + static_cast<std::int64_t>(tail_seconds * sample_rate);
    return plan;
}

void Session::run_export(const ExportPlan& plan, const std::string& path,
                         const std::function<bool(double)>& progress)
{
    // A second generator over the same note renderer, so exporting disturbs nothing that is playing
    // and costs no second read of the 27 MB of tables.
    ToneGenerator engine{*plan.notes, plan.options};
    SequencePlayer player{engine, smf::Song{plan.events, plan.loop, plan.first_note}};

    // Spread as the playing engine does, so an export is the performance that was heard. A file
    // whose opening dump overruns the input queue plays on different patches with this off, and an
    // export that quietly picks the other reading of the same file would be the worst of both. It
    // stays byte-comparable against the library's own renderer -- that is now
    // `tabula-sonora render --spread-bursts`.
    player.set_spread_bursts(true);

    // The lead-in is *not* skipped, unlike playback. A render is data: its length and its alignment
    // against a reference render are what a comparison rests on, and silence at the head of a file
    // is part of the file. Skipping is a listening convenience and belongs where the listening is.

    const auto total = static_cast<std::size_t>(plan.total);
    std::vector<float> left(total, 0.0F);
    std::vector<float> right(total, 0.0F);

    // A quarter-second at a time, so the caller can report progress and abort without the
    // granularity of a whole song.
    constexpr std::size_t chunk = static_cast<std::size_t>(sample_rate) / 4;
    for (std::size_t rendered = 0; rendered < total;) {
        const auto count = std::min(chunk, total - rendered);
        player.render(std::span<float>{left.data() + rendered, count},
                      std::span<float>{right.data() + rendered, count});
        rendered += count;

        if (!progress(static_cast<double>(rendered) / static_cast<double>(total))) {
            return;
        }
    }

    // Through the library's own writer, so an export from here and a `tabula-sonora render` with
    // the same settings are the same bytes, not merely similar ones.
    wav::write(path, left, right, sample_rate);
}

int Session::event_latency_frames() const
{
    // `event_delay_blocks` counts one-millisecond chunks, which is what `block_grid` is: 32 frames
    // at the engine's 32 kHz, and emphatically not the 320-frame control block.
    return options().event_delay_blocks * smf::block_grid;
}

void Session::set_host_rate(int host_rate)
{
    if (host_rate == host_rate_) {
        return;
    }
    host_rate_ = host_rate;

    // As `set_settings` does: with no ROM there is no generator to rebuild, and `rebuild` reads
    // the tables through a `std::optional` that is not engaged until one is loaded. A plugin sets
    // its rate before it has a ROM as a matter of course -- the constructor prepares at the
    // engine's own rate, and the host prepares again long before the 27 MB has finished reading.
    if (!engine_) {
        return;
    }
    rebuild();
}

ToneGeneratorOptions Session::options() const
{
    ToneGeneratorOptions options;
    options.map = static_cast<ToneMap>(settings_.map);
    options.polyphony = settings_.polyphony;
    options.ports = settings_.ports;
    options.reverb = settings_.reverb;
    options.chorus = settings_.chorus;
    options.delay = settings_.delay;
    options.efx = settings_.efx;
    options.extended_interpolation = settings_.extendedInterpolation;
    options.flush_before_sysex = settings_.flushBeforeSysEx;
    options.output_gain = settings_.outputGain;
    options.channels = &channels_;

    // The module's own timing, and deliberately not settings.
    //
    // Neither of these is an option on the module: `TG_ShortMidiIn` only rings a message and
    // `TG_Process` walks it out four 32-sample chunks later, always, and `tg_output_filter` runs on
    // every chunk it emits. The engine defaults them the other way because its own unit tests send
    // a message and inspect a part on the next line, which is a convenience for testing *laws* and
    // the wrong setting for rendering a *song*.
    //
    // Left unset, this app started every note 128 samples early and skipped a stage the hardware
    // always runs -- a fidelity bug in a program whose whole purpose is the hardware's voice. It
    // also stopped being comparable: `tabula-sonora render` sets both unconditionally as of engine
    // fa3c9a6a, with no flag to ask for the old behaviour, so an export is a byte comparison
    // against a differently-timed engine unless this matches it.
    //
    // The cost is four milliseconds of latency on live MIDI, which the module also has, against a
    // uniform shift that is inaudible in playback.
    options.event_delay_blocks = 4;

    // The module runs one output stage, at the ratio between its rate and the host's. Here it is
    // the generator's copy, at 1:1, because the generator emits the engine's own 32 kHz -- unless
    // something downstream is going to run the same filter to do a real conversion, in which case
    // that one is the module's stage and this would be a second, spurious pass of it.
    options.bypass_output_filter = !settings_.extendedOutputResampler;

    // The rate a sample offset on a live message is read against, which the module turns into
    // milliseconds as `offset * 1000 / host_sample_rate`. Left at the engine's own rate it would
    // stamp a host running at 44.1 kHz nearly forty per cent early.
    options.host_sample_rate = host_rate_ > 0 ? host_rate_ : ts::OutputFilter::engine_rate;

    return options;
}

void Session::rebuild()
{
    // Whether there was a player at all, kept apart from where it stood: with the lead-in skipped a
    // song's own starting position is not zero, so "zero" is a real place to be and not a sentinel
    // for "nowhere".
    const bool was_playing = player_.has_value();
    const std::int64_t position = was_playing ? player_->position() : 0;

    // The player holds a pointer into the outgoing engine, so it goes first.
    player_.reset();
    engine_.emplace(*notes_, options());

    // A rebuild makes fresh parts at their power-on values. With no song, the live stream is the
    // only record of what they were, so it is told again -- the whole of it, SysEx included,
    // rather than a program and five controllers per part, which is what this used to carry and
    // which lost every part's drum routing on any change of setting.
    if (song_events_.empty()) {
        live_state_.replay(*engine_);
    } else {
        arm_player();

        // Put the new generator back where the old one was, so changing vintage mid-song resumes
        // rather than restarting. The seek replays the controllers, which is what makes that sound
        // right -- and it also undoes the fresh player's own lead-in skip, which would otherwise
        // jump a listener who had scrubbed back into the opening silence forward again.
        if (was_playing) {
            player_->seek(position);
        }
    }
}

void Session::arm_player()
{
    player_.emplace(*engine_, smf::Song{song_events_, song_loop_, song_first_note_});
    player_->set_loop_count(looping_ ? -1 : 1);

    // Hand a dense opening over at a cable's rate. The engine drops whatever will not fit in one
    // control tick's 2,048 packets, which is what the module does to a host that dumps a burst on
    // it -- but a wire cannot dump one, and this app is standing in for the wire. Without this a
    // file whose opening bulk dump is longer than the queue loses the end of its own setup and
    // plays on the wrong patches.
    player_->set_spread_bursts(true);

    // Then start where the music does. A file that opens with a bar of bank selects and controllers
    // plays as silence, and someone waiting through it cannot tell that from a file that failed to
    // load. Nothing is lost: this goes through `seek`, so every controller and SysEx in the lead-in
    // is still replayed into the engine and only the silence goes.
    //
    // After the loop count rather than before, and before the caller's own seek in `rebuild`: a
    // rebuild arms a fresh player and then puts it back where the old one was, and this must not
    // be what decides that position.
    player_->skip_lead_in();
}

} // namespace ts::apple
