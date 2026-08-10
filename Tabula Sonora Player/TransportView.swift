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

    /// Whether the screen is short rather than small.
    ///
    /// An iPhone in landscape is the case this exists for: the width is generous and the height is
    /// almost gone, and the stacked layout below spends nearly all of it on four rows before the
    /// first part appears. Every iPhone is vertically compact in landscape and every iPad is not,
    /// so this is the platform's own way of saying "there is no height here" -- it needs no idiom
    /// check and it follows a rotation without being told.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    var body: some View {
        Group {
            #if os(macOS)
            stacked
            #else
            if verticalSizeClass == .compact {
                inline
            } else {
                stacked
            }
            #endif
        }
        #if !os(macOS)
        // Declared here rather than in `PlayerView` so the export's state stays with the code that
        // runs it. A toolbar contributed from inside the navigation stack reaches the same bar.
        .toolbar {
            ToolbarItem(placement: .secondaryAction) { exportMenuItem }
        }
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

    /// The transport with room to breathe: a line each for the name, the scrubber, the buttons and
    /// what the engine is doing.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Not on the Mac: the window's own title and subtitle carry both of these lines, and a
            // song name repeated an inch below itself is a window saying one thing twice.
            #if !os(macOS)
            header
            #endif

            VStack(spacing: 4) {
                scrubber

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
    }

    #if !os(macOS)
    /// The same transport on one line, for a screen with no height to spare.
    ///
    /// Four stacked rows become one plus a caption, which is the difference between one part being
    /// visible under it and four. Nothing is dropped, only re-hung on the axis there is room on: the
    /// name goes because the navigation bar is already showing it, the two clocks join into one
    /// reading, and the export button keeps its icon and loses its words.
    ///
    /// What does *not* go is the status line. A glitch the listener hears but the display never
    /// mentions reads as a fault in the engine, and a layout is not a reason to stop saying so.
    private var inline: some View {
        VStack(spacing: 4) {
            HStack(spacing: 14) {
                playButton
                rewindButton
                loopToggle
                panicButton

                scrubber

                Text(verbatim: "\(clockText(scrubbing ?? player.position)) / "
                     + clockText(player.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            status
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
    #endif

    private var scrubber: some View {
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
    }

    #if !os(macOS)
    /// What is making the sound.
    ///
    /// The song's own name is not here. The navigation bar is already showing it, and a title
    /// repeated an inch below itself is one screen saying one thing twice -- the same reason the
    /// Mac dropped this whole block when its title bar took the job over. What is left is the one
    /// fact nothing else in the app states: which ROM the voice came from.
    ///
    /// Localised here rather than by `Text`, because the whole expression would otherwise infer
    /// `LocalizedStringKey` and put the empty fallback in the catalogue as a key of its own. The
    /// empty line itself stays: it holds the height steady, so a ROM arriving does not shift the
    /// scrubber down.
    private var header: some View {
        Text(verbatim: player.romName.map { String(localized: "Sound Canvas voice · \($0)") } ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    #endif

    private var controls: some View {
        HStack(spacing: 16) {
            playButton
            rewindButton
            loopToggle
            panicButton

            Spacer()

            // Both of these are things done to the *file*, and off the Mac they live where the
            // file's other actions live -- Open in the bar, Export in the overflow behind it. The
            // Mac has no overflow and a window wide enough not to need one.
            #if os(macOS)
            Button("Open…") { library.isPresentingSongImporter = true }
                .help("Open a MIDI file")

            exportButton
            #endif
        }
    }

    private var playButton: some View {
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
    }

    private var rewindButton: some View {
        Button("Rewind", systemImage: "backward.end.fill") {
            player.seek(toSeconds: 0)
        }
        .labelStyle(.iconOnly)
        .disabled(player.songName == nil)
        .help("Go back to the start")
    }

    private var loopToggle: some View {
        Toggle(isOn: Binding(get: { player.isLooping },
                             set: { player.isLooping = $0 })) {
            Label("Loop", systemImage: "repeat")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help("Repeat at the file's own loop points, or over the whole file if it declares none")
    }

    private var panicButton: some View {
        Button("Panic", systemImage: "exclamationmark.2", action: player.panic)
            .labelStyle(.iconOnly)
            .help("Panic: silence every voice and return each part to its power-on state")
    }

    #if !os(macOS)
    /// Export as a menu item, which is a different shape from the button beside a Mac's transport.
    ///
    /// A menu row cannot carry a progress bar and a cancel beside each other, so a running export
    /// becomes one row that reads its own progress and cancels when tapped. Nothing is lost: the
    /// percentage is the same number the bar would have drawn, and the row is still the way out.
    @ViewBuilder
    private var exportMenuItem: some View {
        if let export {
            Button("Stop exporting — \(Int(export.fraction * 100))%",
                   systemImage: "stop.circle") {
                export.cancel()
            }
        } else {
            Button("Export WAV…", systemImage: "square.and.arrow.down") { beginExport() }
                .disabled(player.songName == nil)
        }
    }
    #endif

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
