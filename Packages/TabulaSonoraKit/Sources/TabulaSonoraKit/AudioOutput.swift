import AVFoundation
import TabulaSonoraBridge

/// The device end of playback: an `AVAudioEngine` whose source node does nothing but copy out of
/// the engine's ring.
///
/// The division of labour is upstream's, and it is the reason this class is so short. A render
/// thread inside the bridge pulls blocks from the synth and writes them to a lock-free ring; the
/// callback below copies out of that ring and does nothing else -- no allocation, no lock, no
/// engine code. A slow block eats into the ring's lead instead of glitching the device.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private let sourceNode: AVAudioSourceNode
    private let format: AVAudioFormat

    /// - Parameter ringHandle: `TSEngine.ringHandle`, valid for that engine's lifetime.
    init(ringHandle: UnsafeMutableRawPointer) {
        // The synth always runs at 32 kHz. Connecting at its own rate rather than the device's puts
        // the conversion in the mixer, where CoreAudio does it, instead of in the engine, which
        // would have to be told the device rate and retold every time it changed.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: TSEngine.sampleRate,
                                         channels: 2) else {
            fatalError("32 kHz stereo float is not a format CoreAudio recognises")
        }
        self.format = format

        sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else {
                return kAudioServicesUnsupportedPropertyError
            }

            // Zero-pads whatever the ring could not supply, so the device is always handed a whole
            // block. Underruns are counted there and surfaced in the snapshot rather than hidden.
            _ = TSEngineRingRead(ringHandle, left, right, frameCount)
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }

    func start() throws {
        try configureSession()
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
    }

    /// Restarts the graph after an interruption or a route change has torn it down.
    func restart() throws {
        engine.stop()
        engine.reset()
        try start()
    }

    private func configureSession() throws {
        #if os(iOS) || os(visionOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        #endif
        // macOS has no audio session; the graph is the whole story there.
    }
}
