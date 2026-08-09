#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <vector>

namespace ts::apple {

/// The module a file asks to be played on, as far as it says so at all.
///
/// Values that name a tone map match `TSToneMap`/`ts::ToneMap` exactly; `unstated`, `gm` and `gm2`
/// do not, because none of them names one -- a General MIDI file is content to play on any of the
/// vintages and saying otherwise would invent an intent the file does not have.
enum class SongVintage {
    unstated,
    gm,
    gm2,
    sc55 = 1 << 8,
    sc88,
    sc88pro,
    sc8820,
    xg,
};

/// How a file's text is encoded, as far as it can be told.
///
/// Standard MIDI Files carry no encoding declaration at all: FF 01 and its neighbours are "any
/// amount of text", bytes and nothing more. So this is a guess, arrived at by trying to decode and
/// seeing what survives, and it is deliberately the *file's* guess rather than one per string --
/// a file that mixes encodings between its own meta events is rare enough, and the alternative
/// (guessing per string) flips encoding between adjacent rows of the same list, which looks like a
/// bug even when each guess was individually the better one.
enum class TextEncoding {
    /// Plain ASCII, and so correct under every candidate below.
    ascii,
    /// Valid UTF-8 carrying at least one byte above 127. Modern files, and files a modern editor
    /// has been through.
    utf8,
    /// Decodes as Shift-JIS *and* yields CJK. Japanese files are the large non-Latin population
    /// here, and this is what they are almost always in.
    shift_jis,
    /// The fallback that cannot fail: every byte maps to something. Wrong for the Cyrillic and
    /// Greek code pages, which are indistinguishable from it without a charset detector, but right
    /// for the far commoner case of a Latin-1 copyright sign.
    cp1252,
};

/// A marker meta event, and where in the song it falls.
struct SongMarker {
    std::string text;

    /// Frames at the engine's rate, so this can be handed straight to a seek.
    ///
    /// Converted from the file's ticks through its own tempo map, which is why the walk that finds
    /// these has to read delta times it otherwise has no use for.
    std::int64_t position = 0;
};

/// One track of the file, in the order the file stores them.
struct SongTrack {
    /// 1-based, counting every MTrk including a format-1 tempo track that plays nothing.
    int number = 0;

    /// FF 03, Sequence/Track Name.
    std::string name;

    /// FF 04, Instrument Name. Kept apart from `name` because a file may carry both, and because
    /// FF 04 doubles as a port tag in files that predate FF 09 -- so it is often an output's name
    /// rather than an instrument's.
    std::string instrument;

    /// Channels this track sends voice messages on, ascending and zero-based.
    ///
    /// A track is normally one channel, but a format-0 file is one track carrying all of them and
    /// mix-down tracks exist in format 1 too, so this is a list rather than a number.
    std::vector<int> channels;

    /// Note-ons with non-zero velocity. What makes a silent tempo track visibly silent.
    int notes = 0;
};

/// Everything a file says about itself, beyond the events the engine plays.
///
/// Collected by a walk of the file's own chunks rather than from `smf::Song`, because the engine's
/// reader consumes and drops every meta event except tempo, the port tags and the loop markers --
/// which is the right thing for a renderer and leaves nothing for a reader. Doing our own walk also
/// recovers the F7-form system-exclusive messages the reader discards, which matters here because a
/// file is free to declare its module in one.
///
/// Strings hold the file's **raw bytes**, undecoded; `encoding` says what to put them through. The
/// conversion needs Foundation and belongs to the layer that has it, so it does not happen here.
struct SongInfo {
    /// Whether a file was found and understood at all. Everything below is meaningless when false.
    bool valid = false;

    // -- The container ---------------------------------------------------------------------------

    /// Non-empty for a file that had to be converted to be read -- a Miles XMI, a DOOM MUS, and so
    /// on. Empty for a Standard MIDI File, which is converted from nothing. `formats::to_smf`
    /// reports *that* it converted rather than what from, so this can only say which of the two.
    std::string container;

    /// 0, 1 or 2, as the header declares.
    int format = 0;

    /// MTrk chunks found. Not taken from the header's count, which malformed files get wrong.
    int track_count = 0;

    /// Ticks per quarter note. Zero when the file uses SMPTE timing, which has no such thing.
    int division = 0;

