import Foundation
import Testing
import TabulaSonoraBridge

/// The real-time path, without a sound card.
///
/// `TSEngineRingRead` is the one function an audio callback is allowed to touch, and everything
/// behind it -- the render thread, the ring, the flush protocol -- only ever runs for real inside
/// CoreAudio, where nothing can be asserted. Driving it directly is how that path gets tested at
/// all: if audio comes out here, the only thing left between this and the speakers is `AVAudioEngine`.
struct RingTests {
    private static var romPath: String? { ProcessInfo.processInfo.environment["TS_SCCORE_DLL"] }
    private static var midiPath: String? { ProcessInfo.processInfo.environment["TS_TEST_MIDI"] }

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

            // A callback runs every `frames / 32000` seconds. Pacing to that is what gives the
            // render thread a chance to stay ahead, exactly as it must in the real thing.
            Thread.sleep(forTimeInterval: Double(frames) / 32000)
        }
        return peak
    }

    @Test(.enabled(if: romPath != nil && midiPath != nil))
    func aPlayingSongReachesTheRing() throws {
        let engine = TSEngine()
        try engine.loadROM(atPath: Self.romPath!, verifyFully: false)
        try engine.loadSong(atPath: Self.midiPath!)

        // Paused, the ring is meant to stay empty -- and starvation is expected, so it must not be
        // counted as a dropout.
        #expect(engine.isPaused)
        let silence = drain(engine, blocks: 4)
        #expect(silence == 0, "a paused transport should put nothing in the ring")

        engine.isPaused = false

        // Two seconds of audio. Long enough to get past a quiet intro on most files.
        let peak = drain(engine, blocks: 125)
        #expect(peak > 0.001, "nothing reached the ring while playing (peak \(peak))")

        let snapshot = engine.snapshot()
        #expect(snapshot.position > 0, "the transport did not advance")

        // The point of the ring: the render thread stays far enough ahead that the callback is
        // never starved. Any dropout here is a real one, since starvation is only expected while
        // paused or flushing.
        #expect(snapshot.underruns == 0, "the render thread could not keep up")

        engine.isPaused = true
    }

    /// A paused transport is the one time an empty ring is exactly what was asked for.
    ///
    /// The device goes on pulling while paused, so the ring drains and every callback after that
    /// comes up short. Counting those as dropouts fills the display with faults that are just a
    /// stopped transport -- and hides the real ones among them.
    @Test(.enabled(if: romPath != nil && midiPath != nil))
    func pausingCountsNoDropouts() throws {
        let engine = TSEngine()
        try engine.loadROM(atPath: Self.romPath!, verifyFully: false)
        try engine.loadSong(atPath: Self.midiPath!)

        engine.isPaused = false
        _ = drain(engine, blocks: 60)
        #expect(engine.snapshot().underruns == 0, "dropouts before the pause")

        engine.isPaused = true

        // Long enough to drain the whole lead several times over -- which is the point: the ring
        // must be allowed to run dry here without any of it being counted.
        _ = drain(engine, blocks: 120)
        #expect(engine.snapshot().underruns == 0,
                "a paused transport counted \(engine.snapshot().underruns) dropouts")

        // And resuming must not count the refill either.
        engine.isPaused = false
        _ = drain(engine, blocks: 60)
        #expect(engine.snapshot().underruns == 0, "resuming counted dropouts")

        engine.isPaused = true
    }

    /// A device block bigger than the configured buffer must not starve the callback.
    ///
    /// This is what an iOS device does when its screen goes off: it enlarges its I/O block to save
    /// power. A lead shorter than one block can never satisfy a single callback however fast the
    /// engine renders, so the producer has to follow the consumer up rather than hold the setting.
    @Test(.enabled(if: romPath != nil && midiPath != nil))
    func aBlockLargerThanTheBufferStillKeepsUp() throws {
        let engine = TSEngine()
        engine.latencyMilliseconds = TSEngine.minimumLatencyMilliseconds  // 10 ms = 320 frames
        try engine.loadROM(atPath: Self.romPath!, verifyFully: false)
        try engine.loadSong(atPath: Self.midiPath!)
        engine.isPaused = false

        // 4096 frames is 128 ms at the engine's rate -- an order of magnitude past the setting.
        let peak = drain(engine, blocks: 20, frames: 4096)

        #expect(peak > 0.001, "nothing reached the ring at a 128 ms block")
        let dropouts = engine.snapshot().underruns
        #expect(dropouts == 0, "a block larger than the buffer starved the callback: \(dropouts)")

        engine.isPaused = true
    }

    /// The lowest buffer the engine offers has to actually work, or offering it is a trap.
    @Test(.enabled(if: romPath != nil && midiPath != nil))
    func theSmallestBufferStillKeepsUp() throws {
        let engine = TSEngine()
        engine.latencyMilliseconds = TSEngine.minimumLatencyMilliseconds
        #expect(engine.latencyMilliseconds == TSEngine.minimumLatencyMilliseconds)

        try engine.loadROM(atPath: Self.romPath!, verifyFully: false)
        try engine.loadSong(atPath: Self.midiPath!)
        engine.isPaused = false

        // Small blocks, as a low-latency device would ask for.
        let peak = drain(engine, blocks: 250, frames: 128)
        #expect(peak > 0.001, "nothing reached the ring at the smallest buffer")
        #expect(engine.snapshot().underruns == 0,
                "the render thread could not keep a \(TSEngine.minimumLatencyMilliseconds) ms lead")

        engine.isPaused = true
    }

    @Test(.enabled(if: romPath != nil && midiPath != nil))
    func seekingFlushesWhatWasQueued() throws {
        let engine = TSEngine()
        try engine.loadROM(atPath: Self.romPath!, verifyFully: false)
        try engine.loadSong(atPath: Self.midiPath!)
        engine.isPaused = false

        _ = drain(engine, blocks: 30)

        let target = Int64(30 * 32000)
        engine.seek(toFrame: target)
        _ = drain(engine, blocks: 30)

        // The seek is applied on the render thread, and the position that comes back is what is
        // *audible* -- so it trails the target by at most the ring's lead, never precedes it.
        let position = engine.snapshot().position
        #expect(position > target - Int64(32000),
                "expected to land near frame \(target), got \(position)")

        engine.isPaused = true
    }
}
