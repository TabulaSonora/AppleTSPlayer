import CoreMIDI
import Foundation
import OSLog

/// Attached MIDI keyboards, played into the running engine.
///
/// Live notes sound over a playing song, because one generator serves both -- the same arrangement
/// the module itself has, where the front panel keeps working while a sequence runs.
///
/// Everything here happens on CoreMIDI's own high-priority thread. It must never touch the
/// generator directly, and it does not: `Player.send` hands the message to an inbox the render
/// thread drains at its next block, so a MIDI source never waits on a block of synthesis.
public final class MIDIInput: @unchecked Sendable {
    private let log = Logger(subsystem: "co.losno.TabulaSonora", category: "midi")

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private let send: @Sendable (Int, Int, Int) -> Void

    /// - Parameter send: called with (status, data1, data2) for each channel voice message.
    public init(send: @escaping @Sendable (Int, Int, Int) -> Void) {
        self.send = send
    }

    deinit {
        if port != 0 { MIDIPortDispose(port) }
        if client != 0 { MIDIClientDispose(client) }
    }

    /// Opens every source the system can see, and follows the ones plugged in later.
    public func start() {
        guard client == 0 else { return }

        var status = MIDIClientCreateWithBlock("Tabula Sonora" as CFString, &client) { [weak self] in
            // A device appeared or vanished. Connecting is idempotent, so the simplest correct
            // response to any change is to make sure everything is connected.
            let message = $0.pointee
            if message.messageID == .msgSetupChanged {
                self?.connectAllSources()
            }
        }
        guard status == noErr else {
            log.error("Could not create a MIDI client: \(status)")
            return
        }

        // MIDI 1.0 protocol: the engine speaks channel voice messages, and asking CoreMIDI for 1.0
        // means it does the translation from any 2.0 source rather than this code doing it.
        status = MIDIInputPortCreateWithProtocol(client, "Input" as CFString, ._1_0, &port) {
            [weak self] eventList, _ in
            self?.handle(eventList)
        }
        guard status == noErr else {
            log.error("Could not create a MIDI input port: \(status)")
            return
        }

        connectAllSources()
    }

    private func connectAllSources() {
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }
            MIDIPortConnectSource(port, source, nil)
        }
    }

    private func handle(_ eventList: UnsafePointer<MIDIEventList>) {
        // Walked in place rather than through a copy of the list: `MIDIEventList` carries only its
        // first packet inline, so copying the struct and iterating that would read rubbish from the
        // second packet on.
        guard let offset = MemoryLayout<MIDIEventList>.offset(of: \.packet) else { return }

        var packet = UnsafeMutableRawPointer(mutating: UnsafeRawPointer(eventList))
            .advanced(by: offset)
            .assumingMemoryBound(to: MIDIEventPacket.self)

        for _ in 0..<eventList.pointee.numPackets {
            let count = Int(packet.pointee.wordCount)

            withUnsafeBytes(of: &packet.pointee.words) { raw in
                let buffer = raw.bindMemory(to: UInt32.self)
                var index = 0
                while index < count && index < buffer.count {
                    index += consume(buffer[index])
                }
            }

            packet = MIDIEventPacketNext(packet)
        }
    }

    /// Reads one Universal MIDI Packet word, returning how many words it consumed.
    ///
    /// Only channel voice messages are forwarded. System messages and SysEx are skipped by their
    /// declared length rather than guessed at, so a long SysEx does not desynchronise the walk.
    private func consume(_ word: UInt32) -> Int {
        let messageType = UInt8((word >> 28) & 0xF)

        switch messageType {
        case 0x2:  // MIDI 1.0 channel voice -- one word
            let status = Int((word >> 16) & 0xFF)
            let data1 = Int((word >> 8) & 0x7F)
            let data2 = Int(word & 0x7F)
            send(status, data1, data2)
            return 1
        case 0x0, 0x1:
            return 1   // utility, system real time
        case 0x3, 0x4:
            return 2   // 64-bit: SysEx 7-bit, MIDI 2.0 channel voice
        case 0x5:
            return 4   // 128-bit: SysEx 8-bit, mixed datasets
        default:
            // The upper nibble encodes size for everything defined: 0x0-0x2 are 32-bit, 0x3-0x4
            // 64-bit, 0x5 128-bit. Anything else is from a spec revision this does not know, and
            // its size is in the same place.
            return messageType >= 0x8 ? 4 : 1
        }
    }
}
