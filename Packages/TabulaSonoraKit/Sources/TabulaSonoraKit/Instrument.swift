import Foundation
import TabulaSonoraBridge

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

    // MARK: What the panel draws

    /// Published by the render block into atomics, so reading them takes no lock at all.
    ///
    /// The player's full `SessionSnapshot` is deliberately not offered here. It names every part,
    /// which means walking the voice pool and building strings under the engine's lock -- and here
    /// that lock is the one the audio thread is trying to take, so a panel polling for it would put
    /// a block of silence into the audio ten times a second. A plugin has no mixer to draw anyway:
    /// the parts a mixer shows are a property of a loaded song, and there is never one here.
    public var activeVoices: Int { engine.activeVoices }
    public var voiceCapacity: Int { engine.voiceCapacity }

    /// Whether the engine is in XG mode right now -- a bulk dump switches this under the plugin.
    public var isXGMode: Bool { engine.isXGMode }
}
