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
    #expect(identity.architecture == "x64")
    #expect(identity.isPinned)
}

/// The same proof for the build registry, which is a second embedded asset with its own generated
/// translation unit: if it parses and names the builds the engine advertises, then
/// `builds_json.generated.cpp` is present and current. A stale copy is not a build error -- it is
/// an import screen offering files the engine will then refuse.
@Test func everyReadableBuildIsListed() {
    let builds = ROMIdentity.readable

    #expect(builds.map(\.id).sorted()
        == ["2016-03-09-x64", "2016-03-09-x86", "2019-10-30-x64"])

    // Exactly one build is the coordinate system the manifest's offsets are recorded in, and it is
    // the one `pinned` returns. More than one would mean the registry disagreed with itself.
    #expect(builds.filter(\.isPinned).count == 1)
    #expect(builds.first { $0.isPinned }?.sha256 == ROMIdentity.pinned.sha256)

    // The 2016 installer's files are not called SCCore.dll, which is the whole reason the import
    // screen lists file names rather than naming one.
    #expect(Set(builds.map(\.fileName))
        == ["SCCore.dll", "SCCore.64.dll", "SCCore.32.dll"])
}
