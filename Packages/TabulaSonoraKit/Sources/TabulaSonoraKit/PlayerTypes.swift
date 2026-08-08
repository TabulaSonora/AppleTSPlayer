import Foundation
import TabulaSonoraBridge

/// Which module's tone map program changes resolve against.
public enum ToneMap: Int32, CaseIterable, Sendable, Identifiable {
    case sc55 = 1
    case sc88 = 2
    case sc88Pro = 3
    case sc8820 = 4
    case xg = 0x77

    public var id: Int32 { rawValue }

    public var name: String {
        switch self {
        case .sc55: "SC-55"
        case .sc88: "SC-88"
        case .sc88Pro: "SC-88Pro"
        case .sc8820: "SC-8820"
        case .xg: "XG"
        }
    }
}

/// The settings that live in the generator's construction options.
///
/// Changing any but `outputGain` rebuilds the generator -- though never the note renderer, so the
/// 27 MB of tables are read once per session however often the vintage changes. Part settings are
/// carried across a rebuild by replaying the messages that made them; sounding voices are not.
public struct EngineSettings: Equatable, Sendable {
    public var map: ToneMap
    /// Voices before stealing. The hardware's own limit is 64.
    public var polyphony: Int
    /// 1, 2 or 4 -- giving 16, 32 or 64 parts. The module has two.
    public var ports: Int
    public var reverb: Bool
    public var chorus: Bool
    public var delay: Bool
    public var efx: Bool

    /// The wide band-limiting resampler, and with it the removal of the pitch increment ceiling.
    ///
    /// On by default, and the one place the engine knowingly departs from `SCCore.dll`. The module
    /// pins its resampler increment at four times a wave's native rate, so a portamento glide
    /// starting three octaves up does not move until it has descended past that ceiling -- audible
    /// as a dive that holds for half a second before it slides. Upstream lifts the ceiling and fits
    /// a wider kernel to the module's own response, which leaves ordinary material sounding the
    /// same and changes only the rates the module could not reach.
    ///
    /// Off is the module as it is, ceiling and all.
    public var extendedInterpolation: Bool

    /// Linear gain on the finished mix. Applied live, without a rebuild.
    public var outputGain: Double

    /// The engine's own defaults, read from the library rather than restated here.
    public static var `default`: EngineSettings { EngineSettings(TSEngineSettingsDefault()) }

    init(_ settings: TSEngineSettings) {
        map = ToneMap(rawValue: settings.map.rawValue) ?? .sc8820
        polyphony = Int(settings.polyphony)
        ports = Int(settings.ports)
        reverb = settings.reverb
        chorus = settings.chorus
        delay = settings.delay
        efx = settings.efx
        extendedInterpolation = settings.extendedInterpolation
        outputGain = settings.outputGain
    }

    var bridged: TSEngineSettings {
        TSEngineSettings(map: TSToneMap(rawValue: map.rawValue),
                         polyphony: Int32(polyphony),
                         ports: Int32(ports),
                         reverb: reverb,
                         chorus: chorus,
                         delay: delay,
                         efx: efx,
                         extendedInterpolation: extendedInterpolation,
                         outputGain: outputGain)
    }
}

/// One part's state, as of the last block the render thread produced.
public struct PartState: Identifiable, Equatable, Sendable {
    /// `port * 16 + channel`. Also the id, since it is the part's identity.
    public let index: Int
    public var id: Int { index }

    public let program: Int

    /// Bank select MSB, which carries the variation.
    public let bank: Int

    /// Bank select LSB, which on this module names the vintage: 1-4 pick one and 0 keeps the
    /// configured default. Carried beside the MSB because the pair is what a patch list is indexed
    /// by, and either one alone identifies nothing.
    public let bankLSB: Int

    public let volume: Int
    public let expression: Int
    public let pan: Int
    /// Voices this part is sounding, including any fading after being stolen.
    public let voices: Int
    public let isMuted: Bool
    public let isSoloed: Bool
    /// Whether the loaded song addresses this part at all. A mixer shows these and hides the rest.
    public let isPresent: Bool

    /// Whether this part is sounding drums *now* -- not whether it is the drum channel. GS can
    /// route any part to the drum path over SysEx and XG does it from bank select alone, so a
    /// mixer that compares the channel number to a drum channel mislabels both directions.
    public let isDrums: Bool
    /// The kit sounding on a drum part, or nil.
    public let kit: Int?

