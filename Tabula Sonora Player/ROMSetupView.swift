//
//  ROMSetupView.swift
//  Tabula Sonora Player
//

import SwiftUI
import TabulaSonoraKit
import UniformTypeIdentifiers

/// What the app shows before it can make any sound.
///
/// The engine reads its wave ROM and synth tables out of `SCCore.dll`, which ships with SOUND
/// Canvas VA and cannot be distributed with this app. It is read as data, never loaded as code.
///
/// Several releases carry the same tables, packed differently, and the engine translates its
/// offsets into whichever one it is handed -- so this lists every build it will take rather than
/// naming a single file. Someone who owns an older release should not go hunting for a newer one
/// they do not need.
struct ROMSetupView: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library

    @Binding var failure: Failure?
    @State private var isVerifying = false

    private var required: ROMIdentity { Player.requiredROM }

    /// Every build the engine reads, newest release first.
    ///
    /// Which puts the pinned build at the top, though not because it is better -- the tables are
    /// the same data in all of them. It is the copy most people will have, and the one whose file
    /// is called what the button asks for.
    private var builds: [ROMIdentity] {
        Player.readableROMs.sorted { ($0.version, $0.architecture) > ($1.version, $1.architecture) }
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "pianokeys")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Choose your Sound Canvas ROM")
                    .font(.title2.weight(.semibold))

                // One literal, not several joined: a concatenation is an expression, and an
                // expression never reaches the string catalogue -- it would ship in English in
                // every language, silently.
                Text("Tabula Sonora plays through the Roland Sound Canvas voice, which lives inside \(required.fileName). Point it at your own copy from any \(required.product) release listed below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if isVerifying {
                ProgressView("Checking the file…")
            } else {
                Button("Choose \(required.fileName)…") {
                    library.isPresentingROMImporter = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Pick your copy of \(required.fileName). It is checked against the builds listed below and kept inside this app.")
            }

            GroupBox {
                // File name and release, not the hash. A hash identifies a file to a machine;
                // someone looking through their own install needs the name on disk and the version
                // it came from -- and the 2016 installer's two files are not called SCCore.dll at
                // all. The hash is still what the app checks against, and what the error names when
                // a file is not one of these.
                ForEach(builds) { build in
                    LabeledContent(build.fileName) {
                        Text(verbatim: "\(build.version) · \(build.architecture) · "
                             + build.length.formatted(.byteCount(style: .file)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } label: {
                Text("The files it takes").font(.caption.weight(.semibold))
            }
            .frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: Binding(get: { library.isPresentingROMImporter },
                                           set: { library.isPresentingROMImporter = $0 }),
                      allowedContentTypes: [.data]) { result in
            Task { await importROM(result) }
        }
        // Anything at all, as the importer above also takes anything: this screen exists to receive
        // one of a handful of named files, and `importROM` recognises it or says precisely why it
        // is none of them -- which is a better answer than a drag that refuses a copy the system
        // happens not to know is a library. Folders are not `public.data` and are refused at the
        // pointer.
        .fileDrop(of: [.data], prompt: Text("Drop to import")) { picked in
            Task { await importROM(.success(picked)) }
        }
    }

    private func importROM(_ result: Result<URL, any Error>) async {
        isVerifying = true
        defer { isVerifying = false }

        do {
            let picked = try result.get()
            try library.importROM(from: picked)

            // Fully the first time: this is the one moment the whole 27 MB is hashed, and it is
            // what earns the quick check on every launch after.
            try player.loadROM(at: library.romURL, verifyFully: true)
            library.isROMVerified = true
        } catch {
            library.removeROM()
            failure = Failure(title: "Tabula Sonora cannot read that file",
                              message: error.localizedDescription)
        }
    }
}
