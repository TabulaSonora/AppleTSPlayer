import Foundation
import Testing
import TabulaSonoraBridge
@testable import TabulaSonoraKit

/// What a file says about itself, read from files built here byte by byte.
///
/// **These need no ROM**, and that is the point of writing them this way: the walk that reads a
/// file's metadata never touches the engine, so the cases nobody can be relied on to have -- a
/// truncated track, running status with none set, a meta event that must not become one, SMPTE
/// timing -- can be pinned on every machine rather than only where a licensed DLL and a corpus
/// happen to sit.
struct SongInfoTests {
    /// Loads a file into a ROM-less engine and reads back what it says about itself.
    ///
    /// The name is unique per call because Swift Testing runs these in parallel and the reader
    /// takes a *path*: a shared name has one test deleting the file another is halfway through
    /// loading, which fails as "missing MThd" and looks like a parser bug.
    private func info(_ data: Data, named name: String = "song") throws -> SongInfo {
        let url = URL.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString).mid")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = TSEngine()
        try engine.loadSong(atPath: url.path(percentEncoded: false))
        return SongInfo(engine.songInfo)
    }

    // MARK: Tracks

    @Test
    func aTrackIsNamedCountedAndPlacedOnItsChannels() throws {
        let conductor = TestSong.meta(0x03, "Conductor") + TestSong.tempo(500_000)
            + TestSong.endOfTrack

        var part: [UInt8] = TestSong.meta(0x03, "Lead")
        part += TestSong.meta(0x04, "Trumpet")
        part += [0x00, 0x92, 0x3C, 0x64]        // channel 3, a note
        part += [0x60, 0x92, 0x3C, 0x00]        // a note-off, which is not a note
        part += [0x00, 0x94, 0x40, 0x40]        // and one on channel 5
        part += TestSong.endOfTrack

        let song = try info(TestSong.smf(format: 1, tracks: [conductor, part]))

        #expect(song.isValid)
        #expect(song.format == 1)
        #expect(song.trackCount == 2)
        #expect(song.division == 96)
        #expect(!song.isConverted)

        #expect(song.tracks[0].name == "Conductor")
        // What makes a silent tempo track visibly silent.
        #expect(song.tracks[0].notes == 0)
        #expect(song.tracks[0].channels.isEmpty)

        #expect(song.tracks[1].number == 2)
        #expect(song.tracks[1].name == "Lead")
        #expect(song.tracks[1].instrument == "Trumpet")
        #expect(song.tracks[1].channels == [2, 4])
        // A note-on with velocity zero is a note-off, and does not count as a note.
        #expect(song.tracks[1].notes == 2)
    }

    @Test
    func runningStatusSurvivesAMetaEventAndAMetaNeverBecomesOne() throws {
        // The spec says a meta event clears the running status. Sequencers write files that resume
        // running status across one anyway, and clearing costs those files most of their notes --
        // so the reader keeps it, and this is the file that says so.
        var track: [UInt8] = [0x00, 0x90, 0x3C, 0x64]   // sets the running status
        track += TestSong.meta(0x06, "Verse 1")
        track += [0x00, 0x3E, 0x64]                     // still a note-on, under running status
        track += [0x00, 0x40, 0x64]
        track += TestSong.endOfTrack

        let song = try info(TestSong.smf(tracks: [track]))

        #expect(song.tracks[0].notes == 3)
        #expect(song.markers.map(\.text) == ["Verse 1"])
    }

    @Test
    func aChunkPromisingMoreBytesThanExistStopsAtTheEnd() throws {
        // A malformed file is the normal case here, not the exceptional one.
        var bytes: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0, 96]
        bytes += Array("MTrk".utf8) + [0, 0, 0x10, 0x00]   // 4096 bytes promised
        bytes += TestSong.meta(0x03, "Cut")
        bytes += TestSong.endOfTrack

        let song = try info(Data(bytes))

        #expect(song.isValid)
        #expect(song.tracks.count == 1)
        #expect(song.tracks[0].name == "Cut")
    }

    @Test
    func anEventCutInHalfEndsTheTrack() throws {
        // A note-on whose velocity byte the track ran out before reaching. The reader serves the
        // missing byte as a zero from a spent cursor and stops, rather than reading past the track.
        //
        // Another track follows it, and that is not incidental: `smf::load` runs over these same
        // bytes first, and it reads both operands of a channel message without checking that the
        // second is still inside the file. With this track last, that read is one byte past the
        // end -- which libc++ hardening turns into an abort and an ordinary build into UB. That is
        // an engine bug and belongs upstream in NativeTS, not to a fixture here, so the fixture
        // puts a chunk behind the malformed event and tests what this file is for.
        var bytes: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 1, 0, 2, 0, 96]

        let cut: [UInt8] = TestSong.meta(0x03, "Cut") + [0x00, 0x90, 0x3C]
        bytes += Array("MTrk".utf8) + [0, 0, 0, UInt8(cut.count)] + cut

        let whole: [UInt8] = TestSong.meta(0x03, "Whole") + TestSong.endOfTrack
        bytes += Array("MTrk".utf8) + [0, 0, 0, UInt8(whole.count)] + whole

        let song = try info(Data(bytes))

        #expect(song.tracks.count == 2)
        #expect(song.tracks[0].name == "Cut")
        #expect(song.tracks[1].name == "Whole")
    }

    @Test
    func anSMPTEFileNeverGetsAsFarAsBeingDescribed() throws {
        // The high bit set is a negative frame rate, and there is no tick per quarter note. The
        // reader has a branch for it -- it reports division 0 rather than a nonsensical number --
        // but that branch is unreachable through a loaded song, because the engine refuses these
        // files outright and nothing gets read at all. Pinned as the refusal it actually is, so
        // that a later change letting one through is a failure here rather than a blank panel.
        let url = URL.temporaryDirectory.appending(path: "smpte-\(UUID().uuidString).mid")
        try TestSong.smf(division: 0xE728,
                         tracks: [TestSong.meta(0x03, "Film") + TestSong.endOfTrack]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = TSEngine()
        #expect(throws: (any Error).self) {
            try engine.loadSong(atPath: url.path(percentEncoded: false))
        }
    }

    // MARK: Text

    @Test
    func aCreditRepeatedOnceATrackIsListedOnce() throws {
        let credit = TestSong.meta(0x01, "Sequenced by Somebody") + TestSong.endOfTrack
        let song = try info(TestSong.smf(format: 1, tracks: [credit, credit, credit]))

        #expect(song.text == ["Sequenced by Somebody"])
    }

    @Test
    func ampersandsAndAccentsSurviveAsThemselves() throws {
        // Latin-1 in the file's own bytes: an accented vowel followed by an ASCII letter is a legal
        // Shift-JIS pair, so the naive detector reads "Flèche" as kanji. The ampersand is the other
        // half -- the first real file this was pointed at was credited to "Hoagy Carmichael &
        // Stuart Gorell", which the Linux player has to escape on its way into a markup label.
        let latin1: [UInt8] = Array("Fl".utf8) + [0xE8] + Array("che & Violao".utf8)
        let track = TestSong.meta(0x02, latin1) + TestSong.endOfTrack

        let song = try info(TestSong.smf(tracks: [track]))

        #expect(song.copyright == "Flèche & Violao")
    }

    @Test
    func japaneseTextIsReadAsShiftJIS() throws {
        // "テスト" in Shift-JIS. The lead bytes are in 0x81-0x9F, the C1 control range, which no
        // Latin text carries and which is what separates this from the case above.
        let shiftJIS: [UInt8] = [0x83, 0x65, 0x83, 0x58, 0x83, 0x67]
        let track = TestSong.meta(0x03, shiftJIS) + TestSong.endOfTrack

        let song = try info(TestSong.smf(tracks: [track]))

        #expect(song.tracks[0].name == "テスト")
    }

    // MARK: Markers

    @Test
    func markersAreOrderedTimedAndFreeOfTheLoopsOwn() throws {
        // 500,000 µs a quarter at 96 ticks is 5,208 µs a tick: 192 ticks is exactly one second.
        var track: [UInt8] = TestSong.tempo(500_000)
        track += TestSong.meta(0x06, "loopStart")            // the loop scanners' own, not a marker
        track += TestSong.meta(0x06, "Verse 1", delta: 0)
        track += TestSong.meta(0x06, "Chorus", delta: 96)    // half a second in
        track += TestSong.meta(0x06, "Verse 2", delta: 96)   // one second in
        track += TestSong.endOfTrack

        let song = try info(TestSong.smf(tracks: [track]))

        #expect(song.markers.map(\.text) == ["Verse 1", "Chorus", "Verse 2"])
        #expect(song.markers[0].position == 0)
        #expect(abs(song.markers[1].position - 0.5) < 0.001)
        #expect(abs(song.markers[2].position - 1.0) < 0.001)
    }

    @Test
    func aMarkerRepeatedAtTheSameTickIsOneAndRepeatedLaterIsTwo() throws {
        // Two tracks stamping the same marker is one file writing its markers twice; the same words
        // *later* is a second place in the song, and collapsing those would lose it.
        let first = TestSong.meta(0x06, "Chorus") + TestSong.meta(0x06, "Chorus", delta: 96)
            + TestSong.endOfTrack
        let second = TestSong.meta(0x06, "Chorus") + TestSong.endOfTrack

        let song = try info(TestSong.smf(format: 1, tracks: [first, second]))

        #expect(song.markers.count == 2)
        #expect(song.markers.allSatisfy { $0.text == "Chorus" })
        #expect(song.markers[0].position == 0)
        #expect(song.markers[1].position > 0)
    }

    @Test
    func aTempoChangeMovesTheMarkersAfterIt() throws {
        // A marker's tick means nothing on its own: halving the tempo puts the later marker at twice
        // the distance the tick count suggests.
        var track: [UInt8] = TestSong.tempo(500_000)         // 120 bpm
        track += TestSong.meta(0x06, "A", delta: 96)         // half a second in
        track += TestSong.tempo(1_000_000)                   // 60 bpm from here
        track += TestSong.meta(0x06, "B", delta: 96)         // one more second, not half
        track += TestSong.endOfTrack

        let song = try info(TestSong.smf(tracks: [track]))

        #expect(abs(song.markers[0].position - 0.5) < 0.001)
        #expect(abs(song.markers[1].position - 1.5) < 0.001)
        #expect(song.tempoChanges == 2)
        #expect(song.initialTempoBPM.map { abs($0 - 120) < 0.001 } == true)
    }

    @Test
    func aSheetWrittenIntoMarkersIsReadAsLyrics() throws {
        // A third karaoke dialect: the words in FF 06, one syllable an event, keeping Soft
        // Karaoke's `\` and `/` line breaks. Read as section markers it is 800 rows of "Da", "le",
        // one of which is a clickable seek to a syllable.
        var track: [UInt8] = []
        for syllable in ["\\Hap", "py ", "birth", "day ", "/to ", "you ", "/and ", "man", "y ",
                         "/more"] {
            track += TestSong.meta(0x06, syllable)
        }
        track += TestSong.endOfTrack

        let song = try info(TestSong.smf(tracks: [track]))

        #expect(song.markers.isEmpty)
        #expect(song.lyrics.contains("Happy birthday"))
        #expect(song.lyrics.contains("\nto you"))
    }

    @Test
    func softKaraokeHeadingsAreLiftedOutOfTheLyrics() throws {
        var track: [UInt8] = TestSong.meta(0x03, "Words")
        track += TestSong.meta(0x01, "@KMIDI KARAOKE FILE")
        track += TestSong.meta(0x01, "@V0100")
        track += TestSong.meta(0x01, "@TThe Title")
        track += TestSong.meta(0x01, "@TSomebody")
        track += TestSong.meta(0x01, "\\Hap")
        track += TestSong.meta(0x01, "py")
        track += TestSong.endOfTrack

        let song = try info(TestSong.smf(tracks: [track]))

        // @K names the format and @V its version -- neither is worth showing.
        #expect(song.karaokeHeadings == ["The Title", "Somebody"])
        #expect(song.lyrics == "Happy")
        #expect(song.text.isEmpty)
    }

    // MARK: The module a file asks for

    @Test
    func aGSResetAloneIsTheSC55() throws {
        let track: [UInt8] = [0x00] + TestSong.gsReset + TestSong.endOfTrack
        let song = try info(TestSong.smf(tracks: [track]))

        #expect(song.vintage == .sc55)
        #expect(song.vintageName == "SC-55")
        #expect(song.vintageEvidence.contains("GS Reset"))
    }

    @Test
    func aBankSelectLSBRaisesTheFloorAGSResetSet() throws {
        var track: [UInt8] = [0x00] + TestSong.gsReset
        track += [0x00, 0xB0, 0x20, 0x02]        // bank select LSB 2 -- the SC-88's map
        track += TestSong.endOfTrack

        let song = try info(TestSong.smf(tracks: [track]))

        #expect(song.vintage == .sc88)
        #expect(song.vintageEvidence.contains("bank select LSB 2"))
    }

    @Test
    func aBankSelectLSBWithNoResetStatesNothing() throws {
        // Outside a GS file the LSB means whatever the file's own synthesizer decided, and the
        // corpus is full of files using 46 or 127 for something else. Reading those as a vintage is
        // exactly the guess the engine documents itself as refusing to make.
        var track: [UInt8] = [0x00, 0xB0, 0x20, 0x02]
        track += [0x00, 0xB1, 0x20, 0x7F]
        track += TestSong.endOfTrack

        let song = try info(TestSong.smf(tracks: [track]))

        #expect(song.vintage == .unstated)
        #expect(!song.vintage.isStated)
        #expect(song.vintageName.isEmpty)
        #expect(song.vintageEvidence.isEmpty)
    }

    @Test
    func aSystemModeSetFloorsAtTheSC88BecauseNoSC55HasOne() throws {
        let address: [UInt8] = [0x00, 0x00, 0x7F, 0x00]
        let modeSet = TestSong.sysEx([0x41, 0x10, 0x42, 0x12] + address
                                     + [TestSong.rolandChecksum(address), 0xF7])

        let song = try info(TestSong.smf(tracks: [[0x00] + modeSet + TestSong.endOfTrack]))

        #expect(song.vintage == .sc88)
        #expect(song.vintageEvidence.contains("no SC-55"))
    }

    @Test
    func anF7FormSysExIsStillRead() throws {
        // The F7 form is both an escape and a way to send a whole message, and the engine's own
        // reader drops it -- which is the reason this walk exists rather than reading the event
        // list. A file is free to declare its module in one.
        let payload: [UInt8] = [0xF0, 0x43, 0x10, 0x4C, 0x00, 0x00, 0x7E, 0x00, 0xF7]
        var track: [UInt8] = [0x00, 0xF7, UInt8(payload.count)]
        track += payload
        track += TestSong.endOfTrack

        let song = try info(TestSong.smf(tracks: [track]))

        #expect(song.vintage == .xg)
        #expect(song.vintageEvidence.contains("XG System On"))
    }

    @Test
    func generalMIDIIsStatedWithoutNamingAModule() throws {
        let on = TestSong.sysEx([0x7E, 0x7F, 0x09, 0x01, 0xF7])
        let song = try info(TestSong.smf(tracks: [[0x00] + on + TestSong.endOfTrack]))

        // Stated, and still no tone map: a General MIDI file is content to play on any vintage.
        #expect(song.vintage == .generalMIDI)
        #expect(song.vintageName == "General MIDI")
    }

    // MARK: Length and loop

    @Test
    func theLengthAndLoopComeFromTheEnginesOwnScanners() throws {
        var track: [UInt8] = TestSong.tempo(500_000)
        track += TestSong.meta(0x06, "loopStart", delta: 96)
        track += [0x00, 0x90, 0x3C, 0x64]
        track += TestSong.meta(0x06, "loopEnd", delta: 192)
        track += [0x00, 0x80, 0x3C, 0x00]
        track += TestSong.endOfTrack

        let song = try info(TestSong.smf(tracks: [track]))

        let loop = try #require(song.loop)
        #expect(abs(loop.start - 0.5) < 0.01)
        #expect(abs(loop.end - 1.5) < 0.01)

        // Hard, even though the file marked its end. Only the XMI/EMIDI and Touhou controller
        // dialects set `soft` in the engine's scanners; the marker dialect sets the end and leaves
        // the flag alone. Pinned as it is rather than as it reads, so that a change upstream shows
        // up here as a decision rather than as a surprise.
        #expect(!loop.isSoft)

        #expect(song.duration > 0)
    }

    @Test
    func nothingLoadedMeansNothingToSay() throws {
        let engine = TSEngine()
        let song = SongInfo(engine.songInfo)

        #expect(!song.isValid)
        #expect(song.tracks.isEmpty)
        #expect(song.markers.isEmpty)
        #expect(song.loop == nil)
    }
}
