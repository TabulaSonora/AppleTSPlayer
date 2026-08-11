# Tabula Sonora Player

A native Apple front end for [NativeTS](https://github.com/TabulaSonora/NativeTS) — the C++
reimplementation of the Roland Sound Canvas VA synth voice. SwiftUI, macOS and iOS.

It plays Standard MIDI Files, and the rest of what the engine reads: RIFF-MIDI, DirectMusic `MIDS`,
DOOM `MUS`, Miles `XMI`, `GMF`, both HMI containers, Mobile XMF and LDS tracker files, all converted
to SMF on the way in.

- Transport with seeking and looping at the file's own loop points
- A mixer strip per part the file addresses — instrument name, live voice count, mute and solo
- Engine settings: vintage (SC-55 / 88 / 88Pro / 8820 / XG), 16/32/64 parts, polyphony, the four
  effect buses, output gain, and an adjustable buffer
- WAV export, rendered through the library's own writer so the bytes match `tabula-sonora render`
- An **AUv3 instrument** (`aumu` / `tbsn` / `LSCo`) that plays the same voice from a DAW, over MIDI
  including GS and XG System Exclusive

## You need to supply the ROM

The engine is inert without `SCCore.dll` from a licensed SOUND Canvas VA 1.1.6 install — 27,347,456
bytes, SHA-256 `117e6aa1…bdb1`. It is read as *data* and never loaded as code. The app asks for it on
first launch, verifies it against that build, and keeps a copy in a container it shares with the
plugin — an Audio Unit extension is sandboxed on its own and could not otherwise see the file.

**Nothing Roland-derived is in this repository, and nothing derived from it should be added.**

## Building

```sh
git clone --recurse-submodules https://github.com/TabulaSonora/AppleTSPlayer.git
open "Tabula Sonora Player.xcodeproj"
```

The engine is compiled from source by SwiftPM — no CMake, no vcpkg. `Packages/TabulaSonoraKit`
holds NativeTS as a submodule alongside an Objective-C++ bridge and the Swift API; see
[its README](Packages/TabulaSonoraKit/README.md) for the two things that are easy to get wrong
(the numeric-semantics flags, and the generated table manifest).

```sh
cd Packages/TabulaSonoraKit
TS_SCCORE_DLL=~/SCCore.dll TS_TEST_MIDI=~/song.mid swift test
```

Tests that need the ROM or a MIDI file skip when the environment does not name them, so the suite
runs anywhere.

## Licence

BSD 3-Clause, the same as the engine — see [LICENSE](LICENSE).

That covers this repository. It does not cover `SCCore.dll`, which is Roland's and yours to supply
under whatever licence came with your copy of SOUND Canvas VA. `Sources/ThirdParty/nlohmann/json.hpp`
is MIT and carries its own notice in the header.

## How it fits together

The engine renders at 32 kHz and is single-threaded by contract. In the app a render thread owns it
and writes whole blocks into a lock-free ring; the `AVAudioSourceNode` callback copies out of that
ring and does nothing else — no allocation, no lock, no engine code. A slow block eats into the ring's
lead rather than glitching the device, and the buffer setting is how far ahead that lead runs.

The plugin cannot work that way. Its host decides when to call it, and during a bounce it asks for
audio far faster than realtime — which a producer running at wall-clock rate can never keep up with.
So there the engine renders inside the host's render block, for exactly the frames asked for, and
resamples to the host's rate on the way out. The contract still holds: one owning thread, and it is
the host's. See [the extension's README](Tabula%20Sonora%20AU/README.md).
