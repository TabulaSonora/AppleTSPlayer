//
//  ContentView.swift
//  Tabula Sonora Player
//
//  Created by Kevin López Brante on 06-08-26.
//

import OSLog
import SwiftUI
import TabulaSonoraKit
import UniformTypeIdentifiers

/// Startup and file-opening, which happen before there is any UI to report them in.
let log = Logger(subsystem: "co.losno.Tabula-Sonora-Player", category: "player")

struct ContentView: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library

    @State private var failure: Failure?

    /// A file handed to the app before the ROM finished loading.
    ///
    /// Opening the app with a document races the ROM: `onOpenURL` arrives at once, while verifying
    /// 27 MB takes a moment. Without this the file loads into an engine that has no voice yet, and
    /// then sits there silently -- the ROM arrives, and nothing tells the transport to start.
    @State private var pending: URL?

    var body: some View {
        Group {
            if player.romName == nil {
                ROMSetupView(failure: $failure)
            } else {
                // Here rather than around the whole `Group`, so the setup screen's own drop -- for
                // the ROM it is asking for -- is the only one on that screen. A song dropped before
                // there is a voice has nowhere to go that the file importer does not already offer.
                PlayerView(failure: $failure)
                    .fileDrop(of: .midiFiles, prompt: Text("Drop to play")) { open(.success($0)) }
            }
        }
        .task { await loadROMIfPresent() }
        .fileImporter(isPresented: Binding(get: { library.isPresentingSongImporter },
                                           set: { library.isPresentingSongImporter = $0 }),
                      allowedContentTypes: .midiFiles) { result in
            open(result)
        }
        .alert(item: $failure) { failure in
            Alert(title: Text(failure.title),
                  message: Text(failure.message),
                  dismissButton: .default(Text("OK")))
        }
        .onOpenURL { open(.success($0)) }
    }

    /// A ROM imported on an earlier launch is loaded without rehashing 27 MB -- the size and PE
    /// timestamp check is what a file already verified once needs.
    private func loadROMIfPresent() async {
        guard player.romName == nil else { return }

        guard library.hasImportedROM else {
            log.info("No ROM at \(library.romURL.path(percentEncoded: false), privacy: .public)")
            return
        }

        do {
            log.info("Loading ROM, full verification: \(!library.isROMVerified, privacy: .public)")
            try player.loadROM(at: library.romURL, verifyFully: !library.isROMVerified)
            library.isROMVerified = true
            log.info("ROM loaded: \(player.romName ?? "?", privacy: .public)")

            if let waiting = pending {
                pending = nil
                open(.success(waiting))
            }
        } catch {
            // The copy on disk is not the pinned build -- most likely imported before a change of
            // mind about which file it was. Drop it and ask again rather than failing forever.
            log.error("ROM load failed: \(error.localizedDescription, privacy: .public)")
            library.removeROM()
            failure = Failure(title: "That Sound Canvas ROM cannot be used",
                              message: error.localizedDescription)
        }
    }

    private func open(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()

            // Nothing can be played without a voice, so a file that arrives first waits for one
            // rather than loading into an engine that cannot sound it.
            guard player.romName != nil else {
                pending = url
                return
            }

            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            try player.loadSong(at: url)
            library.remember(song: url)
            player.play()
            log.info("Playing \(player.songName ?? "?", privacy: .public)")
        } catch {
            log.error("Open failed: \(error.localizedDescription, privacy: .public)")
            failure = Failure(title: "That file could not be played",
                              message: error.localizedDescription)
        }
    }
}

/// Something worth interrupting the user for, with the engine's own words for what went wrong.
struct Failure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

extension Array where Element == UTType {
    /// What the engine will actually accept.
    ///
    /// Far more than SMF: RIFF-MIDI, DirectMusic MIDS, DOOM MUS, Miles XMI, GMF, both HMI
    /// containers, Mobile XMF and LDS are all converted to SMF on the way in. Most have no declared
    /// type on Apple platforms, so they are matched by extension.
    static var midiFiles: [UTType] {
        var types: [UTType] = [.midi]
        for suffix in ["mid", "midi", "rmi", "mids", "mus", "xmi", "xmf", "mxmf", "gmf", "hmi",
                       "hmp", "lds"] {
            if let type = UTType(filenameExtension: suffix) {
                types.append(type)
            }
        }
        return types
    }
}