    /// The first tempo the file sets, in beats per minute, or zero if it sets none.
    ///
    /// The *first*, not an average: a file that ritards to a halt has a meaningful opening tempo
    /// and a meaningless mean, and the only honest single number is the one it starts at.
    double initial_tempo_bpm = 0.0;

    /// How many times the file changes tempo. A reader needs this to know whether the number above
    /// describes the piece or only its first bar.
    int tempo_changes = 0;

    /// FF 58, as "4/4". Empty when the file declares none.
    std::string time_signature;

    /// FF 59, as "C major". Empty when the file declares none.
    std::string key_signature;

    // -- What the file says ----------------------------------------------------------------------

    TextEncoding encoding = TextEncoding::ascii;

    std::vector<SongTrack> tracks;

    /// FF 02, Copyright Notice.
    std::string copyright;

    /// FF 01, Text, minus the Soft Karaoke `@` lines, which are not prose and are lifted out below.
    /// Deduplicated in order of first appearance: a file that repeats its own credit once per track
    /// is common and listing it seventeen times is not information.
    std::vector<std::string> text;

    /// FF 06, Marker, minus the ones that only exist to mark the loop, ordered by position.
    ///
    /// *Not* deduplicated by text, unlike `text` above, and the difference is the position: a file
    /// that marks "Verse 1" twice is marking two places, and collapsing them would lose the second.
    /// Only an exact repeat -- same text at the same tick, which is what a file writing its markers
    /// onto two tracks produces -- is dropped.
    std::vector<SongMarker> markers;

    /// The lyric sheet, as text, with no timing.
    ///
    /// Assembled from whichever dialect the file uses -- FF 05 Lyric events, or the Soft Karaoke
    /// convention of FF 01 Text in a track named "Soft Karaoke", where `\` starts a paragraph and
    /// `/` a line and everything else is a syllable to be run onto the one before it. Both are
    /// stored one syllable at a time, so joining them is the whole job.
    std::string lyrics;

    /// Soft Karaoke's own `@T` header lines: conventionally the title, then the author, then
    /// whatever the file felt like adding.
    std::vector<std::string> karaoke_headings;

    // -- Length and loop -------------------------------------------------------------------------
    //
    // Neither is found by the walk above, and deliberately so: four marker dialects declare a loop
    // and the engine's reader already scans for all of them, so `Session` copies its answers in
    // here rather than this file growing a fifth, worse implementation of the same scan.

    /// Position of the final event, in frames at the engine's rate.
    ///
    /// Here rather than read from the player's published duration, and that is not tidiness: the
    /// snapshot is refreshed on a display tick, which happens *after* the song name has already
    /// told everything watching that the file changed. A view rebuilding on the name and reading
    /// the duration would show the previous song's length.
    std::int64_t length = 0;

    bool has_loop = false;

    /// Frames at the engine's rate, matching `SessionSnapshot::position`.
    std::int64_t loop_start = 0;
    std::int64_t loop_end = 0;

    /// Whether the file marked the end explicitly. A soft loop rewinds without replaying state; a
    /// hard one has its end inferred and replays controllers the way a seek does.
    bool loop_soft = false;

    // -- What it asks to be played on ------------------------------------------------------------

    SongVintage vintage = SongVintage::unstated;

    /// The evidence, in prose, for showing beside the verdict: "a Roland GS Reset, and a bank
    /// select LSB of 2". Empty when there was none. Plain ASCII, ours rather than the file's, so it
    /// is not subject to `encoding`.
    std::string vintage_evidence;
};

/// Reads what a file says about itself. Never throws; an unreadable or unrecognised file comes back
/// with `valid` false.
///
/// `name` is the file name the bytes came from, needed for the same reason `smf::load` needs it:
/// the Loudness Sound System format has no magic and is recognised by its extension alone.
/// `sample_rate` is what marker positions are expressed in, and defaults to the engine's own, so
/// they can be handed to a seek without conversion.
[[nodiscard]] SongInfo read_song_info(std::span<const std::uint8_t> data, const std::string& name,
                                      int sample_rate = 32000);

/// The display name of a vintage: "SC-88", "General MIDI", or empty when nothing was stated.
[[nodiscard]] std::string vintage_name(SongVintage vintage);

} // namespace ts::apple
