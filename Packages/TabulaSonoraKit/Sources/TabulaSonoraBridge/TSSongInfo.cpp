#include "TSSongInfo.hpp"

#include "tabulasonora/midi_formats.hpp"
#include "tabulasonora/smf_reader.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <utility>

namespace ts::apple {

namespace {

/// The tempo a file is at before it sets one: 120 bpm, the engine's own default.
constexpr std::uint32_t default_tempo = static_cast<std::uint32_t>(smf::default_tempo);

// -- Byte-level reading ---------------------------------------------------------------------------
//
// A cursor rather than an index, because every one of these has to refuse to run off the end of a
// truncated file and returning zero from a spent cursor is what lets the walk below stay readable.
// A malformed file is the normal case here, not the exceptional one: this reads whatever anybody
// ever wrote a MIDI file with, and half of them were wrong.

class Cursor {
public:
    explicit Cursor(std::span<const std::uint8_t> data) : data_{data} {}

    [[nodiscard]] bool spent() const noexcept { return position_ >= data_.size(); }
    [[nodiscard]] std::size_t remaining() const noexcept
    {
        return spent() ? 0 : data_.size() - position_;
    }

    std::uint8_t byte() noexcept
    {
        if (spent()) {
            exhausted_ = true;
            return 0;
        }
        return data_[position_++];
    }

    std::uint32_t big_endian(int width) noexcept
    {
        std::uint32_t value = 0;
        for (int index = 0; index < width; ++index) {
            value = (value << 8) | byte();
        }
        return value;
    }

    /// A MIDI variable-length quantity, capped at the four bytes the format allows. An unterminated
    /// run is a broken file, and reading on would swallow the rest of the track.
    std::uint32_t variable() noexcept
    {
        std::uint32_t value = 0;
        for (int index = 0; index < 4; ++index) {
            const std::uint8_t part = byte();
            value = (value << 7) | (part & 0x7FU);
            if ((part & 0x80U) == 0) {
                break;
            }
        }
        return value;
    }

    /// The next `length` bytes, clamped to what is left.
    std::span<const std::uint8_t> block(std::size_t length) noexcept
    {
        const std::size_t taken = std::min(length, remaining());
        if (taken < length) {
            exhausted_ = true;
        }
        const auto view = data_.subspan(position_, taken);
        position_ += taken;
        return view;
    }

    void skip(std::size_t length) noexcept { (void)block(length); }

