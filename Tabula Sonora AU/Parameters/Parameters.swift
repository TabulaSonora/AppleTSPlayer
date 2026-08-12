//
//  Parameters.swift
//  Tabula Sonora AU
//

import AudioToolbox
import Foundation
import TabulaSonoraKit

/// The parameter tree, which is the engine's settings as a host sees them.
///
/// The indexed ones are pickers in every host that draws a generic view, and the strings beside them
/// are what it shows. Their order is the order of `ToneMap.allCases` and of the two arrays below --
/// an index here is meaningless on its own, so the mapping back is in one place, in
/// `EngineSettings+Parameters.swift`, rather than repeated at each use.
let Tabula_Sonora_AUParameterSpecs = ParameterTreeSpec {
    ParameterGroupSpec(identifier: "voice", name: String(localized: "Voice")) {
        ParameterSpec(
            address: .toneMap,
            identifier: "toneMap",
            name: String(localized: "Module"),
            units: .indexed,
            valueRange: 0...AUValue(ToneMap.allCases.count - 1),
            defaultValue: AUValue(ToneMap.allCases.firstIndex(of: .sc8820) ?? 3),
            valueStrings: EngineSettings.moduleNames
        )

        ParameterSpec(
            address: .ports,
            identifier: "ports",
            name: String(localized: "Parts"),
            units: .indexed,
            valueRange: 0...AUValue(EngineSettings.portChoices.count - 1),
            defaultValue: 1,
            valueStrings: EngineSettings.portNames
        )

        ParameterSpec(
            address: .polyphony,
            identifier: "polyphony",
            name: String(localized: "Polyphony"),
            units: .indexed,
            valueRange: 0...AUValue(EngineSettings.polyphonyChoices.count - 1),
            defaultValue: 0,
            valueStrings: EngineSettings.polyphonyNames
        )

        // Off, unlike the engine's own default and unlike the app's.
        //
        // The engine ships this on -- a wider kernel with the module's pitch-increment ceiling
        // lifted -- and that is right for a player, where the point is to sound good. A plugin's
        // claim is narrower: that it is the Sound Canvas voice. Defaulting one resampler to the
        // module and leaving the other wide would make it neither, so the two move together and
        // both start where the hardware is. Either can still be turned on.
        ParameterSpec(
            address: .extendedResampler,
            identifier: "extendedResampler",
            name: String(localized: "Extended resampler"),
            units: .boolean,
            valueRange: 0...1,
            defaultValue: 0
        )

        // The other resampler, and the only one the app has no use for: it plays at the engine's
        // own rate and lets CoreAudio convert, where a plugin has to do it here. Off, for the
        // reason above -- it is `tg_output_filter`, the allpass into a linear interpolator that
        // shaped the original plugin at every rate but 32 kHz.
        ParameterSpec(
            address: .extendedOutputResampler,
            identifier: "extendedOutputResampler",
            name: String(localized: "Extended output resampler"),
            units: .boolean,
            valueRange: 0...1,
            defaultValue: 0
        )
    }

    ParameterGroupSpec(identifier: "effects", name: String(localized: "Effects")) {
        ParameterSpec(address: .reverb, identifier: "reverb",
                      name: String(localized: "Reverb"),
                      units: .boolean, valueRange: 0...1, defaultValue: 1)

        ParameterSpec(address: .chorus, identifier: "chorus",
                      name: String(localized: "Chorus"),
                      units: .boolean, valueRange: 0...1, defaultValue: 1)

        ParameterSpec(address: .delayEffect, identifier: "delay",
                      name: String(localized: "Delay"),
                      units: .boolean, valueRange: 0...1, defaultValue: 1)

        ParameterSpec(address: .insertionEffects, identifier: "insertionEffects",
                      name: String(localized: "Insertion effects"),
                      units: .boolean, valueRange: 0...1, defaultValue: 1)
    }

    ParameterGroupSpec(identifier: "output", name: String(localized: "Output")) {
        ParameterSpec(
            address: .gain,
            identifier: "gain",
            name: String(localized: "Output gain"),
            units: .linearGain,
            valueRange: EngineSettings.gainBounds,
            defaultValue: 1.0
        )
    }
}

extension ParameterSpec {
    init(
        address: Tabula_Sonora_AUParameterAddress,
        identifier: String,
        name: String,
        units: AudioUnitParameterUnit,
        valueRange: ClosedRange<AUValue>,
        defaultValue: AUValue,
        unitName: String? = nil,
        flags: AudioUnitParameterOptions = [AudioUnitParameterOptions.flag_IsWritable, AudioUnitParameterOptions.flag_IsReadable],
        valueStrings: [String]? = nil,
        dependentParameters: [NSNumber]? = nil
    ) {
        self.init(address: address.rawValue,
                  identifier: identifier,
                  name: name,
                  units: units,
                  valueRange: valueRange,
                  defaultValue: defaultValue,
                  unitName: unitName,
                  flags: flags,
                  valueStrings: valueStrings,
                  dependentParameters: dependentParameters)
    }
}
