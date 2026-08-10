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

    #if !os(macOS)
    /// Whether the engine panel is up as a sheet, which is how the wide layout shows it.
    @State private var isPresentingEngine = false

    /// Wide enough that pushing the panel would be the wrong move.
    ///
    /// The question is the width, not the device: a full-width `Form` pushed over an iPad reads as
    /// the app having gone somewhere else, and takes the transport off screen to show settings that
    /// apply while something is playing. On a phone -- and on an iPad in Slide Over, which is the
    /// same width problem inverted -- a push is still right, so this follows the size class rather
    /// than the idiom and lets a split view change its mind mid-session.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        #if os(macOS)
        // No engine panel here: those are preferences, and they live in the Settings scene where
        // ⌘, reaches them. The window is the transport and the mixer, with what the file says about
        // itself in an inspector beside them.
        VStack(spacing: 0) {
            TransportView(failure: $failure)
            Divider()
            MixerView()
        }
        .frame(minWidth: 480, minHeight: 520)
        // The title bar is where a Mac window says what it is showing, so the transport no longer
        // says it too -- see the header this replaces in `TransportView`.
        .navigationTitle(player.songName ?? "Tabula Sonora")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { songInfoToggle }
        }
        .inspector(isPresented: Binding(get: { library.isShowingSongInfo },
                                        set: { library.isShowingSongInfo = $0 })) {
            SongInfoView()
        }
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
                ToolbarItem(placement: .secondaryAction) { songInfoToggle }
                ToolbarItem(placement: .secondaryAction) {
                    if horizontalSizeClass == .regular {
                        Button("Engine", systemImage: "slider.horizontal.3") {
                            isPresentingEngine = true
                        }
                        .help("Voice, effects, output and buffer settings")
                    } else {
                        NavigationLink {
                            EngineControlsView()
                        } label: {
                            Label("Engine", systemImage: "slider.horizontal.3")
                        }
                        .help("Voice, effects, output and buffer settings")
                    }
                }
            }
            // Its own stack, because the panel carries a title and a sheet has no bar to put it in
            // -- and nothing else here would give it a way out but the swipe.
            .sheet(isPresented: $isPresentingEngine) {
                NavigationStack {
                    EngineControlsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isPresentingEngine = false }
                            }
                        }
                }
            }
            .inspector(isPresented: Binding(get: { library.isShowingSongInfo },
                                            set: { library.isShowingSongInfo = $0 })) {
                SongInfoView()
            }
        }
        #endif
    }

    #if os(macOS)
    /// What is sounding the file, under the file's own name.
    ///
    /// Two different facts on purpose. With a song open the question is what is playing it, which
    /// the tone map and the container answer together -- an `.xmi` read as an SC-8820 is two things
    /// worth knowing at a glance. With nothing open there is no container to name, so this falls
    /// back to the voice, which is the one thing the app has loaded and the one thing that can be
    /// missing.
    ///
    /// Localised here rather than by `Text`, because the whole expression would otherwise infer
    /// `LocalizedStringKey` and put each interpolation in the catalogue as a key of its own.
    private var subtitle: String {
        if let info = player.songInfo, info.isValid {
            return "\(player.settings.map.name) · \(info.containerName)"
        }
        return player.romName.map { String(localized: "Sound Canvas voice · \($0)") } ?? ""
    }
    #endif

    /// The same control on every platform, and the same state behind it as the menu item -- which
    /// is why that state lives on `Library` rather than in this view.
    private var songInfoToggle: some View {
        Toggle(isOn: Binding(get: { library.isShowingSongInfo },
                             set: { library.isShowingSongInfo = $0 })) {
            Label("Song Information", systemImage: "text.page")
        }
        .help("What the file says about itself: its text, its tracks, its markers and its lyrics")
    }
}
