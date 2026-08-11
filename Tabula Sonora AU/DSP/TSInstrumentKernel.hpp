//
//  TSInstrumentKernel.hpp
//  Tabula Sonora AU
//

#pragma once

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMIDI/CoreMIDI.h>

#import "TSEngine.h"
#import "Tabula_Sonora_AUParameterAddresses.h"

#include <algorithm>
#include <vector>

/// Everything the render block does, which is almost nothing.
///
/// The synthesis is behind `TSInstrumentRender`, in the package, where the engine and its resampler
/// live. What is left here is the translation: MIDI bytes into the engine's own call, and the two
/// output pointers the host handed us. Nothing in this file allocates, locks or takes a reference,
/// because everything in it runs on the audio thread.
///
/// The plugin does **not** adopt `MIDIEventList`. Left alone, the framework hands over legacy
/// `AURenderEventMIDI` events -- MIDI 1.0 bytes, and a complete System Exclusive message in one
/// piece -- which is exactly the shape a module built around seven-bit controllers and GS bulk
/// dumps wants. Adopting the newer protocol would mean reassembling six-byte fragments back into
/// the messages the framework had already assembled.
///
/// It also costs nothing in ports, and adopting would: the two protocols do not translate their
/// port number into one another. Measured, on macOS 27 -- a unit left legacy receives the host's
/// `cable` verbatim through `scheduleMIDIEventBlock`, and when a host schedules a `MIDIEventList`
/// instead the framework's conversion carries that block's own `cable` argument, *not* the group
/// nibble inside each packet. A unit that adopts the protocol is the mirror image: the group
/// survives, and a legacy `scheduleMIDIEventBlock` arrives on group 0 with the cable thrown away.
/// So staying legacy is what keeps the ports reachable from the widest set of hosts.
class TSInstrumentKernel {
public:
    /// The engine to drive. From `TabulaSonoraKit.Instrument.handle`, which outlives the kernel.
    void setInstrument(void *handle) noexcept { mHandle = handle; }

    void setMaximumFramesToRender(AUAudioFrameCount frames) noexcept { mMaxFrames = frames; }
    [[nodiscard]] AUAudioFrameCount maximumFramesToRender() const noexcept { return mMaxFrames; }

    void process(std::vector<float *> &outputs, AUEventSampleTime /*now*/,
                 AUAudioFrameCount frameCount) noexcept
    {
        if (outputs.size() < 2 || outputs[0] == nullptr || outputs[1] == nullptr) {
            return;
        }

        if (mHandle == nullptr) {
            std::fill_n(outputs[0], frameCount, 0.0F);
            std::fill_n(outputs[1], frameCount, 0.0F);
            return;
        }

        TSInstrumentRender(mHandle, outputs[0], outputs[1], frameCount);
    }

    void handleOneEvent(AUEventSampleTime /*now*/, AURenderEvent const *event) noexcept
    {
        if (mHandle == nullptr || event == nullptr) {
            return;
        }

        switch (event->head.eventType) {
        case AURenderEventParameter:
        case AURenderEventParameterRamp:
            // Gain and nothing else. Every other parameter rebuilds the tone generator, which
            // allocates and takes milliseconds -- a control-path job, and one the audio thread
            // would be wrong to ask for however the host schedules it.
            if (event->parameter.parameterAddress == Tabula_Sonora_AUParameterAddress::gain) {
                TSInstrumentSetGain(mHandle, event->parameter.value);
            }
            break;

        case AURenderEventMIDI:
            handleMIDI(event->MIDI);
            break;

        case AURenderEventMIDISysEx:
            handleSysEx(event->MIDI);
            break;

        default:
            break;
        }
    }

private:
    /// The cable a host sent on, as one of the four ports the engine can back.
    ///
    /// A port is another sixteen parts, and the cable is the only thing in a MIDI stream that says
    /// which one a message is for -- exactly as it is on the hardware, where the port rides in the
    /// USB-MIDI packet's cable nibble and nothing latches it between messages. The framework hands
    /// the number over untouched: `AUMIDIEvent.cable` is whatever the host passed to
    /// `scheduleMIDIEventBlock`, for a channel voice message and for a SysEx alike.
    ///
    /// Masked to four because that is the most parts `TS_MAX_PARTS` has room for. Folding rather
    /// than dropping is what the module does with the twelve cables it advertises and cannot back,
    /// and what the engine does again below this with a port past the configured count -- a stream
    /// meant for port C on a two-port setting lands on port A rather than going silent.
    [[nodiscard]] static int portFor(const AUMIDIEvent &midi) noexcept
    {
        return midi.cable & 0x03;
    }

    void handleMIDI(const AUMIDIEvent &midi) noexcept
    {
        if (midi.length == 0) {
            return;
        }

        const std::uint8_t status = midi.data[0];

        // Channel voice only. System common and real-time carry no part state, and the engine has
        // no transport of its own for a clock to drive.
        if (status < 0x80 || status >= 0xF0) {
            return;
        }

        TSInstrumentSendChannel(mHandle, portFor(midi), status,
                                midi.length > 1 ? midi.data[1] : 0,
                                midi.length > 2 ? midi.data[2] : 0);
    }

    void handleSysEx(const AUMIDIEvent &midi) noexcept
    {
        if (midi.length == 0) {
            return;
        }

        // `data` is declared as three bytes and the message continues past it: the framework
        // allocates the event large enough for `length` and this is the documented way to read it.
        TSInstrumentSendSysEx(mHandle, portFor(midi), midi.data, midi.length);
    }

    void *mHandle = nullptr;
    AUAudioFrameCount mMaxFrames = 1024;
};
