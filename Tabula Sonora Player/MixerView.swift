//
//  MixerView.swift
//  Tabula Sonora Player
//

import SwiftUI
import TabulaSonoraKit

/// One strip per part the file actually addresses.
///
/// A sixteen-part file has no business drawing sixty-four strips, and the ones it would draw are
/// parts nothing can reach -- so the engine reports which parts a song touches and only those are
/// shown, until nothing is loaded and every part is fair game.
struct MixerView: View {
    @Environment(Player.self) private var player

    /// The parts worth a strip, in the order they are labelled.
    ///
    /// Sorted rather than left in slot order, because the label is the receive channel and the two
    /// part company as soon as a bulk dump moves a part -- a column reading 10, 1, 2, 3 looks like
    /// broken numbering rather than like information. Port first, so a multi-port score still groups
    /// the way an interface labels it, and the slot breaks ties: two parts pointed at one channel is
    /// legal in GS and both strips have to appear.
    private var visible: [PartState] {
        let present = player.parts.filter(\.isPresent)
        return (present.isEmpty ? player.parts : present).sorted { left, right in
            if left.index / 16 != right.index / 16 {
                return left.index / 16 < right.index / 16
            }
            if left.displayChannel != right.displayChannel {
                return left.displayChannel < right.displayChannel
            }
            return left.index < right.index
        }
    }

    private var anySoloed: Bool { player.parts.contains(where: \.isSoloed) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(visible) { part in
                    PartRow(part: part, dimmed: anySoloed && !part.isSoloed)
                    Divider()
                }
            }
        }
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView("No parts", systemImage: "slider.vertical.3",
                                       description: Text("Open a MIDI file to see its channels."))
            }
        }
    }
}

private struct PartRow: View {
    @Environment(Player.self) private var player

    let part: PartState
    let dimmed: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(part.label)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
                .help(part.address)

            VStack(alignment: .leading, spacing: 2) {
                Text(part.name.isEmpty ? "—" : part.name)
                    .font(.callout)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if part.isDrums {
                        Tag(text: part.kit.map { "Kit \($0)" } ?? "Drums", tint: .orange)
                    }
                    // Per part and per moment: a bank LSB names a vintage, and XG System On moves
                    // every part at once, so one label for the whole mixer would go stale mid-song.
                    Tag(text: part.map.name, tint: .secondary)
                }
            }
            // The strip has room for a name and an abbreviation; the numbers behind them go here.
            .help(part.detail)

            Spacer(minLength: 8)

            VoiceMeter(voices: part.voices)

            Toggle("M", isOn: Binding(get: { part.isMuted },
                                      set: { player.setMuted($0, forPart: part.index) }))
                .toggleStyle(.button)
                .tint(.red)
                // Muting silences the part at the mix, not at the note: it goes on consuming
                // polyphony exactly as an audible part does, which is what the module does too.
                .help("Mute \(part.label) — it keeps its voices, it just stops sounding")

            Toggle("S", isOn: Binding(get: { part.isSoloed },
                                      set: { player.setSoloed($0, forPart: part.index) }))
                .toggleStyle(.button)
                .tint(.yellow)
                .help("Solo \(part.label) — once anything is soloed, only soloed parts are heard")
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .opacity(dimmed ? 0.45 : 1)
    }
}

private struct VoiceMeter: View {
    let voices: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<6, id: \.self) { slot in
                RoundedRectangle(cornerRadius: 1)
                    .fill(slot < voices ? Color.accentColor : Color.secondary.opacity(0.18))
                    .frame(width: 3, height: 12)
            }
        }
        .help("\(voices) voice\(voices == 1 ? "" : "s") sounding")
    }
}

private struct Tag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: .rect(cornerRadius: 3))
    }
}
