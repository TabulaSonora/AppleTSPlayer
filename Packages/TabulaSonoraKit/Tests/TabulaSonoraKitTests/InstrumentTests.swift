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

    /// Every send off, for the two tests below that measure where a note went rather than how it
    /// sounded. All Sound Off takes the voices but not the reverb behind them, and a tail ringing
    /// under the next measurement is indistinguishable from a port that was supposed to be silent
    /// and was not.
    private static func silenceEffects(_ settings: inout TSEngineSettings) {
        settings.reverb = false
        settings.chorus = false
        settings.delay = false
        settings.efx = false
    }

    /// Silences one port's channel 1 and plays each port's channel 1 in turn.
    ///
    /// The returned row is the peak heard for each port played, so the port that was silenced is
    /// the one entry in it that should be zero. `configured` and `played` are separate because the
    /// folding test needs to play more ports than the engine has: the volumes may only be set on
    /// ports that exist, or the very fold being measured would send one of them back to full.
    private func peaksSilencing(_ silenced: Int32, on instrument: TSInstrument,
                                configured: Int32, played: Int32) -> [Float] {
        let handle = instrument.handle

        // Channel 1 of every port, so nothing but the port distinguishes one message from the next.
        for port in 0..<configured {
            TSInstrumentSendChannel(handle, port, 0xB0, 7, port == silenced ? 0 : 100)
        }

        return (0..<played).map { played in
            // All Sound Off everywhere first: a peak has to come from this note and not from the
            // tail of the last one. It takes no controller with it -- that is CC#121 -- so the
            // volumes set above survive it.
            for port in 0..<configured {
                TSInstrumentSendChannel(handle, port, 0xB0, 120, 0)
            }
            _ = render(instrument, blocks: 8, frames: 512)

            // And measured after the settle, not across it: a silenced port reads as the tail of
            // whatever sounded before it otherwise, and the test passes or fails on the order the
            // ports happen to be played in.
            let residue = render(instrument, blocks: 4, frames: 512)
            #expect(residue < 0.001,
                    "something was still sounding before port \(played) was played (\(residue))")

            TSInstrumentSendChannel(handle, played, 0x90, 60, 100)
            let peak = render(instrument, blocks: 24, frames: 512)
            TSInstrumentSendChannel(handle, played, 0x80, 60, 0)
            return peak
        }
    }

    /// A port is its own sixteen parts, and the port number on a message is the only thing that says
    /// which sixteen a message is for.
    ///
    /// This is what an Audio Unit's cable number buys: the framework hands `AUMIDIEvent.cable` to
    /// the render block untouched, `TSInstrumentKernel` masks it to four and passes it here, and
    /// four cables therefore reach 64 parts from one instance. Testing it by ear rather than by
    /// bookkeeping -- turn one port's channel 1 down to nothing and play all four -- because the
    /// failure being guarded against is every port quietly collapsing onto port A, and a collapse
    /// looks perfectly healthy to anything that only asks whether a note sounded.
    @Test(.enabled(if: romPath != nil))
    func aPortNumberReachesItsOwnParts() throws {
        let instrument = TSInstrument()
        try instrument.loadROM(atPath: Self.romPath!, verifyFully: false)

        var settings = TSEngineSettingsDefault()
        settings.ports = 4
        Self.silenceEffects(&settings)
        instrument.apply(settings)
        instrument.prepare(forSampleRate: 48_000, maximumFrames: 1024)

        for silenced in Int32(0)..<4 {
            let peaks = peaksSilencing(silenced, on: instrument, configured: 4, played: 4)

            for played in Int32(0)..<4 where played != silenced {
                #expect(peaks[Int(played)] > 0.001,
                        "port \(played) went quiet when port \(silenced) was turned down")
            }
            #expect(peaks[Int(silenced)] < 0.001,
                    "port \(silenced) sounded at \(peaks[Int(silenced)]) with its volume at zero")
        }
    }

    /// A port past the configured count folds onto one that exists rather than going silent.
    ///
    /// The kernel relies on this: it masks a cable to four and hands the number over whatever the
    /// `ports` setting is, because the engine folds with `port & (ports - 1)` exactly as the module
    /// does with the sixteen USB cables it advertises over two ports of parts. Getting it wrong is
    /// silent in the worst way -- a host with four ports wired up and half of them producing nothing.
    @Test(.enabled(if: romPath != nil))
    func aPortPastTheConfiguredCountFoldsOntoOneThatExists() throws {
        let instrument = TSInstrument()
        try instrument.loadROM(atPath: Self.romPath!, verifyFully: false)

        var settings = TSEngineSettingsDefault()
        settings.ports = 2
        Self.silenceEffects(&settings)
        instrument.apply(settings)
        instrument.prepare(forSampleRate: 48_000, maximumFrames: 1024)

        // Four ports played against a two-port engine: C folds onto A, D onto B.
        let peaks = peaksSilencing(0, on: instrument, configured: 2, played: 4)

        #expect(peaks[0] < 0.001, "port A sounded with its volume at zero")
        #expect(peaks[2] < 0.001, "port C did not fold onto the silenced port A (\(peaks[2]))")
        #expect(peaks[1] > 0.001, "port B went quiet")
        #expect(peaks[3] > 0.001, "port D did not fold onto port B (\(peaks[3]))")
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
