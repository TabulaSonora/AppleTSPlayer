import Foundation
import TabulaSonoraBridge

/// The `SCCore.dll` build the engine is pinned to.
///
/// Nothing Roland-derived is committed anywhere in this repository -- this is the description of a
/// file the user has to supply, not the file itself.
public struct ROMIdentity: Sendable, Equatable {
    public let fileName: String
    public let product: String
    public let version: String
    public let length: Int64
    public let sha256: String

    /// The identity compiled into the engine's embedded table manifest. Needs no ROM present.
    public static let pinned: ROMIdentity = {
        let identity = TSROMIdentity.pinned
        return ROMIdentity(
            fileName: identity.fileName,
            product: identity.product,
            version: identity.version,
            length: identity.length,
            sha256: identity.sha256)
    }()
}
