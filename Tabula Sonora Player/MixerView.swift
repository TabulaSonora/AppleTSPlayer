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

    #if !os(macOS)
    /// Whether a row carries its faders where there is not room for them by default.
    ///
    /// Persisted rather than left as session state: someone who wants levels in front of them wants
    /// them every launch, and the alternative is re-asking for the same thing every time the app
    /// comes up.
    @AppStorage("mixer.showsLevels") private var showsLevels = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Whether the screen can carry a second line on every row without being asked.
    ///
    /// Both directions, not just the width. A row needs the width to draw two troughs *and* the
    /// height to spend a second line on all of them, and the two come apart on real hardware: a
    /// large iPhone in landscape reports a regular *width* while having barely any height at all,
    /// and width alone would give it permanent two-line rows on the shortest screen there is -- with
    /// no button to take them away, since the button is what width alone would have hidden.
    ///
    /// The question is still the screen and not the device: an iPad in Slide Over is a phone-shaped
    /// problem, and a split view can change its mind mid-session.
    private var roomForLevels: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }
    #endif

    /// Whether the rows show their volume and pan faders.
    private var levelsVisible: Bool {
        #if os(macOS)
        true
        #else
        roomForLevels || showsLevels
        #endif
    }

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
        VStack(spacing: 0) {
            #if !os(macOS)
            // Only where the faders are not already there to be seen. Where there is room they are,
            // and a button that toggles something already on screen and always visible is a button
            // that only ever takes it away.
            if !roomForLevels, !visible.isEmpty {
                levelsHeader
                Divider()
            }
            #endif

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { part in
                        // Grouped with its rule so a part that leaves takes its divider with it
                        // rather than leaving a double line behind for the animation's length.
                        VStack(spacing: 0) {
                            PartRow(part: part,
                                    dimmed: anySoloed && !part.isSoloed,
                                    showsLevels: levelsVisible)
                            Divider()
                        }
                    }
                }
                // Keyed on the identities rather than on `visible` itself: the array is republished
                // at 10 Hz with new voice counts, and animating that would restart the row animation
                // every tenth of a second. What is worth animating is a part arriving or moving.
                .animation(.default, value: visible.map(\.id))
            }
            .overlay {
                if visible.isEmpty {
                    ContentUnavailableView("No parts", systemImage: "slider.vertical.3",
                                           description: Text("Open a MIDI file to see its channels."))
                        .transition(.opacity)
                }
            }
        }
        .animation(.default, value: visible.isEmpty)
    }

    #if !os(macOS)
    /// Where the faders are asked for, on the one width that cannot afford to show them by default.
    ///
    /// Beside the thing it controls rather than up in the bar with Open and Song Information: those
    /// are what to do with the file, and this is how much of each part to show.
    private var levelsHeader: some View {
        HStack {
            Text("Parts")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer()

            Toggle(isOn: $showsLevels) {
                Label("Levels", systemImage: "slider.horizontal.below.rectangle")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            // One literal rather than two concatenated: a `+` expression is not a literal, and the
            // catalogue only extracts literals -- a joined string is silently never translated.
            .help("Show each part's volume and pan, which the song itself can move")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }
    #endif
}

private struct PartRow: View {
    @Environment(Player.self) private var player

    let part: PartState
    let dimmed: Bool
    let showsLevels: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            strip

            if showsLevels {
                levels
            }
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
        // Every row opens or closes together, so this is the mixer changing shape rather than
        // sixteen rows each redrawing themselves.
        .animation(.default, value: showsLevels)
    }

    private var strip: some View {
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
    }

    /// The two controllers that decide how a part sits in the mix.
    ///
    /// Indented to start under the instrument name rather than under the address, so the line reads
    /// as belonging to the part above it rather than as a row of its own.
    private var levels: some View {
        HStack(spacing: 12) {
            Fader(part: part, controller: 7, title: "Vol",
                  value: part.volume, bounds: 0...127,
                  readout: volumeReadout, brief: "\(part.volume)")

            // Shown from 1, so a part left on the random-pan setting sits hard left and says so in
            // words -- there is no position on a CC#10 fader that means "random".
            Fader(part: part, controller: 10, title: "Pan",
                  value: max(part.pan, 1), bounds: 1...127,
                  readout: panReadout, brief: briefPan)
        }
        .padding(.leading, 40)
        .transition(.opacity)
    }

    /// Expression comes along because CC#7 alone does not say how loud a part is: the two are
    /// multiplied, and a score that leaves volume alone and rides expression would otherwise look as
    /// though nothing were moving.
    private var volumeReadout: String {
        String(localized: "Volume \(part.volume) · Expression \(part.expression)")
    }

    /// Pan as the module spells it: 1-127 read as L63 through R63, with 64 in the middle.
    ///
    /// Zero is not a position. The engine folds a CC#10 of zero to one because the controller cannot
    /// reach the random-pan setting -- only the GS panpot SysEx writes a true zero -- so the fader
    /// does not offer it and a part that has it is described in words instead.
    private var panReadout: String {
        if part.pan <= 0 {
            return String(localized: "Pan random, set by SysEx")
        }

        let offset = part.pan - 64
        if offset == 0 {
            return String(localized: "Pan centre")
        }

        // Two whole format strings rather than a letter concatenated onto a word: L and R are
        // English initials, and a language that writes them differently -- or puts the distance
        // before the side -- has nowhere to say so if the string is assembled here.
        return offset < 0 ? String(localized: "Pan L\(-offset)")
                          : String(localized: "Pan R\(offset)")
    }

    /// `panReadout` at the width a row can spare, for the platforms with no pointer to hover.
    private var briefPan: String {
        if part.pan <= 0 {
            return String(localized: "RND")
        }

        let offset = part.pan - 64
        if offset == 0 {
            return String(localized: "C")
        }

        return offset < 0 ? String(localized: "L\(-offset)") : String(localized: "R\(offset)")
    }
}

