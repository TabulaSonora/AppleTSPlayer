//
//  TransportView.swift
//  Tabula Sonora Player
//

import os
import SwiftUI
import TabulaSonoraKit
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct TransportView: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library

    @Binding var failure: Failure?

    /// Where the thumb is while it is being dragged, so the position readout does not fight the
    /// engine's own reports for the duration of the gesture.
    @State private var scrubbing: TimeInterval?
    @State private var export: ExportState?

    #if !os(macOS)
    /// A finished render waiting to be handed somewhere, which is the only moment there is a file
    /// to hand over: a share sheet cannot offer what has not been written yet.
    @State private var rendered: RenderedFile?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(spacing: 4) {
                Slider(value: Binding(get: { scrubbing ?? player.position },
                                      set: { scrubbing = $0 }),
                       in: 0...max(player.duration, 0.001),
                       onEditingChanged: { editing in
                           if !editing, let target = scrubbing {
                               player.seek(toSeconds: target)
                               scrubbing = nil
                           }
                       })
                .disabled(player.songName == nil)
                .help("Seek. Jumping replays the controllers up to that point, so the parts sound "
                      + "as they would have.")

                HStack {
                    Text(clockText(scrubbing ?? player.position))
                    Spacer()
                    Text(clockText(player.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            controls
            status
        }
        .padding(20)
        #if !os(macOS)
        .sheet(item: $rendered) { file in
            ShareSheet(url: file.url) {
                // Whoever took it has its own copy by now, so the temporary is this app's to clear
                // -- and it is the whole song, which is not a thing to leave lying in a container.
                try? FileManager.default.removeItem(at: file.url)
                rendered = nil
            }
        }
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(player.songName ?? "No file open")
                .font(.headline)
                .lineLimit(1)

            // Localised here rather than by `Text`, because the whole expression would otherwise
            // infer `LocalizedStringKey` and put the empty fallback in the catalogue as a key of
            // its own. The empty line itself stays: it holds the header's height steady, so
            // naming a ROM does not shift the song title up.
            Text(verbatim: player.romName.map { String(localized: "Sound Canvas voice · \($0)") } ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                player.togglePlaying()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 44, height: 32)
            }
            .buttonStyle(.borderedProminent)
            .disabled(player.songName == nil)
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pause" : "Play")

            Button("Rewind", systemImage: "backward.end.fill") {
                player.seek(toSeconds: 0)
            }
            .labelStyle(.iconOnly)
            .disabled(player.songName == nil)
            .help("Go back to the start")

            Toggle(isOn: Binding(get: { player.isLooping },
                                 set: { player.isLooping = $0 })) {
                Label("Loop", systemImage: "repeat")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help("Repeat at the file's own loop points, or over the whole file if it declares none")

            Button("Panic", systemImage: "exclamationmark.2", action: player.panic)
                .labelStyle(.iconOnly)
                .help("Panic: silence every voice and return each part to its power-on state")

            Spacer()

            #if os(macOS)
            Button("Open…") { library.isPresentingSongImporter = true }
                .help("Open a MIDI file")
            #endif

            exportButton
        }
    }

    @ViewBuilder
    private var exportButton: some View {
        if let export {
            HStack(spacing: 6) {
                ProgressView(value: export.fraction)
                    .frame(width: 80)
                    .help("Rendering \(Int(export.fraction * 100))% — playback carries on meanwhile")

                Button("Cancel") { export.cancel() }
                    .buttonStyle(.borderless)
                    .help("Stop the export and leave no file behind")
            }
        } else {
            Button("Export WAV…") { beginExport() }
                .disabled(player.songName == nil)
                .help("Render the whole song to a WAV at the current engine settings")
        }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 14) {
            Label("\(player.activeVoices)/\(player.voiceCapacity) voices",
                  systemImage: "waveform")

            if player.isXGMode {
                Text("XG").font(.caption.weight(.bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.tint.opacity(0.2), in: .rect(cornerRadius: 4))
            }

            Spacer()

            // A glitch the listener hears but the display never mentions reads as a fault in the
            // engine, so this is shown rather than hidden.
            if player.underruns > 0 {
                Label("\(player.underruns) dropouts",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Renders the song to a WAV, asking about the destination at the only moment each platform
    /// can be asked.
    ///
    /// The two orderings are not a preference. A save panel wants to come first, so the engine
    /// writes the file once, straight where it is going -- a song is tens of megabytes and copying
    /// it out of a temporary afterwards would be a second pass over all of it. A share sheet cannot
    /// come first: there is nothing to offer until the render has produced a file.
    ///
    /// Cancelling is safe either way. `run_export` renders the whole song before it writes a byte,
    /// so an abandoned export never leaves a truncated WAV behind -- least of all in a folder the
    /// person chose themselves.
    private func beginExport() {
        let name = (player.songName as NSString?)?.deletingPathExtension ?? "Export"

        #if os(macOS)
        guard let destination = chooseDestination(named: name) else { return }
        #else
        let destination = URL.temporaryDirectory.appending(path: "\(name).wav")
        #endif

        let state = ExportState(destination: destination)
        export = state

        Task {
            do {
                try await player.exportWAV(to: destination) { fraction in
                    Task { @MainActor in state.fraction = fraction }
                    return !state.isCancelled
                }
                export = nil
                guard !state.isCancelled else { return }

                #if os(macOS)
                failure = Failure(title: "Exported",
                                  message: "Written to \(destination.path(percentEncoded: false))")
                #else
                rendered = RenderedFile(url: destination)
                #endif
            } catch {
                export = nil
                failure = Failure(title: "Export failed", message: error.localizedDescription)
            }
        }
    }

    #if os(macOS)
    /// The save panel, run before any rendering starts. Nil when it is dismissed, which is a
    /// perfectly ordinary answer and not a failure worth reporting.
    private func chooseDestination(named name: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(name).wav"
        panel.canCreateDirectories = true
        panel.title = "Export WAV"
        panel.message = "Render the whole song at the current engine settings."

        return panel.runModal() == .OK ? panel.url : nil
    }
    #endif
}

/// Seconds as `m:ss`.
///
/// Shared rather than restated wherever a time is shown, and truncating rather than rounding. The
/// scrubber's readout and the inspector's duration are the same `song_length_` read twice, so a
/// rounding difference between them would show one number disagreeing with itself on one screen.
func clockText(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let whole = Int(seconds)
    return String(format: "%d:%02d", whole / 60, whole % 60)
}

/// One running export, so the button can show progress and take a cancel.
///
/// The cancel flag is not main-actor state: the export's progress callback runs on the thread doing
/// the rendering and reads it there, which is the whole point of having it.
@MainActor
@Observable
final class ExportState {
    let destination: URL
    var fraction: Double = 0

    /// `OSAllocatedUnfairLock` rather than `Mutex`, which needs macOS 15 / iOS 18 -- this app goes
    /// back further. Same guarantee: the export thread reads this while the main actor writes it.
    @ObservationIgnored
    nonisolated private let cancelled = OSAllocatedUnfairLock(initialState: false)

    nonisolated var isCancelled: Bool { cancelled.withLock { $0 } }

    init(destination: URL) {
        self.destination = destination
    }

    nonisolated func cancel() {
        cancelled.withLock { $0 = true }
    }
}

#if !os(macOS)
/// A rendered WAV waiting for somewhere to go. Identifiable so a sheet can be driven off it.
private struct RenderedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet over a finished export -- AirDrop, Messages, and Save to Files, which is
/// the save dialog the Mac gets by another door.
///
/// Presented as the sheet's own content rather than anchored to the button: inside a sheet UIKit
/// gives it a presentation context on every size, which spares the popover source rect an iPad
/// otherwise insists on.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    /// Called once the sheet is done with the file, whether something took it or the person
    /// dismissed it. Waiting for this rather than for the dismissal is what stops an AirDrop still
    /// in flight from having the file deleted out from under it.
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url],
                                                  applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
