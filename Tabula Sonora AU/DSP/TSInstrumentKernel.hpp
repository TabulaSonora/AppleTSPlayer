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
    /// The cable a host sent on, as one of the module's two ports.
    ///
    /// Ports are the module's own second sixteen channels, and a host that offers more than one
    /// cable is the only way to reach them. Anything past the second folds onto it rather than
    /// disappearing, which is what the engine does with a file tagged for four ports.
    [[nodiscard]] static int portFor(const AUMIDIEvent &midi) noexcept
    {
        return midi.cable & 0x01;
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
