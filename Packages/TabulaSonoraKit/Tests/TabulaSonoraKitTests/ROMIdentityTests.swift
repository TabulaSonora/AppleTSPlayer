import Testing
@testable import TabulaSonoraKit

/// The same check `nativets/tests/package/main.cpp` makes as a foreign consumer of the library:
/// if the embedded manifest parses and reports the pinned build, then the engine sources compiled,
/// linked, and found their compiled-in asset. It needs no `SCCore.dll`, so it runs anywhere.
@Test func pinnedROMIdentityMatchesTheEmbeddedManifest() {
    let identity = ROMIdentity.pinned

    #expect(identity.sha256
        == "117e6aa147a96fbde5e10d2caf16c89965acc1e44235fd245992216cc620bdb1")
    #expect(identity.length == 27_347_456)
    #expect(identity.fileName == "SCCore.dll")
    #expect(identity.version == "1.1.6")
}
