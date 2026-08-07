//
//  Library.swift
//  Tabula Sonora Player
//

import Foundation
import Observation
import TabulaSonoraKit

/// Where the ROM lives and which files have been opened.
///
/// The engine needs a `SCCore.dll` the user supplies from a licensed SOUND Canvas VA install. Under
/// the App Sandbox a picked file is reachable only while its security scope is held, and the engine
/// reads the ROM continuously for the life of a session -- so the file is copied into Application
/// Support once and read from there afterwards. That also gives iOS and visionOS the same code path
/// as the Mac, where a bookmark would have been an option.
@MainActor
@Observable
final class Library {
    /// Set when the app has no usable ROM and has to ask for one before it can make a sound.
    var isPresentingROMImporter = false
    var isPresentingSongImporter = false

    private(set) var recentSongs: [URL] = []

    private let defaults = UserDefaults.standard
    private static let verifiedKey = "ROMVerified"

    /// Where the imported ROM is kept.
    var romURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support.appending(path: "SCCore.dll")
    }

    var hasImportedROM: Bool {
        FileManager.default.fileExists(atPath: romURL.path(percentEncoded: false))
    }

    /// Copies a picked ROM into place. The caller then loads it, verifying fully the first time.
    ///
    /// Copies rather than reads: 27 MB inside the container buys one code path on three platforms,
    /// and a file the engine can `pread` for the life of the session without holding a scope open.
    func importROM(from picked: URL) throws {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

        let manager = FileManager.default
        try manager.createDirectory(at: romURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)

        // To a neighbouring file first, then swapped in, so an interrupted copy cannot leave a
        // half-written ROM that the next launch would try to verify.
        let staging = romURL.appendingPathExtension("importing")
        try? manager.removeItem(at: staging)
        try manager.copyItem(at: picked, to: staging)

        if manager.fileExists(atPath: romURL.path(percentEncoded: false)) {
            _ = try manager.replaceItemAt(romURL, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: romURL)
        }

        defaults.set(false, forKey: Self.verifiedKey)
    }

    /// Whether this copy has already been hashed once. A verified file needs only its size and PE
    /// timestamp checked on later launches, which is the difference between instant and a moment.
    var isROMVerified: Bool {
        get { defaults.bool(forKey: Self.verifiedKey) }
        set { defaults.set(newValue, forKey: Self.verifiedKey) }
    }

    func removeROM() {
        try? FileManager.default.removeItem(at: romURL)
        defaults.set(false, forKey: Self.verifiedKey)
    }

    func remember(song: URL) {
        recentSongs.removeAll { $0 == song }
        recentSongs.insert(song, at: 0)
        if recentSongs.count > 10 {
            recentSongs.removeLast(recentSongs.count - 10)
        }
    }
}
