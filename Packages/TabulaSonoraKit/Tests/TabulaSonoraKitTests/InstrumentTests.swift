import Foundation
import Testing
import TabulaSonoraBridge

/// The plugin's render path: the engine driven straight from a render block, resampled on the way
/// out.
///
/// `TSInstrumentRender` is the whole of what an Audio Unit's render block touches, and inside it is
/// the one piece of arithmetic in the bridge that has no second chance -- the interpolator's read
/// position, which decides how many engine frames a block needs and which three it has to keep for
/// the next one. Getting it wrong by one is an out-of-bounds read that a host would report as a
/// crash on a machine nobody here owns, so it is driven directly.
struct InstrumentTests {
    private static var romPath: String? { ProcessInfo.processInfo.environment["TS_SCCORE_DLL"] }

    /// Rates a host actually runs at, plus the engine's own, plus one below it.
    private static let rates: [Double] = [32_000, 44_100, 48_000, 88_200, 96_000, 22_050]

    /// Renders `blocks` blocks and returns the loudest sample seen.
    private func render(_ instrument: TSInstrument, blocks: Int, frames: Int) -> Float {
        var peak: Float = 0
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)

        for _ in 0..<blocks {
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    TSInstrumentRender(instrument.handle, l.baseAddress!, r.baseAddress!,
                                       UInt32(frames))
                }
            }
            peak = max(peak, left.map(abs).max() ?? 0, right.map(abs).max() ?? 0)
        }
        return peak
    }

    /// Every rate, and block sizes that are not multiples of anything, run long enough that the
    /// read position has wrapped through the buffer many times.
    ///
    /// With no ROM the answer is silence, which is the point: what is being tested is that the
    /// indexing survives, not that anything sounds.
    @Test
    func rendersSilenceAtEveryRateWithoutAROM() {
        for rate in Self.rates {
            let instrument = TSInstrument()
            instrument.prepare(forSampleRate: rate, maximumFrames: 4096)

            for frames in [1, 7, 64, 111, 512, 1024, 4096] {
                let peak = render(instrument, blocks: 20, frames: frames)
                #expect(peak == 0, "\(rate) Hz, \(frames)-frame blocks put something in a silent engine")
            }
        }
    }

    /// A host that changes its block size mid-stream, which is what happens when a screen sleeps.
    @Test
    func survivesABlockLargerThanItWasPreparedFor() {
        let instrument = TSInstrument()
        instrument.prepare(forSampleRate: 48_000, maximumFrames: 512)

        // Over the declared maximum: the contract is that it stays silent rather than reading past
        // the buffer it sized.
        let peak = render(instrument, blocks: 4, frames: 4096)
        #expect(peak == 0)
    }

    @Test(.enabled(if: romPath != nil))
    func aNoteSoundsAtEveryRate() throws {
        for rate in Self.rates {
            let instrument = TSInstrument()
            try instrument.loadROM(atPath: Self.romPath!, verifyFully: false)
            instrument.prepare(forSampleRate: rate, maximumFrames: 1024)

            #expect(instrument.hasROM)
            #expect(render(instrument, blocks: 4, frames: 512) == 0, "silent before the note")

            // Middle C on channel 1, fortissimo.
            TSInstrumentSendChannel(instrument.handle, 0, 0x90, 60, 100)

            // A quarter of a second at the engine's rate, whatever the output rate is.
            let blocks = Int(rate / 4 / 512)
            let peak = render(instrument, blocks: blocks, frames: 512)
            #expect(peak > 0.001, "nothing sounded at \(rate) Hz (peak \(peak))")
        }
    }

    /// The resampler read at the right speed, not merely at some speed.
    ///
    /// Every test above passes with the ratio inverted -- a note still sounds, it is just played at
    /// the wrong rate, which is the failure a plugin ships with because nobody hears 32 against 48
    /// side by side. What cannot be faked is a decay measured in seconds: the same note has to take
    /// the same time to fall away however many frames a second the host asked for.
    @Test(.enabled(if: romPath != nil))
    func aNoteDecaysOverTheSameSecondsAtEveryRate() throws {
        /// Seconds from the note's peak until it has fallen to a tenth of it.
        func decaySeconds(at rate: Double) throws -> Double {
            let instrument = TSInstrument()
            try instrument.loadROM(atPath: Self.romPath!, verifyFully: false)
            instrument.prepare(forSampleRate: rate, maximumFrames: 1024)

            TSInstrumentSendChannel(instrument.handle, 0, 0x90, 60, 100)

            let frames = 512
            let secondsPerBlock = Double(frames) / rate
            var peak: Float = 0
            var seconds = 0.0

            // Four seconds is past the end of a piano note at any rate; the loop leaves early.
            while seconds < 4.0 {
                let level = render(instrument, blocks: 1, frames: frames)
                seconds += secondsPerBlock
                peak = max(peak, level)
                if peak > 0 && level < peak * 0.1 {
                    return seconds
                }
            }
            return seconds
        }

        // A piano note takes over a second to fall this far. Asserting that here is what stops the
        // comparison below from passing on two measurements that both gave up after one block.
        let reference = try decaySeconds(at: 32_000)
        #expect(reference > 0.5, "the note decayed in \(reference)s, which is not a piano note")

        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let measured = try decaySeconds(at: rate)
            let drift = abs(measured - reference) / reference
            #expect(drift < 0.15,
                    "\(rate) Hz decayed in \(measured)s against \(reference)s at the engine's rate")
        }
    }

    /// The reason `send_sysex` exists at all: a host opens a session by resetting the module, and a
    /// GS Reset that goes nowhere leaves an engine playing as something it was not asked to be.
    @Test(.enabled(if: romPath != nil))
    func aGSResetIsHeardAndPlayingContinues() throws {
        let instrument = TSInstrument()
        try instrument.loadROM(atPath: Self.romPath!, verifyFully: false)
        instrument.prepare(forSampleRate: 48_000, maximumFrames: 1024)

        let reset: [UInt8] = [0xF0, 0x41, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7F, 0x00, 0x41, 0xF7]
        reset.withUnsafeBufferPointer {
            TSInstrumentSendSysEx(instrument.handle, 0, $0.baseAddress!, UInt32($0.count))
        }

        // The reset silences everything; a note after it still has to sound.
        TSInstrumentSendChannel(instrument.handle, 0, 0x90, 60, 100)
        #expect(render(instrument, blocks: 24, frames: 512) > 0.001)
    }

    /// Gain is the one setting a render block sets for itself, so it is the one that can be wrong
    /// without any control call being involved.
    @Test(.enabled(if: romPath != nil))
    func gainAppliesWithoutARebuild() throws {
        let instrument = TSInstrument()
        try instrument.loadROM(atPath: Self.romPath!, verifyFully: false)
        instrument.prepare(forSampleRate: 48_000, maximumFrames: 1024)

        TSInstrumentSendChannel(instrument.handle, 0, 0x90, 60, 100)
        let plain = render(instrument, blocks: 24, frames: 512)

        TSInstrumentSendChannel(instrument.handle, 0, 0x80, 60, 0)
        _ = render(instrument, blocks: 24, frames: 512)

        TSInstrumentSetGain(instrument.handle, 2.0)
        TSInstrumentSendChannel(instrument.handle, 0, 0x90, 60, 100)
        let louder = render(instrument, blocks: 24, frames: 512)

        #expect(louder > plain, "gain did not reach the mix (\(plain) then \(louder))")
    }
}
