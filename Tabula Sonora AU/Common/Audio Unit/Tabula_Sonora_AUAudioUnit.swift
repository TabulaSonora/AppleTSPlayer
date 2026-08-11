//
//  Tabula_Sonora_AUAudioUnit.swift
//  Tabula Sonora AU
//

import AVFoundation
import TabulaSonoraKit
import os

private let log = Logger(subsystem: "co.losno.Tabula-Sonora-Player.Tabula-Sonora-AU",
                         category: "AudioUnit")

/// The Sound Canvas voice as an instrument plugin.
///
/// The engine is the same one the player app runs, read out of the same `SCCore.dll`: the app
/// imports it into a shared container and this reads it from there, because an Audio Unit extension
/// is sandboxed into a container of its own and has no other way to see a file the app was given.
///
/// What is different from the app is who drives the engine. There the audio device is the app's own
/// and a render thread runs ahead of it into a ring; here the host decides when to call and how much
/// to ask for, and during a bounce it asks far faster than realtime. So the engine renders inside
/// the render block, for exactly the frames asked for, and resamples its 32 kHz to the host's rate
/// on the way out.
public class Tabula_Sonora_AUAudioUnit: AUAudioUnit, @unchecked Sendable {
    /// The engine. Thread-safe by construction -- a host calls this class from whichever thread it
    /// likes, and the render block reaches the same object through `handle` without a message send.
    let instrument = Instrument()

    private var kernel = TSInstrumentKernel()
    private var processHelper: AUProcessHelper?

    private var outputBus: AUAudioUnitBus?
    private var _outputBusses: AUAudioUnitBusArray!

    private let state = NSLock()
    private var _romFailure: String?
    private var isLoadingROM = false

    /// Why there is no sound, in the engine's own words, or nil while there is.
    ///
    /// Read by the panel, written by whichever thread finished the load. A lock rather than an
    /// actor because everything else on this class is reachable from any thread too.
    var romFailure: String? {
        get { state.withLock { _romFailure } }
        set { state.withLock { _romFailure = newValue } }
    }

    @objc override init(componentDescription: AudioComponentDescription,
                        options: AudioComponentInstantiationOptions) throws {
        try super.init(componentDescription: componentDescription, options: options)

        // A placeholder rate. The host replaces the bus format before it allocates render
        // resources, and the engine is told the real one there.
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let bus = try AUAudioUnitBus(format: format)
        bus.maximumChannelCount = 2

        // Stereo only. The module's output stage is a stereo mix and the parts have pan positions
        // in it; folding that to mono is the host's business, not something to fake here.
        bus.supportedChannelCounts = [2]

        outputBus = bus
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [bus])

        kernel.setInstrument(instrument.handle)
        processHelper = AUProcessHelper(&kernel)

        loadROM()
    }

    /// Opens the shared ROM, off whatever thread instantiated the plugin.
    ///
    /// A host instantiates plugins on its main thread and expects that to return promptly; this
    /// reads and parses 27 MB. Until it finishes the render block produces silence, which is also
    /// what the panel says is happening.
    private func loadROM() {
        // One at a time. Each attempt builds a whole second session before swapping it in, so two
        // at once would hold two sets of the engine's 27 MB of tables to no purpose -- and the
        // "Look again" button in the panel is exactly the thing that invites a second attempt while
        // the first is still reading.
        state.lock()
        if isLoadingROM {
            state.unlock()
            return
        }
        isLoadingROM = true
        state.unlock()

        let instrument = self.instrument
        Task.detached(priority: .userInitiated) { [weak self] in
            defer { self?.state.withLock { self?.isLoadingROM = false } }

            do {
                try instrument.loadSharedROM()
                self?.romFailure = nil
            } catch InstrumentFailure.noSharedROM {
                self?.romFailure = String(localized: "No Sound Canvas ROM has been imported yet.")
            } catch {
                log.error("ROM load failed: \(error.localizedDescription)")
                self?.romFailure = error.localizedDescription
            }
        }
    }

    /// Tries again after the app has imported a ROM, since the plugin may have been open the whole
    /// time and nothing tells it the container's contents changed.
    func retryROM() {
        loadROM()
    }

    // MARK: - Busses

    public override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    public override var maximumFramesToRender: AUAudioFrameCount {
        get { kernel.maximumFramesToRender() }
        set { kernel.setMaximumFramesToRender(newValue) }
    }

    /// The resampler's look-ahead, which is a frame at 32 kHz and worth declaring anyway: an
    /// undeclared delay is how a plugin drifts against a click nobody can explain.
    public override var latency: TimeInterval { instrument.latencySeconds }

    // MARK: - MIDI

    /// Two cables, because the module has two ports and its second sixteen parts are unreachable
    /// otherwise. `TSInstrumentKernel` maps a cable to a port.
    public override var virtualMIDICableCount: Int { 2 }

    // MARK: - Rendering

    public override var internalRenderBlock: AUInternalRenderBlock {
        processHelper!.internalRenderBlock()
    }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()

        let format = outputBusses[0].format
        processHelper?.setChannelCount(0, format.channelCount)

        // The one place a plugin may allocate: the resampler sizes its buffers from the rate and
        // the largest block the host has promised, and never grows them again.
        instrument.prepare(sampleRate: format.sampleRate,
                           maximumFrames: Int(maximumFramesToRender))
    }

    // MARK: - Parameters

    public func setupParameterTree(_ parameterTree: AUParameterTree) {
        self.parameterTree = parameterTree

        applyEverything()

        // Called for every change a host or a view makes. Gain is the one that can be answered
        // without a rebuild; the rest go the long way round, which is right, because each of them
        // makes a new tone generator.
        parameterTree.implementorValueObserver = { [weak self] parameter, value in
            guard let self else { return }

            if parameter.address == Tabula_Sonora_AUParameterAddress.gain.rawValue {
                TSInstrumentSetGain(self.instrument.handle, Double(value))
                var settings = self.instrument.settings
                settings.outputGain = Double(value)
                self.instrument.apply(settings)
            } else {
                self.applyEverything()
            }
        }

        parameterTree.implementorStringFromValueCallback = { parameter, valuePointer in
            let value = valuePointer?.pointee ?? parameter.value

            // An indexed parameter names its own values; the gain is a multiplier, and a percentage
            // says what moving it did where "1.20" only says what it is called.
            if let strings = parameter.valueStrings {
                let index = Int(value.rounded())
                return strings.indices.contains(index) ? strings[index] : "-"
            }
            if parameter.address == Tabula_Sonora_AUParameterAddress.gain.rawValue {
                return "\(Int((value * 100).rounded()))%"
            }
            return value > 0.5 ? String(localized: "On") : String(localized: "Off")
        }
    }

    /// Reads the whole tree and hands the engine one settings block.
    ///
    /// One block rather than one call per parameter because that is what the engine wants: a single
    /// rebuild, with each part's state replayed across it, instead of one rebuild per control.
    private func applyEverything() {
        guard let parameterTree else { return }
        instrument.apply(EngineSettings.from(parameterTree))
    }
}