/// One controller fader, and the state that keeps it from fighting its own engine.
///
/// A window onto CC#7 or CC#10 rather than a gain of this program's own: moving one sends the
/// controller the file would have sent, so the file's next one overrides it and a seek -- which
/// replays controllers -- puts every strip back where the score says. A trim of ours riding on top
/// would survive both, and would then be describing a mix that neither the module nor an export of
/// it would ever produce.
private struct Fader: View {
    @Environment(Player.self) private var player

    let part: PartState
    /// 7 for volume, 10 for pan.
    let controller: Int
    let title: LocalizedStringKey
    /// What the engine holds now.
    let value: Int
    let bounds: ClosedRange<Double>
    /// The value spelled out, for the tooltip and for VoiceOver.
    let readout: String
    /// The same value at the width a row can spare.
    let brief: String

    /// The last value this fader sent, or nil when it is simply following the engine.
    ///
    /// A fader that just followed the snapshot would fight the pointer: the engine is polled ten
    /// times a second and any of those ticks can land mid-drag carrying the value from before the
    /// drag began, so the thumb would be dragged forward by the hand and snapped back by the clock.
    /// A fader that has just sent something therefore stops taking the engine's word until it hears
    /// its own value back.
    @State private var pending: Int?

    private var shown: Int { pending ?? value }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .leading)

            // Whole controller values only: a slider left to its own resolution emits a change per
            // pixel of travel, and every one of those is a MIDI message the engine has to dispatch.
            Slider(value: Binding(get: { Double(shown) }, set: send), in: bounds, step: 1)
                .accessibilityLabel(title)
                .accessibilityValue(readout)

            // A tooltip needs a pointer to sit under, so off the Mac the number has to be on the row
            // itself -- the help below is there, and is unreachable.
            #if !os(macOS)
            Text(brief)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .trailing)
                .contentTransition(.numericText())
            #endif
        }
        .help(readout)
        .onChange(of: value) { _, echoed in
            if echoed == pending {
                pending = nil
            }
        }
        // The wait is bounded rather than left to resolve itself, and the bound is doing real work
        // in two cases: a part with its GS volume receive switch off never echoes anything, and a
        // song that sends its own CC#7 while a value of ours is outstanding echoes something else.
        // In both the fader has to give up and show what is true. Setting `pending` restarts this,
        // which is what keeps a continuous drag from timing out under the hand.
        .task(id: pending) {
            guard pending != nil else { return }
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            pending = nil
        }
    }

    /// Sends what the fader now reads as a control change on the part's *receive* channel.
    ///
    /// The receive channel and not the slot: the engine dispatches a controller by walking the parts
    /// looking for one that listens on it, so a message addressed to the slot would go to whatever
    /// part happens to be on that channel -- which after a bulk dump is not the strip under the
    /// pointer. The same reason means one fader can move two parts, when a file has pointed both at
    /// one channel; that is the module's own behaviour and the other strip shows it within a tick.
    private func send(_ position: Double) {
        let value = Int(position.rounded())
        guard value != shown else { return }

        pending = value
        player.send(status: 0xB0 | part.displayChannel,
                    data1: controller,
                    data2: value,
                    port: part.index / 16)
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
