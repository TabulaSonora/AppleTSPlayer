import Foundation
import Security

/// The `SCCore.dll` on disk, in a container both the app and the plugin can reach.
///
/// The engine reads its wave ROM and synth tables out of a file the user supplies from a licensed
/// SOUND Canvas VA install. The app copies that file in once and reads it for the life of a session;
/// the Audio Unit runs in its own sandboxed process with its own container and would otherwise have
/// no way to see it. An app group is the only container two signed bundles from the same team may
/// share, so the ROM lives there and both sides address it through this type.
///
/// Everything here is static because there is nothing to configure: one file, one place, one
/// verified flag. It is also `nonisolated` on purpose -- the plugin loads the ROM off the main actor
/// while its view is being built.
public enum ROMStore {
    /// The app group both bundles are entitled to, asked of the build rather than written down.
    ///
    /// Asked, because writing it down is what goes wrong. The identifier is spelled differently per
    /// platform and neither platform accepts the other's spelling -- iOS wants it to begin with
    /// `group.`, macOS wants the team identifier in front of that -- so it already appears in four
    /// entitlements files, and a fork signed by another team has to change the domain in all of
    /// them (`TS_APP_GROUP_DOMAIN` in `Xcode-config/Shared.xcconfig`). Another copy here, in Swift,
    /// would have to be edited to match and would be the one nothing checks: a mismatch is not a
    /// build error, only an app whose plugin cannot find the ROM.
    ///
    /// Where it is asked from differs by platform, because the ways of asking do. macOS reads the
    /// entitlement back out of this process's own code signature -- the value that actually decides
    /// which container may be opened, so the one spelling that cannot be wrong. iOS has no such API
    /// and reads the `TSAppGroup` Info.plist key instead, which the build fills in from the same
    /// `TS_APP_GROUP` setting that spells the entitlements. Both routes lead back to the xcconfig,
    /// so the team and the domain still live in the build configuration alone.
    public static let appGroup: String = entitledAppGroup() ?? defaultAppGroup

    /// What upstream signs as, for a build with nothing to read the group out of -- a unit test, a
    /// copy whose signature did not survive, or a package build with no app Info.plist around it.
    /// None of those can open a group container anyway; `romURL` falls back to Application Support.
    private static let defaultAppGroup: String = {
        #if os(macOS)
        "8WHB6LKY28.group.co.losno.tabula-sonora"
        #else
        "group.co.losno.tabula-sonora"
        #endif
    }()

