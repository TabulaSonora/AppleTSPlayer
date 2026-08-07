//
//  Tabula_Sonora_PlayerApp.swift
//  Tabula Sonora Player
//
//  Created by Kevin López Brante on 06-08-26.
//

import SwiftUI
import TabulaSonoraKit

@main
struct Tabula_Sonora_PlayerApp: App {
    @State private var player = Player()
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(player)
                .environment(library)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open MIDI File…") { library.isPresentingSongImporter = true }
                    .keyboardShortcut("o")
                    .disabled(player.romName == nil)

                Divider()

                Button("Import Sound Canvas ROM…") { library.isPresentingROMImporter = true }
            }

            CommandMenu("Playback") {
                Button(player.isPlaying ? "Pause" : "Play") { player.togglePlaying() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(player.songName == nil)

                Toggle("Loop", isOn: Binding(get: { player.isLooping },
                                             set: { player.isLooping = $0 }))
                    .keyboardShortcut("l")

                Divider()

                Button("Panic", action: player.panic)
                    .keyboardShortcut(".", modifiers: .command)
            }
        }

        #if os(macOS)
        // The engine controls belong here rather than beside the transport: they are preferences,
        // they persist, and none of them is something to reach for while listening. It also gives
        // the mixer the whole window.
        Settings {
            EngineControlsView()
                .environment(player)
                .frame(width: 420, height: 480)
        }
        #endif
    }
}
