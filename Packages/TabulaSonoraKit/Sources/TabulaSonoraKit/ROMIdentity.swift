import Foundation
import TabulaSonoraBridge

/// One `SCCore.dll` build the engine can read.
///
/// Nothing Roland-derived is committed anywhere in this repository -- this is the description of a
/// file the user has to supply, not the file itself.
///
/// There is more than one such file. The same tables and the same wave ROM shipped in several
/// SOUND Canvas VA releases, packed differently, and the engine translates its offsets into
/// whichever build it is handed -- so this describes *a* build, `readable` is the whole list, and
/// `pinned` is only the one the offsets happen to be recorded in.
public struct ROMIdentity: Sendable, Equatable, Identifiable {
    /// The build registry's own id, e.g. `2016-03-09-x64`. Stable, and not for display.
    public let id: String
    public let fileName: String
    public let product: String
    public let version: String
    /// `x64` or `x86`. Diagnostic only: the DLL is read as data, so either works on any machine.
    public let architecture: String
    public let length: Int64
    public let sha256: String

    /// Whether this is the build every table offset is recorded in.
    ///
    /// A reference coordinate system rather than a better copy: the tables and the wave ROM are the
    /// same data in every build listed, agreeing to within one 16-bit LSB when rendered through the
    /// real DLL. Someone who owns an older release is not getting a lesser one.
    public let isPinned: Bool

    init(_ identity: TSROMIdentity) {
        id = identity.identifier
        fileName = identity.fileName
        product = identity.product
        version = identity.version
        architecture = identity.architecture
        length = identity.length
        sha256 = identity.sha256
        isPinned = identity.isPinned
    }

    /// The build the engine's embedded manifest records its offsets in. Needs no ROM present.
    public static let pinned = ROMIdentity(TSROMIdentity.pinned)

    /// Every build the engine will accept, the pinned one among them. Needs no ROM present.
    public static let readable: [ROMIdentity] = TSROMIdentity.readableBuilds.map(ROMIdentity.init)
}
