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

            Section("Output") {
                LabeledContent("Gain") {
                    Slider(value: binding(\.outputGain), in: 0...2)
                        .help("Linear gain on the finished mix. Applied live, without a rebuild.")
                }
                Text(player.settings.outputGain.formatted(.number.precision(.fractionLength(2))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
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
                         : "\(player.underruns) dropout\(player.underruns == 1 ? "" : "s")")
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