    /// Whether any read has been served short. A walk stops on this rather than looping on a
    /// cursor that has been returning zeroes since the file ended.
    [[nodiscard]] bool exhausted() const noexcept { return exhausted_; }

private:
    std::span<const std::uint8_t> data_;
    std::size_t position_ = 0;
    bool exhausted_ = false;
};

std::string to_string(std::span<const std::uint8_t> bytes)
{
    return std::string{reinterpret_cast<const char*>(bytes.data()), bytes.size()};
}

/// Trims ASCII whitespace and the trailing NULs that padded-out text events are full of.
std::string trimmed(std::string text)
{
    const auto is_padding = [](unsigned char character) {
        return character == '\0' || character == ' ' || character == '\t' || character == '\r'
               || character == '\n';
    };
    while (!text.empty() && is_padding(static_cast<unsigned char>(text.back()))) {
        text.pop_back();
    }
    std::size_t begin = 0;
    while (begin < text.size() && is_padding(static_cast<unsigned char>(text[begin]))) {
        ++begin;
    }
    return text.substr(begin);
}

std::string lowered(std::string text)
{
    for (char& character : text) {
        if (character >= 'A' && character <= 'Z') {
            character = static_cast<char>(character - 'A' + 'a');
        }
    }
    return text;
}

/// Appends unless the text is empty or already present. The lists this feeds are credits and
/// markers, which files repeat once per track as a matter of course.
void add_once(std::vector<std::string>& into, const std::string& text)
{
    if (text.empty() || std::find(into.begin(), into.end(), text) != into.end()) {
        return;
    }
    into.push_back(text);
}

// -- Text encoding ---------------------------------------------------------------------------------

/// Whether a run of bytes is valid UTF-8, by the encoding's own rules -- including the ones that
/// exist to make it self-synchronising, since it is exactly those that make this test worth
/// running. Overlong forms and surrogates are rejected: accepting them would let Shift-JIS text
/// pass as UTF-8 far more often than it does.
bool is_utf8(std::span<const std::uint8_t> bytes)
{
    std::size_t index = 0;
    while (index < bytes.size()) {
        const std::uint8_t lead = bytes[index];
        int followers = 0;
        std::uint32_t code = 0;

        if (lead < 0x80U) {
            ++index;
            continue;
        }
        if ((lead & 0xE0U) == 0xC0U) {
            followers = 1;
            code = lead & 0x1FU;
        } else if ((lead & 0xF0U) == 0xE0U) {
            followers = 2;
            code = lead & 0x0FU;
        } else if ((lead & 0xF8U) == 0xF0U) {
            followers = 3;
            code = lead & 0x07U;
        } else {
            return false;
        }

        if (index + static_cast<std::size_t>(followers) >= bytes.size()) {
            return false;
        }
        for (int step = 1; step <= followers; ++step) {
            const std::uint8_t next = bytes[index + static_cast<std::size_t>(step)];
            if ((next & 0xC0U) != 0x80U) {
                return false;
            }
            code = (code << 6) | (next & 0x3FU);
        }

        static constexpr std::array<std::uint32_t, 4> minimum{0, 0x80, 0x800, 0x10000};
        if (code < minimum[static_cast<std::size_t>(followers)] || code > 0x10FFFF
            || (code >= 0xD800 && code <= 0xDFFF)) {
            return false;
        }
        index += static_cast<std::size_t>(followers) + 1;
    }
    return true;
}

/// Whether a run of bytes is Shift-JIS carrying actual Japanese.
///
/// Structural validity alone is nowhere near enough, and getting this wrong in the permissive
/// direction is expensive: an accented Latin vowel followed by an ASCII letter is a *legal*
/// Shift-JIS pair, so "Flèche", "Violão" and "flächen" all parse cleanly and come out as kanji
/// soup. Measured over 128,000 files, structural validity plus "some double-byte character
/// appeared" misfiled roughly half of what it caught.
///
/// What separates them is the lead byte's range. Accented Latin lives in 0xC0-0xFF; the 0x81-0x9F
/// block is the C1 control range, which no Latin text carries, and which Japanese text can hardly
/// avoid -- the kana are at 0x82 and 0x83, the punctuation at 0x81, and JIS level-1 kanji begin at
/// 0x88. So a lead in that block is the evidence, and a lead in 0xE0-0xEF is merely permitted
/// alongside it.
///
/// Half-width katakana (0xA1-0xDF, single byte) deliberately proves nothing on its own: it shares
/// its range with the whole of Latin-1's accented alphabet, and a copyright sign is far commoner in
/// this corpus than a katakana-only title.
bool is_shift_jis(std::span<const std::uint8_t> bytes)
{
    bool saw_japanese_lead = false;
    std::size_t index = 0;
    while (index < bytes.size()) {
        const std::uint8_t lead = bytes[index];
        if (lead < 0x80U || (lead >= 0xA1U && lead <= 0xDFU)) {
            ++index;
            continue;
        }
        const bool kana_or_kanji = lead >= 0x81U && lead <= 0x9FU;
        const bool extended = lead >= 0xE0U && lead <= 0xEFU;
        if ((!kana_or_kanji && !extended) || index + 1 >= bytes.size()) {
            return false;
        }
        const std::uint8_t trail = bytes[index + 1];
        if (trail < 0x40U || trail > 0xFCU || trail == 0x7FU) {
            return false;
        }
        saw_japanese_lead = saw_japanese_lead || kana_or_kanji;
        index += 2;
    }
    return saw_japanese_lead;
}

/// The encoding ladder, run once over everything the file says.
///
/// Deliberately in this order and no longer. A charset detector would do better on the Cyrillic and
/// Greek files -- which land on cp1252 here and render as mojibake -- but a wrong confident guess is
/// worse than a wrong obvious one, and there is no way to tell CP1251 from CP1252 without one:
/// every byte is valid in both.
TextEncoding detect_encoding(const std::vector<std::uint8_t>& all_text)
{
    const std::span<const std::uint8_t> view{all_text};
    const bool has_high = std::any_of(all_text.begin(), all_text.end(),
                                      [](std::uint8_t byte) { return byte >= 0x80U; });
    if (!has_high) {
        return TextEncoding::ascii;
    }
    if (is_utf8(view)) {
        return TextEncoding::utf8;
    }
    if (is_shift_jis(view)) {
        return TextEncoding::shift_jis;
    }
    return TextEncoding::cp1252;
}

// -- System-exclusive recognition ------------------------------------------------------------------

/// What a file's system-exclusive traffic declared, before the bank selects get a say.
struct Declarations {
    /// `F0 43 1n 4C 00 00 7E 00 F7` -- XG System On.
    bool xg = false;
    /// `F0 41 dd 42 12 40 00 7F 00 41 F7` -- GS Reset. GS is the SC-55's, so this alone is one.
    bool gs_reset = false;
    /// `F0 41 dd 42 12 00 00 7F mm ss F7` -- System Mode Set, which the SC-55 does not have. A file
    /// sending it is addressing an SC-88 or later even when it names no map, and in this corpus
    /// that is exactly what the SC-88 demo disks do.
    bool system_mode_set = false;
    bool gm = false;
    bool gm2 = false;
};

void recognise(std::span<const std::uint8_t> message, Declarations& into)
{
    // Every pattern below is matched against a message including its leading F0, which is how the
    // walk stores them regardless of whether the file used the F0 or the F7 form.
    if (message.size() < 5 || message[0] != 0xF0U) {
        return;
    }

    // Universal non-real-time: F0 7E <device> 09 <mode> F7.
    if (message.size() >= 5 && message[1] == 0x7EU && message[3] == 0x09U) {
        if (message[4] == 0x01U) {
            into.gm = true;
        } else if (message[4] == 0x03U) {
            into.gm2 = true;
        }
        return;
    }

    // Yamaha XG: F0 43 <1n> 4C <address 3> <data> F7. The device nibble varies and the model ID 4C
    // is what makes it XG rather than any other Yamaha device.
    if (message.size() >= 8 && message[1] == 0x43U && (message[2] & 0xF0U) == 0x10U
        && message[3] == 0x4CU && message[4] == 0x00U && message[5] == 0x00U
        && message[6] == 0x7EU) {
        into.xg = true;
        return;
    }

    // Roland GS: F0 41 <device> 42 12 <address 3> <data...> <checksum> F7. The device byte is not
    // fixed -- 10 is the default but files address others -- so it is skipped rather than matched.
    if (message.size() >= 9 && message[1] == 0x41U && message[3] == 0x42U && message[4] == 0x12U) {
        const std::uint8_t a1 = message[5];
        const std::uint8_t a2 = message[6];
        const std::uint8_t a3 = message[7];
        if (a1 == 0x40U && a2 == 0x00U && a3 == 0x7FU) {
            into.gs_reset = true;
        } else if (a1 == 0x00U && a2 == 0x00U && a3 == 0x7FU) {
            into.system_mode_set = true;
        }
    }
}

/// Turns the declarations and the bank selects into a verdict.
///
/// The bank select LSB is the module's own map selector -- 1 SC-55, 2 SC-88, 3 SC-88Pro, 4 SC-8820
/// -- but only inside a GS file. Outside one it means whatever the file's own synthesizer decided,
/// and the corpus is full of files using LSB 46 or 127 for something else entirely; reading those
/// as a vintage is precisely the guess the engine documents itself as refusing to make. So it is
/// consulted only to *raise* a floor that a system-exclusive message already established.
SongVintage decide(const Declarations& declared, const std::vector<int>& bank_lsbs,
                   std::string& evidence)
{
    // Named messages, not sentences. This is shown under the verdict as a caption, where the
    // reader already knows what it is a list of and a prose frame around it only takes up room.
    const auto note = [&evidence](const std::string& clause) {
        evidence += evidence.empty() ? clause : " · " + clause;
    };

    if (declared.xg) {
        note("XG System On");
        return SongVintage::xg;
    }

    if (declared.gs_reset || declared.system_mode_set) {
        // The floor: GS begins with the SC-55, and System Mode Set does not exist before the SC-88.
        SongVintage vintage = declared.system_mode_set ? SongVintage::sc88 : SongVintage::sc55;
        if (declared.gs_reset) {
            note("GS Reset");
        }
        if (declared.system_mode_set) {
            note("System Mode Set, which no SC-55 has");
        }

        int highest = 0;
        for (const int lsb : bank_lsbs) {
            if (lsb >= 1 && lsb <= 4) {
                highest = std::max(highest, lsb);
            }
        }
        if (highest > 0) {
            static constexpr std::array<SongVintage, 5> named{SongVintage::unstated,
                                                              SongVintage::sc55, SongVintage::sc88,
                                                              SongVintage::sc88pro,
                                                              SongVintage::sc8820};
            const SongVintage selected = named[static_cast<std::size_t>(highest)];
            if (static_cast<int>(selected) > static_cast<int>(vintage)) {
                vintage = selected;
            }
            note("bank select LSB " + std::to_string(highest));
        }
        return vintage;
    }

    if (declared.gm2) {
        note("General MIDI 2 System On");
        return SongVintage::gm2;
    }
    if (declared.gm) {
        note("General MIDI System On");
        return SongVintage::gm;
    }
    return SongVintage::unstated;
}

// -- Meta event types ------------------------------------------------------------------------------

constexpr std::uint8_t meta_text = 0x01;
constexpr std::uint8_t meta_copyright = 0x02;
constexpr std::uint8_t meta_track_name = 0x03;
constexpr std::uint8_t meta_instrument = 0x04;
constexpr std::uint8_t meta_lyric = 0x05;
constexpr std::uint8_t meta_marker = 0x06;
constexpr std::uint8_t meta_end_of_track = 0x2F;
constexpr std::uint8_t meta_tempo = 0x51;
constexpr std::uint8_t meta_time_signature = 0x58;
constexpr std::uint8_t meta_key_signature = 0x59;

/// Whether a marker is one the loop scanners consume. Those are shown as the loop, not as markers.
bool is_loop_marker(const std::string& marker)
{
    const std::string key = lowered(marker);
    return key == "loopstart" || key == "loopend" || key == "start";
}

/// Whether a file's markers are really a lyric sheet.
///
/// A third karaoke dialect, after FF 05 and Soft Karaoke's FF 01: some sequencers write the words
/// into FF 06 Marker instead, one syllable per event, keeping Soft Karaoke's convention that `\`
/// starts a paragraph and `/` a line. Nothing but the type distinguishes them, and reading them as
/// section markers is badly wrong in both directions -- the lyrics page says the file has none while
/// the markers list runs to 801 rows of "Da", "le", "a", "tu", "cuer", "po", one of which is a
/// clickable seek to the syllable.
///
/// The line-break prefixes are the tell, and they are the *only* thing trusted here. A section
/// marker is called "Verse 2", never "/For" or "\Da", so a run of them carrying those prefixes is a
/// lyric stream. Several rather than one, so a lone oddly-named marker cannot take the list with it,
/// and the share is set low because a sheet breaks a line only every eight or ten syllables -- the
/// lowest genuine ratio measured over the corpus was one marker in twenty-three.
///
/// Nothing is inferred from the *shape* of the markers, and that is a decision with evidence behind
/// it rather than caution. Files exist -- Tune 1000's, mostly -- that hold a lyric sheet as hundreds
/// of one-word markers with no break characters at all, and they cannot be told apart from a real
/// section list by length, count or word shape: a rule tuned to catch them flagged 163 of 225
/// marker-heavy files, and the ones it caught were "Verse 1", "Interlude", "Full Chorus 1",
/// "Variation 1" -- precisely the markers worth showing. So those files list their words, each
/// correctly stamped and each seekable, which is at worst a long list of true things.
bool markers_are_lyrics(const std::vector<std::string>& markers)
{
    if (markers.size() < 8) {
        return false;
    }
    const auto broken = static_cast<std::size_t>(
        std::count_if(markers.begin(), markers.end(), [](const std::string& text) {
            return !text.empty() && (text.front() == '\\' || text.front() == '/');
        }));
    return broken >= 4 && broken * 32 >= markers.size();
}

// -- The tempo map ---------------------------------------------------------------------------------

/// One tempo change, in ticks.
struct TempoChange {
    std::int64_t tick = 0;
    /// Microseconds per quarter note.
    std::uint32_t microseconds = default_tempo;
};

/// Turns a tick into a frame position, through the tempo changes the file declares.
///
/// A marker's tick means nothing on its own -- a file that halves its tempo halfway through puts
/// its later markers at twice the distance the tick count suggests -- so every change before the
/// target has to be walked. The seconds elapsed at each change are accumulated once and the lookup
/// is then a scan of a short, sorted list; files here carry a handful of tempo changes, and the
/// worst in the corpus is still small enough that a binary search would buy nothing.
class TempoMap {
public:
    TempoMap(std::vector<TempoChange> changes, int division) : division_{division}
    {
        // Ticks are only comparable across tracks because they share an origin, so a format-1
        // file's conductor track and its parts agree. Sorting is stable so two changes stamped on
        // the same tick resolve in the order the file stored them, which is the order the engine
        // would have applied them in.
        std::stable_sort(changes.begin(), changes.end(),
                         [](const TempoChange& a, const TempoChange& b) { return a.tick < b.tick; });

        double seconds = 0.0;
        std::int64_t previous_tick = 0;
        std::uint32_t previous_tempo = default_tempo;
        entries_.reserve(changes.size());
        for (const TempoChange& change : changes) {
            seconds += span_seconds(change.tick - previous_tick, previous_tempo);
            entries_.push_back(Entry{change.tick, seconds, change.microseconds});
            previous_tick = change.tick;
            previous_tempo = change.microseconds;
        }
    }

