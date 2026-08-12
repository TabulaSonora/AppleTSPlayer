//
//  EngineSettings+Parameters.swift
//  Tabula Sonora AU
//

import AudioToolbox
import TabulaSonoraKit

/// The one place a parameter index means something.
///
/// An indexed `AUParameter` is a number and a list of strings; which engine setting the number
/// stands for lives here and nowhere else, so the picker a host draws and the value the engine is
/// given cannot drift apart.
extension EngineSettings {
    /// Voices before the engine starts stealing them. The hardware's own limit is the first.
    static let polyphonyChoices = [64, 128, 256]

    /// MIDI ports, giving 16, 32 or 64 parts. The module has two.
    static let portChoices = [1, 2, 4]

    /// `gainRange` as a parameter's bounds. The engine's own level is the floor: this only ever
    /// adds, because a mix that needs less than the module gives it is asking for the fader after
    /// the plugin, not for headroom the module has already spent.
    static let gainBounds: ClosedRange<AUValue> =
        AUValue(gainRange.lowerBound)...AUValue(gainRange.upperBound)

    /// What a host's generic view and the plugin's own panel both call these values.
    ///
    /// In one place because the two have to agree: a host shows the string at the index it is
    /// setting, so a list that has drifted from `portChoices` would have people picking 32 parts and
    /// getting 64.
    static var moduleNames: [String] { ToneMap.allCases.map(\.name) }

    static var portNames: [String] {
        [String(localized: "16 (1 port)"),
         String(localized: "32 (2 ports)"),
         String(localized: "64 (4 ports)")]
    }

    static var polyphonyNames: [String] {
        [String(localized: "64 (hardware)"), "128", "256"]
    }

    /// The settings a parameter tree describes.
    ///
    /// Built from the engine's own defaults rather than from nothing: a parameter the tree does not
    /// carry -- one added to the engine and not yet to this plugin -- then reads as what the engine
    /// would have used anyway.
    static func from(_ tree: AUParameterTree) -> EngineSettings {
        var settings = EngineSettings.default
        for parameter in tree.allParameters {
            settings.take(parameter.value, from: parameter.address)
        }
        return settings
    }

    mutating func take(_ value: AUValue, from address: AUParameterAddress) {
        let index = Int(value.rounded())

        switch Tabula_Sonora_AUParameterAddress(rawValue: address) {
        case .gain:
            outputGain = Double(value)
        case .toneMap:
            map = ToneMap.allCases.indices.contains(index) ? ToneMap.allCases[index] : .sc8820
        case .polyphony:
            polyphony = Self.polyphonyChoices.indices.contains(index)
                ? Self.polyphonyChoices[index] : 64
        case .ports:
            ports = Self.portChoices.indices.contains(index) ? Self.portChoices[index] : 2
        case .reverb:
            reverb = value > 0.5
        case .chorus:
            chorus = value > 0.5
        case .delayEffect:
            delay = value > 0.5
        case .insertionEffects:
            efx = value > 0.5
        case .extendedResampler:
            extendedInterpolation = value > 0.5
        case .extendedOutputResampler:
            extendedOutputResampler = value > 0.5
        default:
            break
        }
    }
}
