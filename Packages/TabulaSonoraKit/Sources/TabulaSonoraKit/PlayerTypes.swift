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
                         outputGain: outputGain)
    }
}

/// One part's state, as of the last block the render thread produced.
public struct PartState: Identifiable, Equatable, Sendable {
    /// `port * 16 + channel`. Also the id, since it is the part's identity.
    public let index: Int
    public var id: Int { index }

    public let program: Int
    public let bank: Int
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
    /// The tone map this part resolves against, which under XG is not the configured one.
    public let map: ToneMap
    /// The sounding instrument's name -- the tone's, or the kit's on a drum part.
    public let name: String

    /// The part as a player would number it: port letter and 1-based channel, e.g. "A1", "B16".
    public var label: String {
        let port = index / 16
        let channel = index % 16 + 1
        let letter = String(UnicodeScalar(UInt8(65 + port)))
        return "\(letter)\(channel)"
    }

    init(_ state: TSPartState) {
        index = state.index
        program = state.program
        bank = state.bank
        volume = state.volume
        expression = state.expression
        pan = state.pan
        voices = state.voices
        isMuted = state.muted
        isSoloed = state.soloed
        isPresent = state.present
        isDrums = state.drums
        kit = state.kit >= 0 ? state.kit : nil
        map = ToneMap(rawValue: state.map.rawValue) ?? .sc8820
        name = state.name
    }
}
