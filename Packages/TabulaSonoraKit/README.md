# TabulaSonoraKit

The [NativeTS](https://github.com/TabulaSonora/NativeTS) engine, built for Apple platforms and
wrapped in a Swift API.

## Layout

| | |
|---|---|
| `nativets/` | Git submodule. The engine, untouched. |
| `Sources/ThirdParty/nlohmann/json.hpp` | Vendored single header, v3.11.3 (MIT) — the engine's only hard dependency, used by three of its files. Matches the version its own web build fetches. |
| `Sources/TabulaSonoraBridge/` | Objective-C++ façade. The only public header is `TSEngine.h`. |
| `Sources/TabulaSonoraKit/` | The Swift API the app imports. |
| `Scripts/embed-manifest.swift` | Regenerates `manifest_json.generated.cpp`. |

After cloning:

```sh
git submodule update --init
```

## Two things that are easy to get wrong

**The numeric semantics are load-bearing.** `Package.swift` compiles the engine with
`-fwrapv -ffp-contract=off`. These are not optimisation settings: the engine's control path is
16-bit fixed point and depends on signed wrapping, and its float narrowing guarantees break if
clang fuses `a*b+c` into an FMA. Upstream states this outright and supplies the flags through an
exported `ts::numeric_semantics` CMake target; this package restates them. Never add `-ffast-math`.

Because they go through `.unsafeFlags`, **this package can only be consumed by path.** SwiftPM
rejects `unsafeFlags` in a package depended on by version. That is fine — it lives inside the app
that uses it — but it cannot be tagged and published without first finding another way to guarantee
the above.

**The embedded manifest is generated.** The engine expects `ts::assets::manifest_json()`, which
upstream's CMake produces at configure time from `assets/manifest.json` via
`cmake/EmbedAsset.cmake`. SwiftPM has no configure step, so the equivalent translation unit is
checked in at `Sources/TabulaSonoraBridge/manifest_json.generated.cpp`. **When the submodule moves,
regenerate it:**

```sh
swift Packages/TabulaSonoraKit/Scripts/embed-manifest.swift
```

The generated file records the input's SHA-256 in its header. Compare against:

```sh
shasum -a 256 Packages/TabulaSonoraKit/nativets/assets/manifest.json
```

A stale manifest is not a build error — it is an offset map pointing at the wrong tables.

## Verifying

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
```

`ROMIdentityTests` parses the embedded manifest and checks it reports the pinned `SCCore.dll` build.
It is the same check `nativets/tests/package/main.cpp` makes as a foreign consumer of the library:
if it passes, the engine sources compiled, linked, and found their compiled-in asset. It needs no
ROM, so it runs anywhere.

## The ROM

The engine is inert without a `SCCore.dll` the user supplies from a licensed SOUND Canvas VA 1.1.6
install (27,347,456 bytes, SHA-256 `117e6aa1…bdb1`). It is read as *data* — never loaded as code.
Nothing Roland-derived is committed here, and nothing derived from it should be.
