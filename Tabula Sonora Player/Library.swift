//
//  Library.swift
//  Tabula Sonora Player
//

import Foundation
import Observation
import TabulaSonoraKit

/// Which files have been opened, and the window state that outlives them.
///
/// The ROM itself lives in `ROMStore`, in a container shared with the Audio Unit -- the plugin runs
/// in its own sandboxed process and could not otherwise see the file the app imported. What is left
/// here is the part that is only ever the app's: what it has played, and what it is showing.
@MainActor
@Observable
final class Library {
    /// Set when the app has no usable ROM and has to ask for one before it can make a sound.
    var isPresentingROMImporter = false
    var isPresentingSongImporter = false

    /// Whether the song information inspector is open.
    ///
    /// Here rather than in the view that shows it because the menu item toggles the same thing, and
    /// a `Commands` block is built outside any view's state. It is also the piece of window state
    /// most worth surviving a file being closed and another opened.
    var isShowingSongInfo = false

    private(set) var recentSongs: [URL] = []

    init() {
        // Before anything asks whether there is a ROM, so a copy imported by a build that predates
        // the shared container is found rather than asked for again.
        ROMStore.migrate()
    }

    /// Where the imported ROM is kept -- the container the plugin reads too.
    var romURL: URL { ROMStore.romURL }

    var hasImportedROM: Bool { ROMStore.hasImportedROM }

    /// Copies a picked ROM into place. The caller then loads it, verifying fully the first time.
    func importROM(from picked: URL) throws {
        try ROMStore.importROM(from: picked)
    }

    /// Whether this copy has already been hashed once. A verified file needs only its size and PE
    /// timestamp checked on later launches, which is the difference between instant and a moment.
    var isROMVerified: Bool {
        get { ROMStore.isROMVerified }
        set { ROMStore.isROMVerified = newValue }
    }

    func removeROM() {
        ROMStore.removeROM()
    }

    func remember(song: URL) {
        recentSongs.removeAll { $0 == song }
        recentSongs.insert(song, at: 0)
        if recentSongs.count > 10 {
            recentSongs.removeLast(recentSongs.count - 10)
        }
    }
}