    #if os(macOS)
    /// The app group this bundle is entitled to, or nil if it is entitled to none.
    ///
    /// Matched by suffix rather than taken as the first: an entitlement may list more than one
    /// group, and only this one is the ROM's.
    private static func entitledAppGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let entitlement = SecTaskCopyValueForEntitlement(
                  task, "com.apple.security.application-groups" as CFString, nil),
              let groups = entitlement as? [String]
        else {
            return nil
        }
        return groups.first { $0.hasSuffix(".tabula-sonora") }
    }
    #else
    /// The same identifier, carried in the bundle because iOS cannot be asked for it.
    ///
    /// `SecTaskCreateFromSelf` and `SecTaskCopyValueForEntitlement` are macOS-only -- an iOS build
    /// of the branch above does not compile, let alone run -- and iOS offers no supported way for a
    /// process to read its own entitlements. So the build writes the group into the app's and the
    /// extension's `Info.plist` as `TSAppGroup`, under the iOS SDKs only, from the `TS_APP_GROUP`
    /// setting the entitlements are spelled from. It is a copy, but not a hand-maintained one: both
    /// come from the same xcconfig line in the same build, so they cannot disagree.
    ///
    /// `Bundle.main` is the running bundle, which inside the Audio Unit is the appex -- each target
    /// carries its own key, so each finds the group it is actually entitled to.
    ///
    /// Empty counts as absent. The key is present but blank in any bundle built for another SDK,
    /// where the setting behind it is deliberately unset.
    private static func entitledAppGroup() -> String? {
        let group = Bundle.main.object(forInfoDictionaryKey: "TSAppGroup") as? String
        return group?.isEmpty == false ? group : nil
    }
    #endif

    public static let fileName = "SCCore.dll"

    private static let verifiedKey = "ROMVerified"

    /// The shared container, or nil if this build is not entitled to it.
    ///
    /// Nil is a misconfiguration -- an unsigned build, or an entitlement that did not survive a
    /// signing change -- and not something to crash on: the app falls back to its own Application
    /// Support below and goes on working alone, which is what it did before the plugin existed.
    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// Where the app kept the ROM before the group container existed, and where a build with no
    /// entitlement still keeps it.
    private static var applicationSupportURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support.appending(path: fileName)
    }

    /// Where the ROM lives.
    public static var romURL: URL {
        containerURL.map { $0.appending(path: fileName) } ?? applicationSupportURL
    }

    public static var hasImportedROM: Bool {
        FileManager.default.fileExists(atPath: romURL.path(percentEncoded: false))
    }

    /// A marker beside the ROM, rather than a preference.
    ///
    /// It is a fact about *this file*, so it belongs next to it: swap the ROM and the marker goes
    /// with the copy it described. Preferences would also have worked, but not shared ones --
    /// `UserDefaults(suiteName:)` over a group container detaches from `cfprefsd` on macOS and both
    /// processes then read and write the plist behind each other's backs, which is a race to save a
    /// flag whose whole purpose is to avoid a second of work.
    private static var verifiedMarkerURL: URL {
        romURL.appendingPathExtension("verified")
    }

    /// Whether this copy has already been hashed once. A verified file needs only its size and PE
    /// timestamp checked afterwards, which is the difference between instant and a moment.
    public static var isROMVerified: Bool {
        get { FileManager.default.fileExists(atPath: verifiedMarkerURL.path(percentEncoded: false)) }
        set {
            if newValue {
                FileManager.default.createFile(atPath: verifiedMarkerURL
                    .path(percentEncoded: false), contents: nil)
            } else {
                try? FileManager.default.removeItem(at: verifiedMarkerURL)
            }
        }
    }

    /// Copies a picked ROM into place. The caller then loads it, verifying fully the first time.
    ///
    /// Copies rather than reads: 27 MB inside the container buys one code path on three platforms,
    /// and a file the engine can `pread` for the life of the session without holding a security
    /// scope open.
    public static func importROM(from picked: URL) throws {
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }

        let manager = FileManager.default
        let destination = romURL
        try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)

        // To a neighbouring file first, then swapped in, so an interrupted copy cannot leave a
        // half-written ROM that the next launch would try to verify.
        let staging = destination.appendingPathExtension("importing")
        try? manager.removeItem(at: staging)
        try manager.copyItem(at: picked, to: staging)

        if manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }

        isROMVerified = false
    }

    public static func removeROM() {
        try? FileManager.default.removeItem(at: romURL)
        isROMVerified = false
    }

    /// Brings a ROM imported by an earlier build up to date: into the shared container, and with its
    /// verified flag beside it.
    ///
    /// Call before anything reads `hasImportedROM`.
    public static func migrate() {
        guard let container = containerURL else { return }

        let manager = FileManager.default
        let destination = container.appending(path: fileName)
        let source = applicationSupportURL

        // A rename inside one volume, so the 27 MB is not copied and the app does not ask for the
        // file again. A failure needs no recovery: the ROM is still where it was and the import
        // screen will offer to take another, which is better than turning a working install into an
        // error message.
        if manager.fileExists(atPath: source.path(percentEncoded: false)),
           !manager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try? manager.createDirectory(at: destination.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
            try? manager.moveItem(at: source, to: destination)
        }

        // Separately from the move, because a build in between kept the ROM in the container and the
        // flag in preferences -- first the app's own, then the group's. Both are read once and
        // dropped: the flag was earned by hashing this exact file, and leaving it behind would cost
        // a second of hashing on the next launch for nothing.
        //
        // The group's suite is opened only when its plist is on disk *and* still holds the key,
        // which is why that plist is read as a file first. Opening the suite is what logs a
        // `cfprefsd` complaint -- shared preference domains are half supported on macOS, which is
        // the reason the flag stopped being one -- and doing it at every launch to find nothing
        // would leave that complaint in the log forever.
        var stale: [UserDefaults] = [.standard]
        let groupPreferences = container
            .appending(path: "Library/Preferences/\(appGroup).plist")
        if let plist = NSDictionary(contentsOf: groupPreferences), plist[verifiedKey] != nil,
           let group = UserDefaults(suiteName: appGroup) {
            stale.append(group)
        }

        for defaults in stale where defaults.object(forKey: verifiedKey) != nil {
            if defaults.bool(forKey: verifiedKey), hasImportedROM {
                isROMVerified = true
            }
            defaults.removeObject(forKey: verifiedKey)
        }
    }
}
