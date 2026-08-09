import Foundation
import Testing
import TabulaSonoraBridge
@testable import TabulaSonoraKit

/// What a mixer row is allowed to call itself.
///
/// Parts are matched by their receive channel rather than indexed by it, so a strip labelled from
/// its slot names the right channel only until something moves a part -- and GS moves parts, both
/// through `40 1x 02` and through a bulk dump. The file below is the smallest thing that moves one:
/// a GS reset, then part block 1 pointed at channel 10.
///
/// Needs a ROM, because there are no parts to ask until an engine exists. It builds its own MIDI, so
/// it does not need `TS_TEST_MIDI`.
struct PartLabelTests {
    private static var romPath: String? { ProcessInfo.processInfo.environment["TS_SCCORE_DLL"] }

    /// Renders enough blocks for the events at tick zero to have been dispatched.
    private func advance(_ engine: TSEngine, blocks: Int = 12, frames: Int = 512) {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)

        for _ in 0..<blocks {
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    _ = TSEngineRingRead(engine.ringHandle, l.baseAddress!, r.baseAddress!,
                                         UInt32(frames))
                }
            }
            Thread.sleep(forTimeInterval: Double(frames) / 32000)
        }
    }

    @Test(.enabled(if: romPath != nil))
    func partsComeUpListeningOnTheirOwnChannel() throws {
        let engine = TSEngine()
        try engine.loadROM(atPath: Self.romPath!, verifyFully: false)

        // The identity mapping, which is what makes the slot look like the channel in the first
        // place: every part hears the channel its index names, on every port.
        let parts = engine.snapshot().parts
        for (index, part) in parts.enumerated() {
            #expect(part.rxChannel == index % 16, "part \(index)")
        }

        #expect(PartState(parts[0]).label == "A1")
        #expect(PartState(parts[15]).label == "A16")
        #expect(PartState(parts[16]).label == "B1")
    }

    @Test(.enabled(if: romPath != nil))
    func aMovedPartIsLabelledWithTheChannelItHears() throws {
        let engine = TSEngine()
        try engine.loadROM(atPath: Self.romPath!, verifyFully: false)

        // Block 1 is part 0. Pointed at channel 10, which is where the file then plays.
        let song = URL.temporaryDirectory.appending(path: "tabula-sonora-rx-channel.mid")
        try TestSong.movingPartBlock(1, toChannel: 9).write(to: song)
        defer { try? FileManager.default.removeItem(at: song) }

        try engine.loadSong(atPath: song.path(percentEncoded: false))
        engine.isPaused = false
        advance(engine)

        let part = engine.snapshot().parts[0]
        #expect(part.rxChannel == 9, "the SysEx should have moved part 0 onto channel 10")

        // The label is the whole point: by slot this row would still call itself A1, and go on
        // claiming a channel the file is no longer addressing.
        #expect(PartState(part).label == "A10")

        // The spelled-out form is built from the same channel, so the two cannot disagree.
        #expect(PartState(part).address == "Port A, channel 10")
    }

    /// Under XG the melodic lookup is not given the bank the part was sent, so a strip that names
    /// only what was sent misdescribes what is sounding. That is the one case the detail line has
    /// to say something extra -- and the only thing that reads `lookupBank` at all.
    @Test(.enabled(if: romPath != nil))
    func anXGPartNamesTheBankItResolvesAgainst() throws {
        let engine = TSEngine()
        try engine.loadROM(atPath: Self.romPath!, verifyFully: false)

        let song = URL.temporaryDirectory.appending(path: "tabula-sonora-xg-bank.mid")
        try TestSong.xgBankSelect(msb: 64, program: 0).write(to: song)
        defer { try? FileManager.default.removeItem(at: song) }

        try engine.loadSong(atPath: song.path(percentEncoded: false))
        engine.isPaused = false
        advance(engine, blocks: 40)

        let part = PartState(engine.snapshot().parts[0])

        #expect(engine.snapshot().xgMode, "the file should have put the engine into XG")

        // Bank MSB 64 under XG is the SFX bank, which the melodic lookup resolves as 0x7D -- while
        // the part itself was never sent that number. Naming only what was sent would have called
        // this a piano.
        #expect(part.lookupBank == 125)
        #expect(part.lookupBank != part.bank, "XG resolves against a different bank")
        #expect(part.detail.contains("resolves against bank 125"))

        // The compact form drops the kit and one of the two program conventions to fit a row, but
        // never the arrow: it is the whole difference between what was sent and what is sounding.
        //
        // The pair in front of it is 0:0, not 64:0, and that is the XG bank swap rather than a lost
        // number. Under XG the part's `bank` holds what GS would call the LSB -- 0, which is what
        // the file sent -- while the MSB of 64 lands in the engine's `xg_bank_msb` and never
        // reaches the part's own pair. What it turns into is the 125 on the right.
        #expect(part.numbers == "Patch 1 · Bank 0:0→125")
    }

    /// The numbers behind the name, which is what the strip has no room to spell out.
    @Test(.enabled(if: romPath != nil))
    func aPartSpellsOutItsAddressAndItsPatchNumbers() throws {
        let engine = TSEngine()
        try engine.loadROM(atPath: Self.romPath!, verifyFully: false)

        let part = PartState(engine.snapshot().parts[0])

        #expect(part.address == "Port A, channel 1")

        // Counted from one as every patch chart counts them, with the wire value beside it.
        #expect(part.detail.contains("Program 1 (PC 0)"))
        #expect(part.detail.contains("Bank MSB 0, LSB 0"))

        // And the form a row without a tooltip shows: the same two numbers, one convention each,
        // still labelled so neither is a guess.
        #expect(part.numbers == "Patch 1 · Bank 0:0")
    }

    /// A strip is listed if the file reaches the part, which is a question about the channel the
    /// part hears -- not about the slot that shares its number.
    @Test(.enabled(if: romPath != nil))
    func aMovedPartIsListedAndAnUnaddressedOneIsNot() throws {
        let engine = TSEngine()
        try engine.loadROM(atPath: Self.romPath!, verifyFully: false)

        let song = URL.temporaryDirectory.appending(path: "tabula-sonora-rx-present.mid")
        try TestSong.movingPartBlock(1, toChannel: 9).write(to: song)
        defer { try? FileManager.default.removeItem(at: song) }

        try engine.loadSong(atPath: song.path(percentEncoded: false))
        engine.isPaused = false
        advance(engine)

        let parts = engine.snapshot().parts

        // Part 0 now hears channel 10, which is the only channel the file sends on. Taken from the
        // slot it would have been hidden -- while being the part that sounds.
        #expect(parts[0].present, "the part the file actually reaches is not listed")

        // Part 9 still hears channel 10 as well. Two parts on one channel is legal, and both rows
        // have to appear.
        #expect(parts[9].present)

        // And a slot the file never addresses stays hidden.
        #expect(!parts[1].present)
    }
}
