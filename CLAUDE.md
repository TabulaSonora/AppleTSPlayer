# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A SwiftUI front end (macOS + iOS/visionOS, one target) for **NativeTS**, a C++20 reimplementation of
the Roland Sound Canvas VA synth voice. The engine is a git submodule compiled from source by
SwiftPM; this repo is the bridge and the UI over it.

## Commands

Needs a full Xcode, not CommandLineTools. If `xcodebuild`/`swift` reports "requires Xcode", the
selected toolchain is wrong — `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, or
prefix one command with `DEVELOPER_DIR=…`.

```sh
git submodule update --init                     # nativets/ — nothing builds without it

# Package (engine + bridge + Swift API)
cd Packages/TabulaSonoraKit && swift build
swift test                                      # ROM/MIDI tests skip when unnamed
TS_SCCORE_DLL=~/SCCore.dll TS_TEST_MIDI=~/song.mid swift test
swift test --filter RenderTests                 # one suite
swift test --filter "RingTests/seekingFlushesWhatWasQueued"   # one test

# App
xcodebuild -project "Tabula Sonora Player.xcodeproj" -scheme "Tabula Sonora Player" \
  -destination 'platform=macOS' build
```

`ROMIdentityTests` needs no ROM and is the cheap proof that the engine sources compiled, linked, and
found their compiled-in asset — run it first when a build looks broken.

## Three things that will silently break the engine

**Never add `-ffast-math`, and never drop `-fwrapv` or `-ffp-contract=off`** (`Package.swift`,
`cxxSettings`). These are correctness requirements, not tuning: the control path is 16-bit fixed
point and depends on signed wrapping, and float narrowing guarantees break if clang fuses `a*b+c`
into an FMA. Upstream exports them via a `ts::numeric_semantics` CMake target; SwiftPM restates them.
Because they go through `.unsafeFlags`, this package can only ever be consumed **by path**.

**Regenerate the manifest whenever the `nativets` submodule moves:**

```sh
swift Packages/TabulaSonoraKit/Scripts/embed-manifest.swift
shasum -a 256 Packages/TabulaSonoraKit/nativets/assets/manifest.json   # compare to the .cpp header
```

`Sources/TabulaSonoraBridge/manifest_json.generated.cpp` stands in for CMake's configure-time
`ts_embed_asset()`. A stale copy is **not a build error** — it is an offset map pointing at the wrong
tables.

**Nothing Roland-derived enters this repository.** The engine reads a user-supplied `SCCore.dll`
(27,347,456 bytes, SHA-256 `117e6aa1…bdb1`) as *data*, never as code. `.gitignore` blocks `*.dll` and
`*.wav`; keep it that way, and don't commit renders either.

The `nativets/` submodule is upstream and stays untouched — changes belong in
[NativeTS](https://github.com/TabulaSonora/NativeTS), not here.

## Layers

```
nativets/                     upstream C++20 engine (submodule, read-only)
  RomImage → NoteRenderer → ToneGenerator → SequencePlayer   (each borrows the one above)
Sources/TabulaSonoraBridge/   Objective-C++ façade
  TSSession.{hpp,cpp}         ts::apple::Session — the chain + everything doable to it
  TSPlayer.{hpp,cpp}          ts::apple::Player  — render thread, ring, locks, MIDI inbox
  TSEngine.mm / TSEngine.h    the ONLY public header; TSTypes.h is plain C, shared with the C++
Sources/TabulaSonoraKit/      Swift API the app imports
  Player.swift                @MainActor @Observable; the whole surface a view binds to
