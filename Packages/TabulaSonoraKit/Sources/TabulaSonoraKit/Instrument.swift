import Foundation
import TabulaSonoraBridge

/// What a plugin's panel draws, taken from the engine in one look.
///
/// A value, not an observable object: the Audio Unit's view builds its own state around this at
/// whatever rate it likes, and the audio unit itself has no view for most of its life.
public struct InstrumentSnapshot: Sendable {
    public let activeVoices: Int
    public let voiceCapacity: Int
    /// Whether the engine is in XG mode right now -- a bulk dump switches this under the plugin.
    public let isXGMode: Bool
    /// Every part the engine has ports for. Unlike the player's, none of these is marked present:
    /// presence is a property of a loaded song, and a plugin never has one.
    public let parts: [PartState]

    init(_ snapshot: TSSnapshot) {
        activeVoices = snapshot.activeVoices
        voiceCapacity = snapshot.voiceCapacity
        isXGMode = snapshot.xgMode
        parts = snapshot.parts.map(PartState.init)
    }
}

/// Why an instrument has nothing to play.
public enum InstrumentFailure: Error {
    /// No `SCCore.dll` in the shared container. The app has to import one first; a plugin cannot,
    /// because the file it needs is not something a file picker in a plugin window should be asking
    /// a musician for in the middle of a session.
    case noSharedROM
}

/// The engine as an Audio Unit plays it.
///
/// Deliberately **not** `@MainActor`, unlike `Player`. A plugin is called on threads it does not
/// choose: `allocateRenderResources` arrives on whichever thread the host felt like using, state is
/// restored on another, and the render block runs on the audio thread. The object underneath
/// serialises all of that itself -- see `TSInstrument` -- so the right shape here is a thread-safe
/// façade and a view model built on top of it, rather than an actor the host would have to await.
///
/// The render block does not go through this at all. It takes `handle` once and calls the C
/// functions in `TSEngine.h`, which is the only path that touches the engine without a message send.
public final class Instrument: @unchecked Sendable {
    private let engine = TSInstrument()
    private let lock = NSLock()
    private var stored = EngineSettings.default

    public init() {}

    /// Pass to `TSInstrumentRender` and friends. Valid for this object's lifetime.
    public var handle: UnsafeMutableRawPointer { engine.handle }

    public var romName: String? { engine.romName }
    public var hasROM: Bool { engine.hasROM }

    /// The delay to report to the host, from the resampler's one-frame look-ahead.
    public var latencySeconds: TimeInterval { engine.latencySeconds }

    /// Sizes the resampler for the host's rate and its largest block.
    ///
    /// From `allocateRenderResources`, where a plugin is allowed to allocate.
    public func prepare(sampleRate: Double, maximumFrames: Int) {
        engine.prepare(forSampleRate: sampleRate, maximumFrames: UInt32(maximumFrames))
    }

    /// Opens the ROM the app imported.
    ///
    /// Call off the audio thread and off the main one: this reads and parses 27 MB. Rendering
    /// continues throughout -- silently, since until this returns there is nothing to render.
    ///
    /// Verifies fully only when nobody has: the flag lives in the shared container beside the file,
    /// so a ROM the app already hashed costs a size and timestamp check here.
    public func loadSharedROM() throws {
        guard ROMStore.hasImportedROM else { throw InstrumentFailure.noSharedROM }

        try engine.loadROM(atPath: ROMStore.romURL.path(percentEncoded: false),
                           verifyFully: !ROMStore.isROMVerified)
        ROMStore.isROMVerified = true

        // The settings the host restored before there was an engine to apply them to.
        engine.apply(settings.bridged)
    }

    /// Rebuilds the generator unless only the gain moved, exactly as in the app.
    public func apply(_ settings: EngineSettings) {
        lock.lock()
        stored = settings
        lock.unlock()

        engine.apply(settings.bridged)
    }

    public var settings: EngineSettings {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func snapshot() -> InstrumentSnapshot {
        InstrumentSnapshot(engine.snapshot())
    }
}