    /// The MIDI channel this part listens on, zero-based -- **not** its slot.
    ///
    /// Parts are matched by their receive channel rather than indexed by it: GS can point several
    /// parts at one channel or detach one from every channel, so `index % 16` names the right
    /// channel only until something moves a part -- and a bulk dump moves parts by definition.
    ///
    /// -1 when no engine reported one, and 16 for the module's "off". Use `displayChannel`, which
    /// is what `label` and the mixer's ordering are built from.
    public let rxChannel: Int

    /// The channel a row shows, falling back to the slot when the part names none.
    ///
    /// A cleared snapshot reports -1 and a detached part reports 16; neither is a channel, and
    /// labelling every row "1" or "17" would be worse than the slot it came up on. A detached part
    /// is normally filtered out by `isPresent` before this matters -- it hears nothing, so nothing
    /// the file sends reaches it.
    public var displayChannel: Int {
        (0..<16).contains(rxChannel) ? rxChannel : index % 16
    }
    /// The tone map this part resolves against, which under XG is not the configured one.
    public let map: ToneMap

    /// The bank the melodic lookup is given, which under XG is not `bank`.
    public let lookupBank: Int
    /// The sounding instrument's name -- the tone's, or the kit's on a drum part.
    public let name: String

    /// The part as a player would number it: port letter and 1-based channel, e.g. "A1", "B16".
    ///
    /// The channel comes from the part's own routing, not from the slot. Labelling a row
    /// `index % 16 + 1` names the channel a part happens to start on, and goes on naming it after a
    /// bulk dump has pointed the part somewhere else. The port still comes from the slot, because a
    /// port is sixteen slots of one.
    public var label: String {
        let port = index / 16
        let letter = String(UnicodeScalar(UInt8(65 + port)))
        return "\(letter)\(displayChannel + 1)"
    }

    /// `label` spelled out, because "A1" is an abbreviation nothing else in the interface expands.
    ///
    /// Built from the same channel the label is, so the two cannot disagree about which one a part
    /// is on.
    public var address: String {
        let port = index / 16
        let letter = String(UnicodeScalar(UInt8(65 + port)))
        return "Port \(letter), channel \(displayChannel + 1)"
    }

    /// The numbers behind the name.
    ///
    /// The sounding instrument's name answers "what is this"; this answers "which entry is it",
    /// which is the question anyone comparing against a module's patch chart or a MIDI capture
    /// actually has.
    ///
    /// Programs are counted from one, as every chart and the module's own display counts them, with
    /// the wire value beside it so there is no guessing which convention is meant. Both halves of
    /// the bank select appear because neither identifies anything alone: the MSB carries the
    /// variation and the LSB names the vintage.
    public var detail: String {
        var detail = ""

        if isDrums, let kit {
            detail += "Drum kit \(kit) · "
        }

        detail += "Program \(program + 1) (PC \(program))"
        detail += " · Bank MSB \(bank), LSB \(bankLSB)"

        // Under XG the melodic lookup is not given the bank the part was sent, so saying only what
        // was sent would misdescribe what is sounding.
        if !isDrums, lookupBank != bank {
            detail += " (resolves against bank \(lookupBank))"
        }

        return detail
    }

    /// `detail` at the width a strip can actually spare.
    ///
    /// Where there is no pointer there is no tooltip, so `detail` is unreachable and the numbers it
    /// carries have to be on the row itself or nowhere. This is the same information at a third of
    /// the width: one convention for the program rather than both, named so which one is meant is
    /// still not a guess, and the bank pair colon-separated the way a patch chart prints it.
    ///
    /// The kit is left out where `detail` names it -- a drum part already carries it as a tag, and
    /// the row has no room to say it twice.
    public var numbers: String {
        var numbers = "Patch \(program + 1) · Bank \(bank):\(bankLSB)"

        // The one thing that cannot be dropped for width: under XG the part is sounding out of a
        // bank it was never sent, so the pair above is not what the lookup was given.
        if !isDrums, lookupBank != bank {
            numbers += "→\(lookupBank)"
        }

        return numbers
    }

    init(_ state: TSPartState) {
        index = state.index
        program = state.program
        bank = state.bank
        bankLSB = state.bankLSB
        volume = state.volume
        expression = state.expression
        pan = state.pan
        voices = state.voices
        isMuted = state.muted
        isSoloed = state.soloed
        isPresent = state.present
        isDrums = state.drums
        kit = state.kit >= 0 ? state.kit : nil
        rxChannel = state.rxChannel
        map = ToneMap(rawValue: state.map.rawValue) ?? .sc8820
        lookupBank = state.lookupBank
        name = state.name
    }
}