Tabula Sonora Player/         SwiftUI; Library.swift owns ROM-on-disk and recents
```

Engine and bridge are deliberately **one SwiftPM target**. Splitting them would make
`nativets/include` a `publicHeadersPath`, and SwiftPM would synthesise an umbrella modulemap over 47
C++20 headers. Keeping them private include paths means Swift only ever sees `TSEngine.h`.

## The threading contract

This is the load-bearing design and most bugs here will be violations of it.

- `ToneGenerator` is **single-threaded by contract**. `Session` is not thread-safe and does not need
  to be — `Player` gives it exactly one owning thread.
- A **render thread** pulls 128-frame blocks (4 ms at 32 kHz) from the session into a lock-free
  `FrameRing`. The `AVAudioSourceNode` callback calls `TSEngineRingRead` and *nothing else* — no
  allocation, no lock, no Objective-C dispatch, no engine code. A slow block eats the ring's lead
  instead of glitching the device; `latencyMilliseconds` (10–400, default 40) is that lead.
- **Control** (load, settings, seek, transport) takes `Player::lock_`, which the render thread also
  holds while rendering. Safe *because* the render thread is not the audio callback.
- **Live MIDI** goes through a separate inbox under its own mutex, swapped wholesale once per block,
  so a MIDI source never waits on a render.
- **Mute/solo** take no lock — `ChannelMask`'s flags are atomic for exactly that reason, and they
  live outside the generator so they survive a rebuild.
- Lock order when both are needed: `export_lock_` then `lock_`, never the reverse. Export borrows the
  27 MB `NoteRenderer` rather than copying it.
- UI never reads engine state directly. The render thread publishes a `SessionSnapshot`; Swift's
  `Player` polls a copy at 10 Hz (`refresh()`).
- **A stopped transport is not a silent instrument.** The loop separates `transport_idle` (should
  the *song* advance) from `live` (is there sound to make — a live message this block, or voices
  still sounding). When stopped but live it calls `Session::render_live`, which renders the
  generator without stepping the sequencer, and leaves `audible_` alone so the scrubber does not
  walk backwards. Collapsing these back into one flag silences the keyboard whenever no song is
  playing. Because of this, pausing must send All Sound Off (`Session::silence`) — the sequencer
  stops advancing, so a note it was holding would otherwise never reach its note-off.

`adoptWorkgroupFromAudioUnit:` must be called after *every* graph start or restart — a device has a
workgroup only once its hardware runs, and a different one after a restart. Without it an iPhone with
its screen off stops scheduling the render thread in time and you hear dropouts.

## Conventions worth knowing

- Everything measured in frames is at **32 kHz**. The graph connects at the engine's rate so
  CoreAudio does the conversion in the mixer; never teach the engine the device rate.
- A part is addressed as `port * 16 + channel`, 0–63 (`TS_MAX_PARTS`). `ports` is 1/2/4 → 16/32/64
  parts; the module itself has two.
- **A part's index is not the channel it hears.** Parts are matched by `rxChannel`, not indexed by
  it — GS can point several parts at one channel or detach one entirely. Label, ordering *and*
  listing all follow the receive channel: `Session::used_channels_` holds the channels the file
  sends on (a property of the file), and `capture` asks the engine which part hears each — the same
  walk `dispatch_channel` does. Use `displayChannel`, not `rxChannel`, for anything shown: the raw
  value is -1 on a cleared snapshot and 16 for a detached part.
- `isDrums` is *sounding drums now*, not "is channel 10" — GS reroutes over SysEx and XG does it from
  bank select. Same for `map`: under XG a part resolves against a map that is not the configured one.
- Under XG the bank pair swaps meaning: `bank` holds what GS would call the LSB, the MSB lands in
  the engine's `xg_bank_msb`, and `lookupBank` is what the melodic lookup actually gets (0x7D when
  the XG MSB is 64). `PartState.detail` names the resolved bank whenever it differs from `bank`.
- `extendedInterpolation` is the **one setting whose default is not the module** — a wider resampling
  kernel with the module's 4× pitch-increment ceiling lifted. Anything being compared against
  `SCCore.dll` needs it off; upstream's own gates render with it off.
- Changing any `EngineSettings` but `outputGain` rebuilds the `ToneGenerator` (part state replayed
  across it, sounding voices lost) but never the `NoteRenderer` — tables are read once per session.
- Underruns are surfaced all the way to the UI on purpose. Never hide them.
- The app reads far more than SMF (RIFF-MIDI, MIDS, MUS, XMI, GMF, HMI, Mobile XMF, LDS). Most have
  no declared UTType, so `Array<UTType>.midiFiles` matches by extension — extend it there.

### Adding an engine setting

`TSEngineSettings` in `TSTypes.h` → `Session::options()`/`rebuild()` → `EngineSettings` and its
`bridged` in `PlayerTypes.swift` → a `Preferences.Key` (one key per setting, never an encoded blob,
so a later addition reads back as its default) → `EngineControlsView`.

### Adding a snapshot field

`PartState`/`SessionSnapshot` in `TSSession.hpp` → `Session::capture` → `TSPartState`/`TSSnapshot` in
`TSEngine.h` and `.mm` → `PlayerTypes.swift` → `Player.refresh()`.
