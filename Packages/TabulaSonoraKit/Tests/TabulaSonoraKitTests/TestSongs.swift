import Foundation

/// MIDI files small enough to build here.
///
/// The suite's other fixtures cannot be committed -- the ROM is Roland's and the corpus is
/// somebody's music -- so tests that need only a few events make their own, and then need nothing
/// from the environment but a ROM.
enum TestSong {
    /// A format 0 file at 96 ticks a quarter, wrapping one track's worth of bytes.
    static func smf(track: [UInt8]) -> Data {
        var bytes: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0, 96]
        bytes += Array("MTrk".utf8)
        bytes += withUnsafeBytes(of: UInt32(track.count).bigEndian) { Array($0) }
        bytes += track
        return Data(bytes)
    }

    /// A SysEx event as SMF spells it: the length counts everything after the `F0`.
    static func sysEx(_ payload: [UInt8]) -> [UInt8] {
        [0xF0, UInt8(payload.count)] + payload
    }

    /// The checksum GS wants: the address and data bytes complemented to a multiple of 128.
    static func rolandChecksum(_ bytes: [UInt8]) -> UInt8 {
        let sum = bytes.reduce(0) { ($0 + Int($1)) & 0x7F }
        return UInt8((128 - sum) & 0x7F)
    }

    static let gsReset = sysEx([0x41, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7F, 0x00, 0x41, 0xF7])

    /// A GS reset, one part block pointed at another channel, and a note there to render against.
    ///
    /// The block is not the part: block 0 is channel 10, blocks 1-9 are channels 1-9, and the rest
    /// follow. `40 1x 02` is that block's Rx channel.
    static func movingPartBlock(_ block: UInt8, toChannel channel: UInt8) -> Data {
        let address: [UInt8] = [0x40, 0x10 | block, 0x02, channel]
        let move = sysEx([0x41, 0x10, 0x42, 0x12] + address + [rolandChecksum(address), 0xF7])

        var track: [UInt8] = []
        track += [0x00] + gsReset
        track += [0x00] + move
        track += [0x00, 0x90 | channel, 0x3C, 0x64]
        track += [0x83, 0x00, 0x80 | channel, 0x3C, 0x00]
        track += [0x00, 0xFF, 0x2F, 0x00]
        return smf(track: track)
    }

    /// One note held far longer than a test will run, so a pause always lands in the middle of it.
    static func oneHeldNote() -> Data {
        var track: [UInt8] = []
        track += [0x00, 0x90, 0x3C, 0x64]
        track += [0x87, 0x40, 0x80, 0x3C, 0x00]  // 960 ticks -- ten beats
        track += [0x00, 0xFF, 0x2F, 0x00]
        return smf(track: track)
    }

    /// XG System On, then a bank select and a program change on channel 1.
    ///
    /// Under XG the melodic lookup is not given the bank the part was sent, which is the one case
    /// where naming only what was sent misdescribes what is sounding.
    static func xgBankSelect(msb: UInt8, program: UInt8) -> Data {
        var track: [UInt8] = []
        track += [0x00] + sysEx([0x43, 0x10, 0x4C, 0x00, 0x00, 0x7E, 0x00, 0xF7])
        track += [0x30, 0xB0, 0x00, msb]         // half a beat later, so the reset has landed
        track += [0x00, 0xB0, 0x20, 0x00]
        track += [0x00, 0xC0, program]
        track += [0x00, 0x90, 0x3C, 0x64]
        track += [0x87, 0x40, 0x80, 0x3C, 0x00]
        track += [0x00, 0xFF, 0x2F, 0x00]
        return smf(track: track)
    }

    /// One high melodic note, held for two beats. High because that is what reads a wave fast
    /// enough for the resampler to be doing visible work.
    static func oneHighNote() -> Data {
        var track: [UInt8] = []
        track += [0x00, 0x90, 0x60, 0x64]
        track += [0x83, 0x00, 0x80, 0x60, 0x00]
        track += [0x00, 0xFF, 0x2F, 0x00]
        return smf(track: track)
    }
}
