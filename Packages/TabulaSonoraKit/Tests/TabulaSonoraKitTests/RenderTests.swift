import Foundation
import Testing
import TabulaSonoraBridge

/// End-to-end renders through the bridge, without an audio device.
///
/// These need a `SCCore.dll` and a MIDI file, which cannot be committed, so they *skip* rather than
/// fail when the environment does not name them -- the same convention the engine's own suite uses
/// for its Roland-derived fixtures.
///
///     TS_SCCORE_DLL=~/SCCore.dll TS_TEST_MIDI=~/Demos/song.mid swift test
struct RenderTests {
    private static var romPath: String? { ProcessInfo.processInfo.environment["TS_SCCORE_DLL"] }
    private static var midiPath: String? { ProcessInfo.processInfo.environment["TS_TEST_MIDI"] }

    @Test(.enabled(if: romPath != nil))
    func loadsTheROMAndReportsItsName() throws {
        let engine = TSEngine()
        try engine.loadROM(atPath: Self.romPath!, verifyFully: true)
        #expect(engine.romName == "SCCore.dll")

        // No song, no device: the snapshot should still describe a live engine at rest.
        let snapshot = engine.snapshot()
        #expect(snapshot.hasROM)
        #expect(!snapshot.hasSong)
        #expect(snapshot.parts.count == 32)  // two ports, the module's own
    }

    @Test(.enabled(if: romPath != nil))
    func aWrongFileIsRefusedByIdentity() {
        let engine = TSEngine()
        #expect(throws: (any Error).self) {
            try engine.loadROM(atPath: "/usr/bin/true", verifyFully: true)
        }
    }

    @Test(.enabled(if: romPath != nil && midiPath != nil))
    func rendersASongToAWAVThatIsNotSilent() throws {
        let engine = TSEngine()
        try engine.loadROM(atPath: Self.romPath!, verifyFully: false)
        try engine.loadSong(atPath: Self.midiPath!)

        let snapshot = engine.snapshot()
        #expect(snapshot.hasSong)
        #expect(snapshot.length > 0, "the file should have a length in frames")

        let output = URL.temporaryDirectory.appending(path: "tabula-sonora-test.wav")
        try? FileManager.default.removeItem(at: output)

        var lastFraction = 0.0
        try engine.exportWAV(toPath: output.path(percentEncoded: false)) { fraction in
            lastFraction = fraction
            return true
        }

        #expect(lastFraction == 1.0)

        let data = try Data(contentsOf: output)
        #expect(data.count > 44, "a WAV needs more than its header")

        // The library writes 16-bit PCM stereo -- four bytes a frame -- so the payload should match
        // the reported length plus the 2.2 s tail the engine renders past the last event.
        let expectedFrames = Double(snapshot.length) + 2.2 * 32000
        let actualFrames = Double(data.count - 44) / 4.0
        #expect(abs(actualFrames - expectedFrames) < 32000,
                "expected about \(Int(expectedFrames)) frames, got \(Int(actualFrames))")

        // Silence would mean the chain built but never made a sound -- the failure this whole test
        // exists to catch.
        let peak = data.dropFirst(44).withUnsafeBytes { raw -> Int16 in
            raw.bindMemory(to: Int16.self).reduce(0) { Swift.max($0, Swift.abs(Int16(clamping: $1))) }
        }
        #expect(peak > 328, "the render is silent (peak \(peak) of 32767)")

        try? FileManager.default.removeItem(at: output)
    }
}
