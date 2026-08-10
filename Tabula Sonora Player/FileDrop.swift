//
//  FileDrop.swift
//  Tabula Sonora Player
//

import OSLog
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Accepts a file dragged onto this view, exactly as the file importer beside it would have.
    ///
    /// `dropDestination(for: URL.self)` rather than `onDrop(of:)`, and the difference is not a
    /// preference. `onDrop` takes the list of types the view wants and is the only one of the two
    /// that can refuse a wrong file at the pointer -- but what it hands back is an `NSItemProvider`
    /// synthesised for the type that matched, and that provider no longer carries the drag's
    /// `public.file-url` at all: a dropped MIDI file offers `public.midi-audio` and nothing else,
    /// so there is no way left to ask where the file is. `URL` as a `Transferable` resolves the
    /// pasteboard's own file URL, on the main actor, and is what Apple's own drop examples use.
    ///
    /// The cost is that the pointer accepts any file and the wrong one is turned away on release,
    /// which is the snap-back animation the platform already uses for a refused drop.
    ///
    /// - Parameters:
    ///   - types: What the view will take, checked against the dropped file's own type. Resolved
    ///     the same way the file importers resolve theirs -- see `Array<UTType>.midiFiles`.
    ///   - prompt: What the view is offering to do with it, shown while the drag is over it. Passed
    ///     as a `Text` so the literal stays at the call site, where the catalogue can find it.
    ///   - accept: Handed the dropped file. One file: this app plays one thing at a time and
    ///     imports one ROM, so a multiple selection takes the first that fits and drops the rest.
    func fileDrop(of types: [UTType],
                  prompt: Text,
                  accept: @escaping (URL) -> Void) -> some View {
        modifier(FileDrop(types: types, prompt: prompt, accept: accept))
    }
}

private struct FileDrop: ViewModifier {
    let types: [UTType]
    let prompt: Text
    let accept: (URL) -> Void

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: wanted) else {
                    let refused = urls.map(\.lastPathComponent).joined(separator: ", ")
                    log.error("Dropped file is not one of ours: \(refused, privacy: .public)")
                    return false
                }
                accept(url)
                return true
            } isTargeted: { targeted in
                withAnimation(.easeInOut(duration: 0.15)) { isTargeted = targeted }
            }
            .overlay {
                if isTargeted { highlight }
            }
    }

    /// Whether this is a file the view asked for.
    ///
    /// The type on disk first, because that is what the system itself would say the file is, and
    /// the extension only when the file cannot be reached to ask -- which is the same fallback
    /// `Array<UTType>.midiFiles` is built out of, so the two agree on what a `.mus` is.
    private func wanted(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }

        let onDisk = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        guard let type = onDisk ?? UTType(filenameExtension: url.pathExtension) else { return false }

        return types.contains { type.conforms(to: $0) }
    }

    /// The view saying it will take this. Over the whole view rather than in a corner, because the
    /// drop target *is* the whole view and a hint smaller than the target invites aiming at it.
    private var highlight: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            .background(RoundedRectangle(cornerRadius: 16).fill(.tint.opacity(0.08)))
            .overlay {
                prompt
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(8)
            // The drag is already over this view; a highlight that could intercept the drop itself
            // would be a hit test fighting the thing it was drawn to describe.
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}
