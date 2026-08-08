import AVFoundation
import Foundation
import Observation
import TabulaSonoraBridge

/// The engine, its audio output and the state a UI draws from.
///
/// Everything here is main-actor. The engine's own state is never read directly: the render thread
/// publishes a snapshot roughly every 20 ms and this polls a copy of it, which is what keeps the
/// single-threaded synth single-threaded with a mixer attached.
@MainActor
@Observable
public final class Player {
    /// The engine's frame rate. Everything measured in frames is at this rate.
    public static let sampleRate = TSEngine.sampleRate

    /// The `SCCore.dll` build the engine requires, for an import screen to name.
    public static let requiredROM = ROMIdentity.pinned

    // MARK: State a view draws

    public private(set) var romName: String?
    public private(set) var songName: String?
    public private(set) var isPlaying = false
    public private(set) var isComplete = false

    /// What is audible, in seconds -- which lags what has been rendered by the ring's lead.
    public private(set) var position: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0

    public private(set) var activeVoices = 0
    public private(set) var voiceCapacity = 0
    public private(set) var isXGMode = false

    /// How many times the audio callback came up short. Never hide this from the user: a glitch
    /// they hear but the display does not mention reads as a fault in the engine.
    public private(set) var underruns: Int64 = 0
    public private(set) var peakLeft: Float = 0
    public private(set) var peakRight: Float = 0

    /// As many parts as the engine has ports for. A mixer should show those marked `isPresent`.
    public private(set) var parts: [PartState] = []

    public private(set) var settings = EngineSettings.default

    public var isLooping = false {
        didSet {
            engine.isLooping = isLooping
            preferences.isLooping = isLooping
        }
    }

    /// How far ahead of the device the engine renders, in milliseconds.
    ///
    /// This is the buffer: lower means a live keyboard answers sooner and a seek is heard sooner,
    /// higher leaves more room for the render thread to be descheduled without the audio callback
    /// coming up short. Watch `underruns` when lowering it -- that is the number this trades against.
    ///
    /// Takes effect at the next block and never reallocates, so it is safe to drag a slider against.
    public var latencyMilliseconds: Int {
        didSet {
            engine.latencyMilliseconds = latencyMilliseconds
            preferences.latencyMilliseconds = latencyMilliseconds
        }
    }

    public static let latencyRange =
        TSEngine.minimumLatencyMilliseconds...TSEngine.maximumLatencyMilliseconds

    // MARK: Machinery

    /// The engine crosses isolation boundaries deliberately, so live MIDI can reach it from a
    /// source's own thread and an export can run off the main actor.
    ///
    /// This is a claim about the bridge, not a suppression: `ts::apple::Player` serialises every
    /// control operation behind a mutex, takes live MIDI through a separate inbox so a MIDI source
    /// never waits on a block render, and routes mute and solo through `ChannelMask`, whose flags
    /// are atomic for exactly this reason. The one thing that is *not* safe -- touching the
    /// `ToneGenerator` from two threads -- is what the bridge exists to prevent.
    private struct EngineBox: @unchecked Sendable {
        let engine: TSEngine
    }

    @ObservationIgnored nonisolated private let box: EngineBox
    @ObservationIgnored private let output: AudioOutput
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var nowPlaying: NowPlaying?

    /// Where the system was last told the transport was, so a jump can be told from ordinary drift.
    @ObservationIgnored private var lastPublishedPosition: TimeInterval = 0

    nonisolated private var engine: TSEngine { box.engine }

    public init(defaults: UserDefaults = .standard) {
        let engine = TSEngine()
        let preferences = Preferences(defaults: defaults)

        self.box = EngineBox(engine: engine)
        self.output = AudioOutput(ringHandle: engine.ringHandle)
        self.preferences = preferences

        // Restored before anything is loaded, which is also when it is free. The session keeps the
        // settings it is handed even with no ROM open and builds the generator from them when one
        // arrives, so restoring here costs no rebuild and resets nobody's parts.
        let stored = preferences.settings
        self.settings = stored
        self.latencyMilliseconds = preferences.latencyMilliseconds ?? engine.latencyMilliseconds
        self.isLooping = preferences.isLooping

        engine.apply(stored.bridged)
        engine.latencyMilliseconds = self.latencyMilliseconds
        engine.isLooping = self.isLooping

        observeAudioInterruptions()

        nowPlaying = NowPlaying(commands: NowPlaying.Commands(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            toggle: { [weak self] in self?.togglePlaying() },
            seek: { [weak self] in self?.seek(toSeconds: $0) },
            skip: { [weak self] offset in
                guard let self else { return }
                self.seek(toSeconds: self.position + offset)
            }))
    }

    // MARK: Loading

    /// Opens a `SCCore.dll`.
    ///
    /// - Parameter verifyFully: hashes all 27 MB, which takes a moment. Do it once, when the file
    ///   is first imported; a file already verified needs only its size and PE timestamp checked.
    public func loadROM(at url: URL, verifyFully: Bool) throws {
        try engine.loadROM(atPath: url.path(percentEncoded: false), verifyFully: verifyFully)
        romName = engine.romName
        try startOutput()
        startTicking()
    }

    public func loadSong(at url: URL) throws {
        try engine.loadSong(atPath: url.path(percentEncoded: false))
        songName = engine.songName
        isComplete = false
        try startOutput()
        startTicking()

        // The bridge publishes a snapshot before `loadSong` returns, so this picks up the song's
        // length now rather than a tenth of a second later -- without it the system would be handed
        // a zero duration and draw a scrubber that cannot be dragged.
        refresh()
        publishNowPlaying()
    }

