# Tabula Sonora AU

An AUv3 instrument (`aumu`, `tbsn`, `LSCo`) that plays MIDI through the same NativeTS engine the app
plays files through, out of the same `SCCore.dll`.

## How it differs from the app

The app owns its audio device: a render thread runs ahead of it into a lock-free ring, and the
device callback does nothing but copy out of that ring. A plugin owns nothing. Its host decides when
to call and how many frames to ask for, and during a bounce it asks far faster than realtime — which
a producer running at wall-clock rate can never satisfy, so a ring between the two would hand back
silence for the one operation that has to come out exact.

So the engine renders **inside the render block**, on the host's audio thread, for exactly the frames
asked for, and resamples its fixed 32 kHz to the host's rate on the way out. That is not a departure
from the engine's threading contract — `ToneGenerator` wants one owning thread, and here that thread
is the host's. MIDI arrives on it too, before the audio between events is asked for, so the live-MIDI
inbox and the control mutex the app's `TSPlayer` needs are not needed here.

`ts::apple::Instrument` (in the package, beside `ts::apple::Player`) is that arrangement. Control —
loading a ROM, changing settings — does its expensive work outside a lock; the render block
`try_lock`s and gives up rather than wait, so the worst a settings change costs is one block of
silence, and the only change that can cause one already takes the sounding voices.

## The ROM

The engine reads a user-supplied `SCCore.dll`, and an extension is sandboxed into a container of its
own. The app imports the file into an **app group** container and this reads it from there. There is
nothing to import here and no picker to do it with: see `ROMStore` in `TabulaSonoraKit`.

The group identifier is spelled differently per platform — `group.co.losno.tabula-sonora` on iOS,
team-prefixed on macOS — which is why each target has two entitlements files, selected by
`CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`.

## Layout

| Path | What it is |
| --- | --- |
| `DSP/TSInstrumentKernel.hpp` | The render block's whole job: MIDI bytes in, `TSInstrumentRender` out. Nothing here allocates or locks. |
| `Common/DSP/…AUProcessHelper.hpp` | Xcode's template helper, kept: it splits a block at event boundaries, which is exactly what sample-accurate MIDI needs. |
| `Parameters/` | The engine's settings as an `AUParameterTree`, which is also how a host saves and restores them. |
| `Common/Audio Unit/…AudioUnit.swift` | The `AUAudioUnit` subclass: busses, MIDI cables, latency, and the parameter routing. |
| `UI/…MainView.swift` | The panel — ROM status, voice count, the settings. |

## Ports

The plugin declares **four virtual MIDI cables**, one per port, so one instance reaches all 64 parts
at the engine's largest `ports` setting. There is no such thing as a port-select message: the port
rides on each message, in the USB-MIDI packet's cable nibble on the hardware and in
`AUMIDIEvent.cable` here, and nothing latches it from one message to the next.

Measured on macOS 27, because the two MIDI protocols do not translate their port number into one
another and the choice is therefore load-bearing:

| The unit adopts | Host schedules | What the render block sees |
| --- | --- | --- |
| MIDI 1.0 bytes (this plugin) | `scheduleMIDIEventBlock` | `cable` verbatim, 0–15, channel voice and SysEx alike |
| MIDI 1.0 bytes (this plugin) | `scheduleMIDIEventListBlock` | that block's `cable` argument — **not** the group nibble in the packets |
| `MIDIEventList` | `scheduleMIDIEventListBlock` | the UMP group, intact |
| `MIDIEventList` | `scheduleMIDIEventBlock` | group 0 always — the cable is **dropped** |

So staying on legacy events, which `TSInstrumentKernel` explains for its own reasons, is also what
keeps the ports reachable from the most hosts. `virtualMIDICableCount` is advertising and not a
gate — a unit declaring one cable still receives cable 3 — and the count is declared fixed rather
than following the `ports` parameter, because a host reads it once when it wires up the instrument's
inputs. Nothing is lost by that: the engine folds a port past the configured count onto one that
exists (`port & (ports - 1)`), exactly as the module folds the sixteen USB cables it advertises onto
the two ports of parts it actually has.

`InstrumentTests.aPortNumberReachesItsOwnParts` is the regression test, and it measures by ear —
one port's channel 1 turned down to nothing, all four played — because every port quietly collapsing
onto port A sounds perfectly healthy to anything that only asks whether a note sounded.

## Parameters

Only `gain` is a parameter in the sense a host means: a number that may be automated and applied
inside a render block. Every other address rebuilds the tone generator, which allocates, so the
render block ignores them and they are applied from the control path. They are parameters at all
because the default `fullState` carries the parameter tree, which is how a session reopens on the
module it was saved with.

## Testing it

```sh
auval -v aumu tbsn LSCo          # after running the app once, so the extension registers
```

The app must have run at least once for the component to register, and the offline render tests in
`InstrumentTests` cover the resampler without a host at all.
