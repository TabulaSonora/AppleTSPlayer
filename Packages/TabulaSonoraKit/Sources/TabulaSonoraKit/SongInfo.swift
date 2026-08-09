import Foundation
import TabulaSonoraBridge

/// The module a file asks to be played on, as far as it says so at all.
///
/// `unstated`, `generalMIDI` and `generalMIDI2` name no tone map on purpose: a General MIDI file is
/// content to play on any of the vintages, and reading one as a request for a particular module
/// would invent an intent the file does not have.
///
/// The verdict is shown and never applied. Which module plays a file stays a preference -- the same
/// restraint the engine takes, which leaves detection to the host because a bank select LSB of 18
/// is a legitimate GS map selector and guessing would break the files that mean it.
public enum SongVintage: Int, Sendable {
    case unstated = 0
    case generalMIDI = 1
    case generalMIDI2 = 2
    case sc55 = 256
    case sc88
    case sc88Pro
    case sc8820
    case xg

    /// Whether the file said anything at all. What decides between naming a module and saying so.
    public var isStated: Bool { self != .unstated }
}

/// A marker meta event, and where in the song it falls.
public struct SongMarker: Identifiable, Equatable, Sendable {
    /// Position and text together: a file marks "Verse 1" twice because there are two of them, so
    /// neither half identifies a row alone.
    public var id: String { "\(position)-\(text)" }

    public let text: String

    /// Seconds, ready for `Player.seek(toSeconds:)`.
    ///
    /// Converted from the file's own ticks through its own tempo map, which is why the walk that
    /// finds these reads delta times it otherwise has no use for -- a file that halves its tempo
    /// halfway through puts its later markers at twice the distance the tick count suggests.
    public let position: TimeInterval
}

/// One track of the file, in the order the file stores them.
public struct SongTrack: Identifiable, Equatable, Sendable {
    /// 1-based, counting every MTrk including a format-1 tempo track that plays nothing.
    public let number: Int
    public var id: Int { number }

    /// FF 03, Sequence/Track Name.
    public let name: String

    /// FF 04, Instrument Name. Apart from `name` because a file may carry both, and because FF 04
    /// doubles as a port tag in files that predate FF 09 -- so it is often an output's name rather
    /// than an instrument's.
    public let instrument: String

    /// Channels this track sends voice messages on, ascending and zero-based. A list rather than a
    /// number because a format-0 file is one track carrying all of them.
    public let channels: [Int]

    /// Note-ons with non-zero velocity. What makes a silent tempo track visibly silent.
    public let notes: Int
}

/// The file's own loop points.
public struct SongLoop: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval

    /// Whether the file marked the end explicitly. A soft loop rewinds cleanly; a hard one has its
    /// end inferred and replays controllers the way a seek does.
    public let isSoft: Bool
}

/// Everything the loaded file says about itself, beyond the events the engine plays.
///
/// Read once when the file is loaded, from a walk of its own chunks rather than from the engine's
/// event list: the engine's reader consumes and drops every meta event except tempo, the port tags
/// and the loop markers, which is right for a renderer and leaves nothing for a reader.
///
/// A Standard MIDI File declares no text encoding, so the reader guesses one -- for the file, not
/// per string -- and every string here has already been through it.
public struct SongInfo: Equatable, Sendable {
    /// Whether a file was found and understood at all.
    public let isValid: Bool

    /// Whether the bytes on disk were something other than an SMF -- an XMI, a MUS, an HMI -- and
    /// had to be converted to be read. The converter reports *that* it converted rather than what
    /// from, so this is a flag and not a name.
    public let isConverted: Bool

    /// 0, 1 or 2, as the header declares.
    public let format: Int

    /// MTrk chunks found. Not the header's count, which malformed files get wrong.
    public let trackCount: Int

    /// Ticks per quarter note. Zero when the file uses SMPTE timing, which has no such thing.
    public let division: Int

    /// The *first* tempo the file sets, or nil if it sets none. Not an average: a file that ritards
    /// to a halt has a meaningful opening tempo and a meaningless mean.
    public let initialTempoBPM: Double?

    /// How many times the file changes tempo -- whether the number above describes the piece or
    /// only its first bar.
    public let tempoChanges: Int

    /// FF 58, as "4/4". Empty when the file declares none.
    public let timeSignature: String

    /// FF 59, as "C major". Empty when the file declares none.
    public let keySignature: String

    public let tracks: [SongTrack]

    /// FF 02, Copyright Notice.
    public let copyright: String

    /// FF 01, Text, minus the Soft Karaoke `@` lines. Deduplicated in order of first appearance: a
    /// file that repeats its own credit once per track is common, and listing it seventeen times is
    /// not information.
    public let text: [String]

    /// FF 06, Marker, minus the ones that only mark the loop, ordered by position.
    public let markers: [SongMarker]

    /// The lyric sheet, with no timing, assembled from whichever karaoke dialect the file uses.
    public let lyrics: String

    /// Soft Karaoke's own `@T` header lines: conventionally the title, then the author.
    public let karaokeHeadings: [String]

    /// Where the final event falls.
    ///
    /// Here rather than read from `Player.duration`, and that is not tidiness: the player's copy is
    /// refreshed from a snapshot on a display tick, which happens *after* the song name has already
    /// told every view that the file changed. A view rebuilding on the name and reading the
    /// player's duration would show the previous song's length.
    public let duration: TimeInterval

    public let loop: SongLoop?

    public let vintage: SongVintage

    /// "SC-88", "General MIDI" -- or empty when the file states nothing.
    public let vintageName: String

    /// The evidence for the verdict, for showing beside it: "GS Reset · bank select LSB 2". Empty
    /// when there was none.
    public let vintageEvidence: String

    /// Whether the file carries any prose about itself at all.
    public var hasText: Bool {
        !copyright.isEmpty || !text.isEmpty || !karaokeHeadings.isEmpty
    }

    init(_ info: TSSongInfo) {
        isValid = info.isValid
        isConverted = info.isConverted
        format = info.format
        trackCount = info.trackCount
        division = info.division
        initialTempoBPM = info.initialTempoBPM > 0 ? info.initialTempoBPM : nil
        tempoChanges = info.tempoChanges
        timeSignature = info.timeSignature
        keySignature = info.keySignature
        copyright = info.copyright
        text = info.text
        lyrics = info.lyrics
        karaokeHeadings = info.karaokeHeadings
        duration = TimeInterval(info.length) / Player.sampleRate
        vintage = SongVintage(rawValue: info.vintage.rawValue) ?? .unstated
        vintageName = info.vintageName
        vintageEvidence = info.vintageEvidence

        tracks = info.tracks.map { track in
            SongTrack(number: track.number,
                      name: track.name,
                      instrument: track.instrument,
                      channels: track.channels.map(\.intValue),
                      notes: track.notes)
        }

        markers = info.markers.map { marker in
            SongMarker(text: marker.text,
                       position: TimeInterval(marker.position) / Player.sampleRate)
        }

        loop = info.hasLoop
            ? SongLoop(start: TimeInterval(info.loopStart) / Player.sampleRate,
                       end: TimeInterval(info.loopEnd) / Player.sampleRate,
                       isSoft: info.loopSoft)
            : nil
    }
}
