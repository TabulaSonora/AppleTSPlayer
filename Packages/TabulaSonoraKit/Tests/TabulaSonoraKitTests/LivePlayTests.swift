import Foundation
import Testing
import TabulaSonoraBridge

/// A stopped transport is not a silent instrument.
///
/// The two halves of that are separate defects and both are audible: a keyboard has to sound while
/// nothing is playing, and a song's held chord has to stop when the transport does. They meet in the
/// render loop, which renders whenever there is sound to make and steps the sequencer only when the
/// transport is running.
///
/// Driven through the ring, the way `RingTests` does, because that is the only place this path can
/// be observed outside CoreAudio.
struct LivePlayTests {
    private static var romPath: String? { ProcessInfo.processInfo.environment["TS_SCCORE_DLL"] }

    /// Drains the ring the way an audio callback would, returning the loudest sample it saw.
    private func drain(_ engine: TSEngine, blocks: Int, frames: Int = 512) -> Float {
        var peak: Float = 0
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)

        for _ in 0..<blocks {
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    _ = TSEngineRingRead(engine.ringHandle, l.baseAddress!, r.baseAddress!,
                                         UInt32(frames))
                }
            }
            peak = max(peak, left.map(abs).max() ?? 0, right.map(abs).max() ?? 0)
            Thread.sleep(forTimeInterval: Double(frames) / 32000)
        }
        return peak
    }

    /// The defect this exists for: with no song loaded the transport never starts, so a render loop
    /// that renders only for a running song produced nothing at all from a keyboard.
    @Test(.enabled(if: romPath != nil))
    func aLiveNoteSoundsWithNoSongLoaded() throws {
        let engine = TSEngine()
        try engine.loadROM(atPath: Self.romPath!, verifyFully: false)

        #expect(engine.isPaused, "nothing is loaded, so the transport is stopped")
        #expect(drain(engine, blocks: 4) == 0, "silence until something is played")

        engine.sendChannel(onPort: 0, status: 0x90, data1: 60, data2: 100)
        #expect(drain(engine, blocks: 12) > 0, "a key pressed with the transport stopped is silent")
    }

    /// And the tail of one just let go: a note-off must not cut the release short by putting the
    /// render loop back to sleep on top of it.
    @Test(.enabled(if: romPath != nil))
    func aReleasedLiveNoteKeepsSounding() throws {
        let engine = TSEngine()
        try engine.loadROM(atPath: Self.romPath!, verifyFully: false)

        engine.sendChannel(onPort: 0, status: 0x90, data1: 60, data2: 100)
        _ = drain(engine, blocks: 6)

        engine.sendChannel(onPort: 0, status: 0x80, data1: 60, data2: 0)
        #expect(drain(engine, blocks: 4) > 0, "the release was cut off rather than rendered")
    }

    /// Pausing has to cut what the song was holding.
    ///
    /// A stopped transport still renders so the keyboard stays playable, but the sequencer is not
    /// advancing -- so before All Sound Off was sent on pause, a note held across one never reached
    /// its note-off and sounded until playback resumed.
    @Test(.enabled(if: romPath != nil))
    func pausingCutsANoteTheSongWasHolding() throws {
        let engine = TSEngine()
        try engine.loadROM(atPath: Self.romPath!, verifyFully: false)

        let song = URL.temporaryDirectory.appending(path: "tabula-sonora-held-note.mid")
        try TestSong.oneHeldNote().write(to: song)
        defer { try? FileManager.default.removeItem(at: song) }
        try engine.loadSong(atPath: song.path(percentEncoded: false))

        engine.isPaused = false
        #expect(drain(engine, blocks: 8) > 0, "the held note should be sounding")

        engine.isPaused = true

        // Past whatever was already queued when the pause landed -- the ring holds a lead's worth
        // of audio rendered before it, and that audio is not the defect.
        _ = drain(engine, blocks: 10)

        #expect(drain(engine, blocks: 6) == 0, "the song's note went on sounding through the pause")
    }

    /// Pausing must not cost the player its keyboard: All Sound Off silences, it does not stop the
    /// instrument answering.
    @Test(.enabled(if: romPath != nil))
    func aLiveNoteStillSoundsAfterPausingASong() throws {
        let engine = TSEngine()
        try engine.loadROM(atPath: Self.romPath!, verifyFully: false)

        let song = URL.temporaryDirectory.appending(path: "tabula-sonora-held-note-2.mid")
        try TestSong.oneHeldNote().write(to: song)
        defer { try? FileManager.default.removeItem(at: song) }
        try engine.loadSong(atPath: song.path(percentEncoded: false))

        engine.isPaused = false
        _ = drain(engine, blocks: 6)
        engine.isPaused = true
        _ = drain(engine, blocks: 12)

        engine.sendChannel(onPort: 0, status: 0x90, data1: 72, data2: 100)
        #expect(drain(engine, blocks: 10) > 0, "a paused transport stopped answering the keyboard")
    }
}
