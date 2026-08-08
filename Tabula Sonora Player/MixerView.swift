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
                    // Grouped with its rule so a part that leaves takes its divider with it rather
                    // than leaving a double line behind for the length of the animation.
                    VStack(spacing: 0) {
                        PartRow(part: part, dimmed: anySoloed && !part.isSoloed)
                        Divider()
                    }
                }
            }
            // Keyed on the identities rather than on `visible` itself: the array is republished at
            // 10 Hz with new voice counts, and animating that would restart the row animation every
            // tenth of a second. What is worth animating is a part arriving, leaving or moving.
            .animation(.default, value: visible.map(\.id))
        }
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView("No parts", systemImage: "slider.vertical.3",
                                       description: Text("Open a MIDI file to see its channels."))
                    .transition(.opacity)
            }
        }
        .animation(.default, value: visible.isEmpty)
    }
}

private struct PartRow: View {
    @Environment(Player.self) private var player

    let part: PartState
    let dimmed: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(part.label)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
                .help(part.address)

            // The tags sit beside the name rather than under it. They are three or four characters
            // each and the name is one line, so stacking them spent a whole row's height on a
            // quarter of a row's content -- and a mixer is read down the column, where every row
            // saved is another part on screen.
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(part.name.isEmpty ? "—" : part.name)
                        .font(.callout)
                        .lineLimit(1)
                        // A program change swaps the whole string; crossfading it reads as the part
                        // changing instrument rather than as the row being rebuilt.
                        .contentTransition(.opacity)

                    if part.isDrums {
                        Tag(text: part.kit.map { "Kit \($0)" } ?? "Drums", tint: .orange)
                    }
                    // Per part and per moment: a bank LSB names a vintage, and XG System On moves
                    // every part at once, so one label for the whole mixer would go stale mid-song.
                    Tag(text: part.map.name, tint: .secondary)
                }
                // Both tags can appear or change mid-song -- GS reroutes drums over SysEx and XG
                // System On moves every map at once -- so neither is a fixture of the row.
                .animation(.default, value: part.isDrums)
                .animation(.default, value: part.kit)
                .animation(.default, value: part.map)
                .animation(.default, value: part.name)

                // A tooltip needs a pointer to sit under, so off the Mac the numbers behind the
                // name have to be on the row itself -- the help below is there, and is unreachable.
                #if !os(macOS)
                Text(part.numbers)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.default, value: part.numbers)
                #endif
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
        // Small rather than the default: two buttons set the row's height on their own, and at the
        // regular size they were taller than the line of text they sit beside.
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
        .opacity(dimmed ? 0.45 : 1)
        // Soloing dims every other row at once. Stepped without an animation it reads as a redraw;
        // faded, it reads as the rest of the mixer standing back.
        .animation(.easeInOut(duration: 0.18), value: dimmed)
    }
}

private struct VoiceMeter: View {
    let voices: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<6, id: \.self) { slot in
                RoundedRectangle(cornerRadius: 1)
                    .fill(slot < voices ? Color.accentColor : Color.secondary.opacity(0.18))
                    .frame(width: 3, height: 10)
            }
        }
        // The count is polled at 10 Hz, so a segment that lit and cleared between two ticks would
        // otherwise be a single frame of colour. Easing out over rather less than the poll interval
        // keeps it visible without smearing one note's worth of activity into the next.
        .animation(.easeOut(duration: 0.08), value: voices)
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
            // Kit numbers change under the same tag rather than replacing it, so the text crossfades
            // while the pill stays put; the pill itself grows out of the row when the drum tag first
            // appears, which is the moment worth noticing.
            .contentTransition(.opacity)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}
