//
//  PlayerView.swift
//  Tabula Sonora Player
//

import SwiftUI
import TabulaSonoraKit

struct PlayerView: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library

    @Binding var failure: Failure?

    var body: some View {
        #if os(macOS)
        // No engine panel here: those are preferences, and they live in the Settings scene where
        // ⌘, reaches them. The window is the transport and the mixer.
        VStack(spacing: 0) {
            TransportView(failure: $failure)
            Divider()
            MixerView()
        }
        .frame(minWidth: 480, minHeight: 520)
        #else
        NavigationStack {
            VStack(spacing: 0) {
                TransportView(failure: $failure)
                Divider()
                MixerView()
            }
            .navigationTitle(player.songName ?? "Tabula Sonora")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Open", systemImage: "folder") {
                        library.isPresentingSongImporter = true
                    }
                    .help("Open a MIDI file")
                }
                ToolbarItem(placement: .secondaryAction) {
                    NavigationLink {
                        EngineControlsView()
                    } label: {
                        Label("Engine", systemImage: "slider.horizontal.3")
                    }
                    .help("Voice, effects, output and buffer settings")
                }
            }
        }
        #endif
    }
}
