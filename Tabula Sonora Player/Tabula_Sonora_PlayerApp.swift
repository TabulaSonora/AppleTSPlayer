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
        main.commands {
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

            // In the View menu, beside the sidebar item the system puts there, because that is
            // where a panel attached to the window belongs. The toolbar's toggle is the same state.
            CommandGroup(after: .sidebar) {
                Button(library.isShowingSongInfo
                       ? "Hide Song Information" : "Show Song Information") {
                    library.isShowingSongInfo.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
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

    /// The window the app is.
    ///
    /// One window on the Mac, not a group, and that is a statement about what this app is: there is
    /// one engine, one audio graph and one transport behind whatever is on screen, so a second
    /// window would be a second view of the same playing file with the same buttons -- and ⌘N would
    /// have offered it as though it were a new document. `Window` also drops "New Window" from the
    /// File menu and gives the scene a stable identity to be restored by, which a group's Nth window
    /// does not have.
    ///
    /// Elsewhere it stays a `WindowGroup`, because there it is not a choice: on iOS a group is one
    /// window on a phone anyway, and on iPadOS and visionOS taking multiple scenes away would break
    /// the platform's own way of putting an app beside another one.
    @SceneBuilder
    private var main: some Scene {
        #if os(macOS)
        Window("Tabula Sonora Player", id: "player") {
            ContentView()
                .environment(player)
                .environment(library)
        }
        .defaultSize(width: 760, height: 660)
        #else
        WindowGroup {
            ContentView()
                .environment(player)
                .environment(library)
        }
        #endif
    }
}
