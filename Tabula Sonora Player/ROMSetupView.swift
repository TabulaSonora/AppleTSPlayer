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
/// Canvas VA and cannot be distributed with this app. It is read as data -- never loaded as code --
/// and only one build works, so this names that build precisely enough for someone to find it.
struct ROMSetupView: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library

    @Binding var failure: Failure?
    @State private var isVerifying = false

    private var required: ROMIdentity { Player.requiredROM }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "pianokeys")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Choose your Sound Canvas ROM")
                    .font(.title2.weight(.semibold))

                Text("Tabula Sonora plays through the Roland Sound Canvas voice, which lives "
                     + "inside \(required.fileName). Point it at your own copy from "
                     + "\(required.product) \(required.version).")
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
                .help("Pick your copy of \(required.fileName). It is checked against the build "
                      + "above and kept inside this app.")
            }

            GroupBox {
                LabeledContent("File", value: required.fileName)
                LabeledContent("Size", value: required.length.formatted(.byteCount(style: .file)))
                LabeledContent("SHA-256") {
                    Text(required.sha256)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            } label: {
                Text("The file it needs").font(.caption.weight(.semibold))
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
        // one named file, and `importROM` recognises it or says precisely why it is not that
        // file -- which is a better answer than a drag that refuses a copy the system happens not
        // to know is a library. Folders are not `public.data` and are refused at the pointer.
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
            failure = Failure(title: "That is not the right \(required.fileName)",
                              message: error.localizedDescription)
        }
    }
}
