//
//  TransportView.swift
//  Tabula Sonora Player
//

import os
import SwiftUI
import TabulaSonoraKit

struct TransportView: View {
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library

    @Binding var failure: Failure?

    /// Where the thumb is while it is being dragged, so the position readout does not fight the
    /// engine's own reports for the duration of the gesture.
    @State private var scrubbing: TimeInterval?
    @State private var export: ExportState?

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

                HStack {
                    Text(time(scrubbing ?? player.position))
                    Spacer()
                    Text(time(player.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            controls
            status
        }
        .padding(20)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(player.songName ?? "No file open")
                .font(.headline)
                .lineLimit(1)

            Text(player.romName.map { "Sound Canvas voice · \($0)" } ?? "")
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
                Label("\(player.underruns) dropout\(player.underruns == 1 ? "" : "s")",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private func beginExport() {
        let name = (player.songName as NSString?)?.deletingPathExtension ?? "Export"
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "\(name).wav")

        let state = ExportState(destination: destination)
        export = state

        Task {
            do {
                try await player.exportWAV(to: destination) { fraction in
                    Task { @MainActor in state.fraction = fraction }
                    return !state.isCancelled
                }
                export = nil
                if !state.isCancelled {
                    failure = Failure(title: "Exported",
                                      message: "Written to \(destination.path(percentEncoded: false))")
                }
            } catch {
                export = nil
                failure = Failure(title: "Export failed", message: error.localizedDescription)
            }
        }
    }
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