    [[nodiscard]] double seconds_at(std::int64_t tick) const
    {
        // SMPTE timing has no ticks per quarter note and no tempo map to walk. The engine refuses
        // those files outright, so nothing that reaches a window is one; returning zero rather
        // than dividing by it is what keeps this callable on its own.
        if (division_ <= 0) {
            return 0.0;
        }

        double seconds = 0.0;
        std::int64_t base_tick = 0;
        std::uint32_t tempo = default_tempo;
        for (const Entry& entry : entries_) {
            if (entry.tick > tick) {
                break;
            }
            seconds = entry.seconds;
            base_tick = entry.tick;
            tempo = entry.microseconds;
        }
        return seconds + span_seconds(tick - base_tick, tempo);
    }

private:
    struct Entry {
        std::int64_t tick = 0;
        double seconds = 0.0;
        std::uint32_t microseconds = default_tempo;
    };

    [[nodiscard]] double span_seconds(std::int64_t ticks, std::uint32_t microseconds) const
    {
        if (division_ <= 0 || ticks <= 0) {
            return 0.0;
        }
        return static_cast<double>(ticks) * static_cast<double>(microseconds)
               / (1'000'000.0 * static_cast<double>(division_));
    }

    std::vector<Entry> entries_;
    int division_ = 0;
};

/// Seconds to frames, clamped at zero. Not quantised onto the engine's block grid: this is handed
/// to a seek, which takes any frame, and rounding it would move a marker off the beat it names.
std::int64_t to_frames(double seconds, int sample_rate)
{
    if (!(seconds > 0.0)) {
        return 0;
    }
    return static_cast<std::int64_t>(seconds * static_cast<double>(sample_rate));
}

std::string format_time_signature(std::span<const std::uint8_t> data)
{
    if (data.size() < 2 || data[1] > 31) {
        return {};
    }
    const int denominator = 1 << data[1];
    return std::to_string(static_cast<int>(data[0])) + "/" + std::to_string(denominator);
}

std::string format_key_signature(std::span<const std::uint8_t> data)
{
    if (data.size() < 2) {
        return {};
    }
    // The count is signed: negative is flats, positive sharps, and -7..7 is the whole domain.
    const int accidentals = static_cast<int>(static_cast<std::int8_t>(data[0]));
    const bool minor = data[1] != 0;
    if (accidentals < -7 || accidentals > 7) {
        return {};
    }

    static constexpr std::array<const char*, 15> majors{"Cb", "Gb", "Db", "Ab", "Eb", "Bb", "F",
                                                        "C",  "G",  "D",  "A",  "E",  "B", "F#",
                                                        "C#"};
    static constexpr std::array<const char*, 15> minors{"Ab", "Eb", "Bb", "F",  "C",  "G",  "D",
                                                        "A",  "E",  "B",  "F#", "C#", "G#", "D#",
                                                        "A#"};
    const auto index = static_cast<std::size_t>(accidentals + 7);
    const char* tonic = minor ? minors[index] : majors[index];
    return std::string{tonic} + (minor ? " minor" : " major");
}

// -- Soft Karaoke ----------------------------------------------------------------------------------

/// Whether a track is a Soft Karaoke lyric track.
///
/// The format puts its lyrics in FF 01 Text rather than FF 05 Lyric, which would be indistinguishable
/// from ordinary prose if it did not also name the track: the convention is a track named "Words" in
/// a file whose first track is named "Soft Karaoke", and the `@` headers are the other half of the
/// signature. Testing for the headers rather than the names is what makes this work on the many
/// files that kept the format and lost the naming.
bool looks_like_karaoke(const std::vector<std::string>& texts)
{
    return std::any_of(texts.begin(), texts.end(), [](const std::string& text) {
        return text.size() >= 2 && text[0] == '@'
               && (text[1] == 'K' || text[1] == 'L' || text[1] == 'T' || text[1] == 'V'
                   || text[1] == 'I' || text[1] == 'W');
    });
}

/// Joins karaoke syllables into a readable sheet.
///
/// The syllables arrive one event at a time with no separators; the format's own line breaks are
/// carried in-band, `\` starting a paragraph and `/` a line. Everything else runs onto the line
/// being built, which is what makes a word out of "Hap", "py", " birth", "day".
std::string join_karaoke(const std::vector<std::string>& syllables)
{
    std::string sheet;
    for (const std::string& piece : syllables) {
        for (const char character : piece) {
            if (character == '\\') {
                sheet += "\n\n";
            } else if (character == '/') {
                sheet += '\n';
            } else if (character == '\r') {
                continue;
            } else {
                sheet += character;
            }
        }
    }
    return trimmed(std::move(sheet));
}

} // namespace

std::string vintage_name(SongVintage vintage)
{
    switch (vintage) {
    case SongVintage::gm:
        return "General MIDI";
    case SongVintage::gm2:
        return "General MIDI 2";
    case SongVintage::sc55:
        return "SC-55";
    case SongVintage::sc88:
        return "SC-88";
    case SongVintage::sc88pro:
        return "SC-88Pro";
    case SongVintage::sc8820:
        return "SC-8820";
    case SongVintage::xg:
        return "XG";
    case SongVintage::unstated:
        break;
    }
    return {};
}

SongInfo read_song_info(std::span<const std::uint8_t> data, const std::string& name, int sample_rate)
{
    SongInfo info;

    // The same conversion the engine's reader opens with, so this sees the file the engine sees and
    // a DOOM MUS or a Miles XMI has track names like anything else. The converted bytes have to
    // outlive the walk, hence the named local rather than a temporary inside the `if`.
    std::vector<std::uint8_t> converted;
    std::span<const std::uint8_t> smf = data;
    try {
        if (auto foreign = formats::to_smf(data, name)) {
            converted = std::move(*foreign);
            smf = converted;
            info.container = "converted";
        }
    } catch (const std::exception&) {
        // A recognised-but-malformed foreign file. The engine will refuse it too, and there is
        // nothing to say about a file that cannot be read; fall through to the header check below,
        // which will not find MThd in the original bytes and will report the file as unreadable.
    }

    if (smf.size() < 14 || smf[0] != 'M' || smf[1] != 'T' || smf[2] != 'h' || smf[3] != 'd') {
        return info;
    }

    Cursor header{smf};
    header.skip(4);
    const std::uint32_t header_length = header.big_endian(4);
    info.format = static_cast<int>(header.big_endian(2));
    header.skip(2); // The declared track count; the real one is counted below.
    const auto division = static_cast<std::uint16_t>(header.big_endian(2));

    // A negative division is SMPTE timing: the high byte is a negative frame rate and there is no
    // tick-per-quarter-note to report. The engine refuses those files outright, so this only has to
    // avoid claiming a nonsensical number for one.
    info.division = (division & 0x8000U) != 0 ? 0 : static_cast<int>(division);

    // Chunks start after the header's declared length, not after the fourteen bytes we just read:
    // the format allows a longer header and says to skip what you do not understand.
    std::size_t position = 8 + header_length;

    std::vector<int> bank_lsbs;
    Declarations declared;
    std::vector<std::uint8_t> all_text;
    std::vector<std::string> lyric_pieces;
    std::vector<std::string> karaoke_pieces;
    bool saw_lyric_meta = false;

    // Markers and tempo changes are gathered in ticks and resolved once every track has been read:
    // a file may put its tempo map on a conductor track that follows the tracks carrying markers,
    // and converting as we went would place those against a map that was still being built.
    struct TickedText {
        std::int64_t tick = 0;
        std::string text;
    };
    std::vector<TickedText> marker_ticks;
    std::vector<TempoChange> tempo_changes;

    while (position + 8 <= smf.size()) {
        const bool is_track = smf[position] == 'M' && smf[position + 1] == 'T'
                              && smf[position + 2] == 'r' && smf[position + 3] == 'k';
        Cursor length_reader{smf.subspan(position + 4, 4)};
        const std::uint32_t chunk_length = length_reader.big_endian(4);
        position += 8;

        const std::size_t available = std::min(static_cast<std::size_t>(chunk_length),
                                               smf.size() - position);
        if (!is_track) {
            // An unknown chunk. The format says to skip it, and files do carry them.
            position += available;
            continue;
        }

        SongTrack track;
        track.number = ++info.track_count;

        std::vector<std::string> track_texts;
        std::vector<std::string> track_lyrics;
        bool channels_seen[16] = {};

        Cursor cursor{smf.subspan(position, available)};
        position += available;

        std::uint8_t running = 0;
        std::int64_t tick = 0;
        while (!cursor.spent() && !cursor.exhausted()) {
            // Ticks are accumulated for the markers' sake alone. The lyric sheet is deliberately
            // unsynced and nothing else here cares when it happened, but a marker that cannot be
            // jumped to is a label rather than a place.
            tick += cursor.variable();
            if (cursor.spent()) {
                break;
            }

            std::uint8_t status = cursor.byte();

            // Under running status the byte just read is not a status but the first data byte, and
            // the status is the one still standing from the previous event. There is no rewinding
            // this cursor, so that byte is carried forward in `pending` and the channel-message
            // branch below reads one fewer operand because of it.
            bool have_pending = false;
            std::uint8_t pending = 0;
            if (status < 0x80U) {
                // With no running status set the track is malformed from here, and guessing would
                // produce plausible-sounding nonsense -- the same call the engine's reader makes.
                if (running == 0) {
                    break;
                }
                pending = status;
                have_pending = true;
                status = running;
            }

            if (status == 0xFFU) {
                const std::uint8_t type = cursor.byte();
                const std::uint32_t length = cursor.variable();
                const auto payload = cursor.block(length);

                // Two readings of the same bytes. A label is trimmed, because a track called
                // "Piano   " is called Piano; a lyric syllable is not, because the spaces around it
                // are the word boundaries -- "Hap" + "py " + "birth" + "day" only reads as English
                // if the one trailing space survives. Both feed the encoding sample either way.
                const auto sample = [&] {
                    all_text.insert(all_text.end(), payload.begin(), payload.end());
                    all_text.push_back('\n');
                };
                const auto as_label = [&] {
                    const std::string value = trimmed(to_string(payload));
                    if (!value.empty()) {
                        sample();
                    }
                    return value;
                };
                const auto as_written = [&] {
                    std::string value = to_string(payload);
                    // NULs pad a fixed-width field in some writers and are never content; spaces
                    // are.
                    value.erase(std::remove(value.begin(), value.end(), '\0'), value.end());
                    if (!value.empty()) {
                        sample();
                    }
                    return value;
                };

                switch (type) {
                case meta_track_name:
                    track.name = as_label();
                    break;
                case meta_instrument:
                    track.instrument = as_label();
                    break;
                case meta_copyright: {
                    const std::string value = as_label();
                    if (info.copyright.empty()) {
                        info.copyright = value;
                    }
                    break;
                }
                case meta_text: {
                    // Kept as written, because this track may turn out to be a Soft Karaoke lyric
                    // sheet -- which is not known until the whole track has been read. Trimming
                    // happens later, for the pieces that turn out to be prose after all.
                    const std::string value = as_written();
                    if (!value.empty()) {
                        track_texts.push_back(value);
                    }
                    break;
                }
                case meta_lyric: {
                    const std::string value = as_written();
                    if (!value.empty()) {
                        saw_lyric_meta = true;
                        track_lyrics.push_back(value);
                    }
                    break;
                }
                case meta_marker: {
                    // As written, not trimmed: a marker may turn out to be a karaoke syllable, and
                    // the space in front of " all" is what keeps it from running into the word
                    // before it. Trimmed again below for the ones that stay markers.
                    const std::string value = as_written();
                    if (!trimmed(value).empty() && !is_loop_marker(trimmed(value))) {
                        // Kept in ticks for now: the tempo map is not complete until every track
                        // has been read, and a file is free to put its tempo changes on a later
                        // track than its markers.
                        marker_ticks.push_back(TickedText{tick, value});
                    }
                    break;
                }
                case meta_tempo: {
                    if (payload.size() >= 3) {
                        const std::uint32_t microseconds =
                            (static_cast<std::uint32_t>(payload[0]) << 16)
                            | (static_cast<std::uint32_t>(payload[1]) << 8) | payload[2];
                        ++info.tempo_changes;
                        if (microseconds > 0) {
                            tempo_changes.push_back(TempoChange{tick, microseconds});
                        }
                    }
                    break;
                }
                case meta_time_signature:
                    if (info.time_signature.empty()) {
                        info.time_signature = format_time_signature(payload);
                    }
                    break;
                case meta_key_signature:
                    if (info.key_signature.empty()) {
                        info.key_signature = format_key_signature(payload);
                    }
                    break;
                case meta_end_of_track:
                    break;
                default:
                    break;
                }
                continue;
            }

            if (status == 0xF0U || status == 0xF7U) {
                const std::uint32_t length = cursor.variable();
                const auto payload = cursor.block(length);

                // Normalised to always carry a leading F0, whichever form the file used. The F7
                // form is both an escape and a way to send a whole message, and files that declare
                // their module do sometimes use it -- which is the case the engine's own reader
                // drops, and the reason this walk exists rather than reading `Session`'s events.
                std::vector<std::uint8_t> message;
                message.reserve(payload.size() + 1);
                if (status == 0xF0U) {
                    message.push_back(0xF0U);
                } else if (payload.empty() || payload[0] != 0xF0U) {
                    message.push_back(0xF0U);
                }
                message.insert(message.end(), payload.begin(), payload.end());
                recognise(message, declared);
                continue;
            }

            // A channel voice message, and the only kind that becomes the running status.
            //
            // Both halves of that matter, and the engine's own reader carries the same pair with
            // the file that found them. Storing a meta or SysEx status would desync the track: the
            // next event omitting its status would be read as another meta and its length byte
            // swallowed as data. And a system message does not *clear* the running status either --
            // the spec says it should, but sequencers write files that resume running status
            // across a meta event, and clearing costs those files most of their notes.
            running = status;
            const std::uint8_t high = status & 0xF0U;
            channels_seen[status & 0x0FU] = true;

            // Program change and channel pressure take one operand; everything else takes two.
            const int data_bytes = (high == 0xC0U || high == 0xD0U) ? 1 : 2;
            std::array<std::uint8_t, 2> operands{};
            for (int index = 0; index < data_bytes; ++index) {
                const bool reuse = have_pending && index == 0;
                operands[static_cast<std::size_t>(index)] = reuse ? pending : cursor.byte();
            }

            if (high == 0x90U && operands[1] != 0) {
                ++track.notes;
            } else if (high == 0xB0U && operands[0] == 0x20U) {
                // Bank select LSB: on this module the map selector, and the corroborating half of
                // the vintage verdict.
                bank_lsbs.push_back(static_cast<int>(operands[1]));
            }
        }

        for (int channel = 0; channel < 16; ++channel) {
            if (channels_seen[channel]) {
                track.channels.push_back(channel);
            }
        }

        // Which pile this track's FF 01 text belongs in. A Soft Karaoke track's text is a lyric
        // sheet; anybody else's is prose about the file.
        if (looks_like_karaoke(track_texts)) {
            for (const std::string& piece : track_texts) {
                if (piece.size() >= 2 && piece[0] == '@') {
                    // @K names the format, @V its version, @L the language -- none of them worth
                    // showing. @T is the title-and-author block and @I is free information.
                    if (piece[1] == 'T' || piece[1] == 'I') {
                        add_once(info.karaoke_headings, trimmed(piece.substr(2)));
                    }
                    continue;
                }
                karaoke_pieces.push_back(piece);
            }
        } else {
            for (const std::string& piece : track_texts) {
                add_once(info.text, trimmed(piece));
            }
        }

        for (std::string& piece : track_lyrics) {
            lyric_pieces.push_back(std::move(piece));
        }

        info.tracks.push_back(std::move(track));
    }

    // FF 05 is the standard and wins where a file carries both, which a handful do -- usually a
    // Soft Karaoke file that somebody later ran through a sequencer that rewrote the lyrics
    // properly, leaving the older text in place.
    // Ordered by where they fall before anything is decided about them, because both the dialect
    // test and the sheet they might become depend on reading them in the order they are sung.
    std::stable_sort(marker_ticks.begin(), marker_ticks.end(),
                     [](const TickedText& a, const TickedText& b) { return a.tick < b.tick; });

    std::vector<std::string> marker_words;
    marker_words.reserve(marker_ticks.size());
    for (const TickedText& marker : marker_ticks) {
        marker_words.push_back(marker.text);
    }
    const bool markers_sing = markers_are_lyrics(marker_words);

    // FF 05 first, then Soft Karaoke's FF 01, then the marker dialect. A file carrying more than
    // one is usually one that has been through a second sequencer, and the later conventions are
    // the better-formed copy.
    if (saw_lyric_meta) {
        info.lyrics = join_karaoke(lyric_pieces);
    } else if (!karaoke_pieces.empty()) {
        info.lyrics = join_karaoke(karaoke_pieces);
    } else if (markers_sing) {
        info.lyrics = join_karaoke(marker_words);
    }

    // The opening tempo is the earliest by tick, not the first one read: a format-1 file's tempo map
    // is on its own track, and a file whose tracks are stored out of order would otherwise be
    // reported at whatever tempo happened to be parsed first.
    const TempoMap tempos{tempo_changes, info.division};
    if (!tempo_changes.empty()) {
        const auto earliest = std::min_element(
            tempo_changes.begin(), tempo_changes.end(),
            [](const TempoChange& a, const TempoChange& b) { return a.tick < b.tick; });
        info.initial_tempo_bpm = 60'000'000.0 / earliest->microseconds;
    }

    // Only an exact repeat is dropped: the same words at the same tick, which is what a file that
    // writes its markers onto two tracks produces. The same words *later* is a second place in the
    // song and has to stay. Keyed on the pair rather than compared against the previous entry --
    // two tracks stamping different markers on one tick interleave, and an adjacent-only test
    // would let the repeat through.
    // Markers that turned out to be a lyric sheet are not also section markers: they have been
    // joined into `lyrics` above, and listing them here as well would be the same words twice, once
    // as prose and once as several hundred rows of one syllable each.
    if (!markers_sing) {
        std::vector<std::pair<std::int64_t, std::string>> seen;
        seen.reserve(marker_ticks.size());
        for (const TickedText& marker : marker_ticks) {
            const auto key = std::pair{marker.tick, marker.text};
            if (std::find(seen.begin(), seen.end(), key) != seen.end()) {
                continue;
            }
            seen.push_back(key);
            // Trimmed here, where it is a label again rather than a syllable.
            info.markers.push_back(SongMarker{
                trimmed(marker.text), to_frames(tempos.seconds_at(marker.tick), sample_rate)});
        }
    }

    info.encoding = detect_encoding(all_text);
    info.vintage = decide(declared, bank_lsbs, info.vintage_evidence);
    info.valid = info.track_count > 0;
    return info;
}

} // namespace ts::apple
