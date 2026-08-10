//
//  SongInfoView.swift
//  Tabula Sonora Player
//

import SwiftUI
import TabulaSonoraKit

/// What the loaded file says about itself: its own text, its tracks, its lyrics and its markers.
///
/// An inspector rather than a window, which is the whole difference between this and the Linux
/// player's version of the same thing. There it is a second window because that is what the platform
/// offers for something meant to be left open beside the player; here the platform offers a panel
/// attached to the window it describes, which is a better fit for content that follows whatever file
/// is loaded and has nothing to say when none is.
///
/// It reads `Player.songInfo` and no snapshot field, deliberately. The snapshot refreshes on a
/// display tick that runs *after* the song name changes, so a view built from it would spend a
/// tenth of a second describing the previous file -- most visibly by showing its length.
struct SongInfoView: View {
    @Environment(Player.self) private var player

    @State private var page: Page = .song

    /// The three questions a file answers, which are different enough in shape to be worth
    /// separating: prose about the piece, a list of its tracks, and a sheet of words.
    private enum Page: String, CaseIterable, Identifiable {
        case song = "Song"
        case tracks = "Tracks"
        case lyrics = "Lyrics"

        var id: Self { self }
    }

    var body: some View {
        Group {
            if let info = player.songInfo, info.isValid {
                VStack(spacing: 0) {
                    Picker("Page", selection: $page) {
                        ForEach(Page.allCases) { page in
                            Text(page.rawValue).tag(page)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    switch page {
                    case .song: SongPage(info: info)
                    case .tracks: TracksPage(tracks: info.tracks)
                    case .lyrics: LyricsPage(lyrics: info.lyrics)
                    }
                }
            } else {
                // Also the answer for a file that loaded but could not be walked -- rare, and there
                // is nothing more useful to say about one than that there is nothing to say.
                ContentUnavailableView("No Song Open", systemImage: "text.page",
                                       description: Text("Open a MIDI file to see what it says "
                                                         + "about itself."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
    }
}

extension SongInfo {
    /// What the bytes on disk were.
    ///
    /// Worth saying even though the converter only reports *that* it converted rather than what
    /// from: it explains why an `.xmi` has track names and a format number.
    ///
    /// Here rather than at either place that shows it, because both the inspector's row and the
    /// Mac window's subtitle name the same fact and two spellings of it would eventually disagree.
    var containerName: String {
        isConverted ? String(localized: "Converted to Standard MIDI File")
                    : String(localized: "Standard MIDI File")
    }
}

// MARK: - Song

private struct SongPage: View {
    @Environment(Player.self) private var player

    let info: SongInfo

    var body: some View {
        Form {
            // No "Name" row: the transport already carries the file name a few points to the left,
            // and repeating it as the first row of the first group says the same thing twice on one
            // screen.
            Section("File") {
                value("Container", info.containerName)
                value("Format", "\(info.format)")
                value("Tracks", "\(info.trackCount)")
                value("Duration", clockText(info.duration))
            }

            Section("Module") {
                // The evidence is the row's own footnote rather than a second row: it is the reason
                // for the value above it, not a separate fact. The verdict is shown and never
                // applied -- which module plays a file stays a preference, the same restraint the
                // engine takes.
                VStack(alignment: .leading, spacing: 2) {
                    LabeledContent("Asks for",
                                   value: info.vintage.isStated ? info.vintageName : "No preference")
                    if !info.vintageEvidence.isEmpty {
                        Text(info.vintageEvidence)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                value("Playing on", player.settings.map.name)
            }

            Section("Timing") {
                value("Tempo", tempo)
                value("Time", info.timeSignature)
                value("Key", info.keySignature)
            }

            // Only when there is one. A group whose entire content is "there is no loop" is a row
            // saying nothing, and the great majority of files have none.
            if let loop = info.loop {
                Section("Loop") {
                    // Named, because the two behave differently at the jump: a soft loop rewinds
                    // cleanly, where a hard one's end is inferred and replays controllers.
                    value(loop.isSoft ? "Soft" : "Hard",
                          "\(clockText(loop.start)) – \(clockText(loop.end))")
                }
            }

            // The text is its own label. Files carry anywhere from one line to a dozen, and a
            // "Text" title repeated down the left of every one of them is a column of one word.
            if info.hasText {
                Section("Text") {
                    if !info.copyright.isEmpty {
                        prose(info.copyright)
                    }
                    ForEach(Array(info.text.enumerated()), id: \.offset) { _, line in
                        prose(line)
                    }
                    ForEach(Array(info.karaokeHeadings.enumerated()), id: \.offset) { _, heading in
                        prose(heading)
                    }
                }
            }

            if !info.markers.isEmpty {
                Section("Markers") {
                    ForEach(info.markers) { marker in
                        MarkerRow(marker: marker) { player.seek(toSeconds: marker.position) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var tempo: String {
        guard let bpm = info.initialTempoBPM else { return "" }
        let rounded = "\(Int(bpm.rounded())) bpm"
        // The *first* tempo, not an average, so a file that varies has to say so or the number
        // reads as a description of the whole piece.
        return info.tempoChanges > 1 ? rounded + ", varying" : rounded
    }

    /// A labelled fact, with an em dash where the file said nothing.
    ///
    /// A dash rather than a hidden row: a file that says nothing about itself is the common case,
    /// and a panel that shrinks to three rows for it looks broken where one that says "Key —" has
    /// answered the question.
    private func value(_ title: String, _ text: String) -> some View {
        LabeledContent(title, value: text.isEmpty ? "—" : text)
            .textSelection(.enabled)
    }

    /// A line the file wrote, which is already a label and needs no title beside it.
    ///
    /// Passed as a variable rather than a literal on purpose: SwiftUI parses markdown in `Text`
    /// only for string *literals*, so arbitrary file text arrives as itself. The Linux player has
    /// to escape the same strings, because the widget it puts them in parses Pango markup and the
    /// first real file this was pointed at was credited to "Hoagy Carmichael & Stuart Gorell".
    private func prose(_ line: String) -> some View {
        Text(line)
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A marker: what it says, where it falls, and a jump to it.
///
/// A button, because a marker whose position is known and cannot be reached is a label rather than a
/// place -- "Chorus" is worth showing mostly because it is worth going to. Seeking only, not
/// seek-and-play: the transport keeps whatever state it had, so this scrubs a paused song and jumps
/// a playing one, which is what the scrubber it stands in for does.
private struct MarkerRow: View {
    let marker: SongMarker
    let seek: () -> Void

    var body: some View {
        Button(action: seek) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker.text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(clockText(marker.position))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Go to \(clockText(marker.position))")
    }
}

// MARK: - Tracks

private struct TracksPage: View {
    let tracks: [SongTrack]

    var body: some View {
        List(tracks) { track in
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(track.number). \(track.name.isEmpty ? "Untitled" : track.name)")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // What makes a silent tempo track visibly silent, which is most of why anyone
                    // reads this list.
                    Text(track.notes == 1 ? "1 note" : "\(track.notes) notes")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                // The instrument name and the channels are two different answers to "what is this
                // track", and files supply one, both or neither.
                if let subtitle = subtitle(for: track) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
        }
    }

    private func subtitle(for track: SongTrack) -> String? {
        var parts: [String] = []

        if !track.instrument.isEmpty {
            parts.append(track.instrument)
        }

        if !track.channels.isEmpty {
            // One-based, because that is how every sequencer and this app's own mixer number them.
            let list = track.channels.map { String($0 + 1) }.joined(separator: ", ")
            parts.append((track.channels.count == 1 ? "Channel " : "Channels ") + list)
        }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Lyrics

private struct LyricsPage: View {
    let lyrics: String

    var body: some View {
        if lyrics.isEmpty {
            // Told to fill what is left of the panel. Left to its own size it sits at the top under
            // the page picker at whatever width its longest line wants, which reads as a label that
            // failed to lay out rather than as a page saying there is nothing here.
            ContentUnavailableView("No Lyrics", systemImage: "text.justify.left",
                                   description: Text("This file carries no lyric events."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Scrolling text rather than a list: the sheet runs to hundreds of lines and is one
            // thing, not many, so selecting and copying it out has to take the whole of it.
            ScrollView {
                Text(lyrics)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }
}
