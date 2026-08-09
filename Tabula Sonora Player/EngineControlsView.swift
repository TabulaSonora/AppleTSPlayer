//
//  EngineControlsView.swift
//  Tabula Sonora Player
//

import SwiftUI
import TabulaSonoraKit

/// The generator's construction options.
///
/// Everything but the gain rebuilds the generator when it changes. That is cheap on purpose: the
/// note renderer survives, so the 27 MB of tables are read once per session however often the
/// vintage changes, and each part's settings are carried across by replaying the messages that made
/// them. Only the sounding voices are lost.
struct EngineControlsView: View {
    @Environment(Player.self) private var player

    private static let latencyBounds =
        Double(Player.latencyRange.lowerBound)...Double(Player.latencyRange.upperBound)


    var body: some View {
        Form {
            Section("Voice") {
                Picker("Module", selection: binding(\.map)) {
                    ForEach(ToneMap.allCases) { map in
                        Text(map.name).tag(map)
                    }
                }
                .help("Which module's tone map program changes resolve against")

                Picker("Parts", selection: binding(\.ports)) {
                    Text("16 (1 port)").tag(1)
                    Text("32 (2 ports)").tag(2)
                    Text("64 (4 ports)").tag(4)
                }
                .help("The hardware has two ports. More is an extension, for files that want it.")

                Picker("Polyphony", selection: binding(\.polyphony)) {
                    Text("64 (hardware)").tag(64)
                    Text("128").tag(128)
                    Text("256").tag(256)
                }
                .help("Voices before the engine starts stealing them")
            }

            Section {
                Toggle("Extended resampler", isOn: binding(\.extendedInterpolation))
                    .help("A wider band-limiting kernel, and no ceiling on how fast a wave is read")
            } header: {
                Text("Resampler")
            } footer: {
                // Stated plainly because it is the one setting whose default is *not* the module.
                // Someone comparing this player against a Sound Canvas and hearing a glide that
                // slides where theirs stalls should be able to find out why.
                Text("The module reads a wave at no more than four times its own rate, so a "
                     + "portamento dive from high up holds before it slides. Lifting that limit "
                     + "needs the wider kernel to stay clean. Turn it off to hear the module "
                     + "exactly, limit and all.")
            }

            Section("Effects") {
                Toggle("Reverb", isOn: binding(\.reverb))
                    .help("The module's reverb send bus")

                Toggle("Chorus", isOn: binding(\.chorus))
                    .help("The module's chorus send bus")

                Toggle("Delay", isOn: binding(\.delay))
                    .help("The module's delay send bus")

                Toggle("Insertion effects", isOn: binding(\.efx))
                    .help("Per-part insertion effects, which a file selects over SysEx")
            }

            Section {
                LabeledContent("Gain") {
                    // Two decimals, which is what the stored setting keeps. It bounds the writes a
                    // drag makes as much as the precision: without it every pixel of motion is a
                    // fresh value, and each value is a settings write and a trip through the engine.
                    Slider(value: Binding(get: { player.settings.outputGain },
                                          set: { newValue in
                                              let rounded = (newValue * 100).rounded() / 100
                                              guard rounded != player.settings.outputGain else {
                                                  return
                                              }
                                              var settings = player.settings
                                              settings.outputGain = rounded
                                              player.apply(settings)
                                          }),
                           in: EngineSettings.gainRange)
                        .help("Linear gain on the finished mix. Applied live, without a rebuild.")
                }

                // A percentage, although the setting is a linear multiplier: "120%" says what
                // moving the handle did, where "1.20" only says what it is called.
                Text("\(Int((player.settings.outputGain * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } header: {
                Text("Output")
            } footer: {
                Text("The engine's own level is the left end. This only ever adds, because a file "
                     + "that needs less than the module gives it is asking for the volume control "
                     + "on the other side of the output -- and a loud one can clip on the way up.")
            }

            Section {
                LabeledContent("Buffer") {
                    Slider(value: Binding(get: { Double(player.latencyMilliseconds) },
                                          set: { player.latencyMilliseconds = Int($0) }),
                           in: Self.latencyBounds,
                           step: 5)
                        .help("\(Player.latencyRange.lowerBound)–"
                              + "\(Player.latencyRange.upperBound) ms. Takes effect immediately.")
                }

                HStack {
                    Text("\(player.latencyMilliseconds) ms")
                        .font(.caption.monospacedDigit())

                    Spacer()

                    // The number the buffer trades against. Lower it until this starts moving, then
                    // go back up -- that is the only way to find the right value for a given machine.
                    Text(player.underruns == 0
                         ? "no dropouts"
                         : "\(player.underruns) dropouts")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(player.underruns == 0 ? Color.secondary : Color.orange)
                }
            } header: {
                Text("Latency")
            } footer: {
                Text("How far ahead the engine renders. Lower answers a keyboard sooner; raise it "
                     + "if you hear dropouts.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Engine")
    }

    /// Writes the whole settings block back at once, which is what the engine wants: one rebuild
    /// rather than one per control.
    private func binding<Value>(
        _ path: WritableKeyPath<EngineSettings, Value>
    ) -> Binding<Value> {
        Binding(get: { player.settings[keyPath: path] },
                set: { newValue in
                    var settings = player.settings
                    settings[keyPath: path] = newValue
                    player.apply(settings)
                })
    }
}
