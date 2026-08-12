//
//  Tabula_Sonora_AUMainView.swift
//  Tabula Sonora AU
//

import SwiftUI
import TabulaSonoraKit

/// The plugin's panel: what it is playing through, and the handful of settings that change it.
///
/// Deliberately not the app's mixer. A plugin's window is small, a host already draws faders for
/// everything it hosts, and the parts a mixer would show are the file's -- and there is no file
/// here. What is worth the space is the state a musician cannot otherwise see: whether the ROM was
/// found, which module the voice is resolving against, and how many voices are sounding.
struct Tabula_Sonora_AUMainView: View {
    var parameterTree: ObservableAUParameterGroup
    weak var audioUnit: Tabula_Sonora_AUAudioUnit?

    @State private var romName: String?
    @State private var failure: String?
    @State private var voices = 0
    @State private var capacity = 0
    @State private var isXG = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if let failure {
                missingROM(failure)
            } else {
                voice
                effects
                output
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: failure == nil ? 340 : 220)
        .task { await follow() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tabula Sonora")
                    .font(.headline)

                Text(romName ?? String(localized: "No ROM"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if failure == nil {
                // The number that says the engine is alive. A plugin with no transport of its own
                // has nothing else moving on it between notes.
                Text(isXG ? "XG · \(voices)/\(capacity)" : "\(voices)/\(capacity)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(voices > 0 ? Color.accentColor : Color.secondary)
                    .help("Voices sounding, of the polyphony the engine was built with")
            }
        }
    }

    private func missingROM(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)

            // The plugin cannot ask for the file itself, and should not: the ROM is a 27 MB library
            // out of a licensed install, and a file picker appearing inside a session is the wrong
            // place to go looking for it. The app imports it once, into a container both can read.
            // One literal, not two joined: a concatenation is an expression, and an expression
            // never reaches the string catalogue -- it would ship in English in every language.
            Text("Open Tabula Sonora Player and import SCCore.dll there. This plugin reads it from the same place.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Look again") { audioUnit?.retryROM() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Settings

    private var voice: some View {
        VStack(alignment: .leading, spacing: 10) {
            picker(String(localized: "Module"),
                   parameter: parameterTree.voice.toneMap,
                   labels: EngineSettings.moduleNames)
                .help("Which module's tone map program changes resolve against")

            picker(String(localized: "Parts"),
                   parameter: parameterTree.voice.ports,
                   labels: EngineSettings.portNames)
                .help("The hardware has two ports. More is an extension, for files that want it.")

            picker(String(localized: "Polyphony"),
                   parameter: parameterTree.voice.polyphony,
                   labels: EngineSettings.polyphonyNames)
                .help("Voices before the engine starts stealing them")

            toggle(String(localized: "Extended resampler"),
                   parameter: parameterTree.voice.extendedResampler)
                .help("A wider kernel, and no ceiling on how fast a wave is read. Off is the module.")

            toggle(String(localized: "Extended output resampler"),
                   parameter: parameterTree.voice.extendedOutputResampler)
                .help("How the engine's 32 kHz reaches this host's rate. Off is the module's own.")
        }
    }

    private var effects: some View {
        HStack(spacing: 16) {
            toggle(String(localized: "Reverb"), parameter: parameterTree.effects.reverb)
            toggle(String(localized: "Chorus"), parameter: parameterTree.effects.chorus)
            toggle(String(localized: "Delay"), parameter: parameterTree.effects.delay)
            toggle(String(localized: "Insert"), parameter: parameterTree.effects.insertionEffects)
                .help("Per-part insertion effects, which a file selects over SysEx")
        }
        .font(.callout)
    }

    private var output: some View {
        let gain = parameterTree.output.gain as ObservableAUParameter

        return HStack {
            Text("Gain")
                .font(.callout)

            Slider(value: Binding(get: { gain.value }, set: { gain.value = $0 }),
                   in: gain.min...gain.max,
                   onEditingChanged: gain.onEditingChanged)

            // A percentage, although the setting is a linear multiplier: "120%" says what moving
            // the handle did, where "1.20" only says what it is called.
            Text("\(Int((gain.value * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: - Controls over a parameter

    /// An indexed parameter as a picker. The index *is* the value, so the labels have to be the
    /// ones the parameter was built with -- see `EngineSettings.moduleNames` and its neighbours.
    private func picker(_ title: String,
                        parameter: ObservableAUParameter,
                        labels: [String]) -> some View {
        Picker(title, selection: Binding(get: { Int(parameter.value.rounded()) },
                                         set: { parameter.value = AUValue($0) })) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                Text(label).tag(index)
            }
        }
    }

    private func toggle(_ title: String, parameter: ObservableAUParameter) -> some View {
        Toggle(title, isOn: Binding(get: { parameter.boolValue },
                                    set: { parameter.boolValue = $0 }))
    }

    // MARK: - What the engine is doing

    /// Ten times a second while the panel is on screen, and never when it is not.
    ///
    /// A plugin outlives its window -- a host closes the view and goes on rendering for hours -- so
    /// this belongs to the view's lifetime rather than the audio unit's. `task` cancels it when the
    /// panel goes away, which is the whole reason it is written this way.
    private func follow() async {
        while !Task.isCancelled {
            if let audioUnit {
                romName = audioUnit.instrument.romName
                failure = audioUnit.instrument.hasROM ? nil
                    : (audioUnit.romFailure ?? String(localized: "Loading the Sound Canvas ROM…"))

                voices = audioUnit.instrument.activeVoices
                capacity = audioUnit.instrument.voiceCapacity
                isXG = audioUnit.instrument.isXGMode
            }

            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