    public func unloadSong() {
        pause()
        engine.unloadSong()
        songName = nil
        isComplete = false
        nowPlaying?.clear()
    }

    /// Starts the audio graph and hands its workgroup to the render thread.
    ///
    /// The two belong together. A device only has a workgroup once its hardware is running, and it
    /// is a different one after a restart -- so every path that starts the graph has to re-adopt,
    /// or the render thread stays joined to a workgroup that no longer drives anything.
    private func startOutput(restarting: Bool = false) throws {
        if restarting {
            try output.restart()
        } else {
            try output.start()
        }
        engine.adoptWorkgroup(from: output.outputAudioUnit)
    }

    // MARK: Transport

    public func play() {
        guard romName != nil else { return }

        // A finished song restarts rather than refusing: at the end, Play cannot mean anything else.
        if isComplete {
            engine.seek(toFrame: 0)
            isComplete = false
        }

        engine.isPaused = false
        isPlaying = true
        publishNowPlaying()
    }

    public func pause() {
        engine.isPaused = true
        isPlaying = false
        publishNowPlaying()
    }

    public func togglePlaying() {
        isPlaying ? pause() : play()
    }

    public func seek(toSeconds seconds: TimeInterval) {
        engine.seek(toFrame: Int64(max(0, seconds) * Self.sampleRate))
        isComplete = false
        position = max(0, min(seconds, duration))
        publishNowPlaying()
    }

    /// Silences everything and returns every part to its power-on state.
    public func panic() {
        engine.panic()
    }

    // MARK: Mixer

    public func setMuted(_ muted: Bool, forPart part: Int) {
        engine.setMuted(muted, forPart: part)
    }

    public func setSoloed(_ soloed: Bool, forPart part: Int) {
        engine.setSoloed(soloed, forPart: part)
    }

    public func resetChannels() {
        engine.resetChannels()
    }

    // MARK: Engine settings

    /// Rebuilds the generator if anything structural changed, carrying part state across it.
    /// Gain alone is applied live.
    public func apply(_ settings: EngineSettings) {
        self.settings = settings
        engine.apply(settings.bridged)
        preferences.store(settings)
        publishNowPlaying()
    }

    /// Tells the system what is playing.
    ///
    /// Called where the state actually changes rather than from the ten-per-second refresh: the
    /// elapsed time goes out with a playback rate beside it and the system extrapolates, so
    /// republishing on a timer would keep resetting the very extrapolation it depends on.
    private func publishNowPlaying() {
        guard let songName else {
            lastPublishedPosition = 0
            nowPlaying?.clear()
            return
        }

        lastPublishedPosition = position

        nowPlaying?.update(
            title: (songName as NSString).deletingPathExtension,
            module: settings.map.name,
            duration: duration,
            position: position,
            isPlaying: isPlaying)
    }

    // MARK: Live MIDI

    /// One channel voice message, sounding over a playing song because one generator serves both --
    /// the arrangement the module itself has, where the front panel keeps working while a sequence
    /// runs.
    ///
    /// Nothing in the app calls this yet: the CoreMIDI source that did was taken out and is coming
    /// back. It stays `nonisolated` for that return -- the bridge takes live messages through an
    /// inbox the render thread drains at its next block, so this never blocks on a render and is
    /// safe to call from a MIDI callback's own thread.
    public nonisolated func send(status: Int, data1: Int, data2: Int, port: Int = 0) {
        engine.sendChannel(onPort: port, status: status, data1: data1, data2: data2)
    }

    // MARK: Export

    /// Renders the loaded song to a WAV, off the main actor, while playback continues.
    ///
    /// Goes through the library's own writer over a second generator, so the result is the same
    /// bytes a `tabula-sonora render` with these settings would produce -- not merely similar ones.
    public func exportWAV(to url: URL,
                          progress: @escaping @Sendable (Double) -> Bool) async throws {
        let box = self.box
        let path = url.path(percentEncoded: false)
        try await Task.detached(priority: .userInitiated) {
            try box.engine.exportWAV(toPath: path) { progress($0) }
        }.value
    }

    // MARK: Snapshot polling

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                // Ten times a second. The render thread publishes far more often; this is a display
                // refresh, not a sampling of the engine.
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func refresh() {
        let snapshot = engine.snapshot()

        position = TimeInterval(snapshot.position) / Self.sampleRate
        duration = TimeInterval(snapshot.length) / Self.sampleRate
        activeVoices = snapshot.activeVoices
        voiceCapacity = snapshot.voiceCapacity
        isXGMode = snapshot.xgMode
        underruns = snapshot.underruns
        peakLeft = snapshot.peakLeft
        peakRight = snapshot.peakRight
        parts = snapshot.parts.map(PartState.init)

        // A song that wraps at its loop points moves the position backwards, and the system has no
        // way to know: it is extrapolating forwards from the last thing it was told. Anything that
        // is not the steady forward creep of playback gets republished.
        if isPlaying, position < lastPublishedPosition - 1 {
            publishNowPlaying()
        }

        if snapshot.complete && !isComplete {
            isComplete = true
            pause()   // publishes
        }
    }

    // MARK: Interruptions

    private func observeAudioInterruptions() {
        #if os(iOS) || os(visionOS)
        let center = NotificationCenter.default

        center.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []

            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .began:
                    self.pause()
                case .ended where options.contains(.shouldResume):
                    try? self.startOutput(restarting: true)
                    self.play()
                default:
                    break
                }
            }
        }

        center.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

            // Headphones pulled out. Carrying on through the speaker is never what was wanted.
            if reason == .oldDeviceUnavailable {
                MainActor.assumeIsolated { self?.pause() }
            }
        }
        #endif
    }
}
