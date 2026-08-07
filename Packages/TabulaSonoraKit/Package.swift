// swift-tools-version: 6.0

import PackageDescription

// The NativeTS engine, compiled from source rather than linked as a prebuilt binary.
//
// The engine's own build is CMake + vcpkg, which would mean building and packaging five platform
// slices into an XCFramework before Xcode could see any of it. Compiling the 44 sources here
// instead costs one vendored header (nlohmann/json, the only hard dependency) and one generated
// translation unit (see Scripts/embed-manifest.swift), and in exchange every Apple platform builds
// incrementally from the same tree.
//
// NOTE: `unsafeFlags` below means this package can only ever be consumed by path. That is fine --
// it lives inside the app that uses it -- but it cannot be published and depended on by version
// without first finding another way to guarantee the numeric semantics.
let package = Package(
    name: "TabulaSonoraKit",
    platforms: [.macOS(.v14), .iOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "TabulaSonoraKit", targets: ["TabulaSonoraKit"])
    ],
    targets: [
        // One target spanning both the engine sources and our bridge, deliberately.
        //
        // Splitting the engine into its own target would make `nativets/include` a
        // `publicHeadersPath`, and SwiftPM would synthesise an umbrella modulemap over 47 C++20
        // headers that Swift may then try to build as a Clang module without C++ interop. Keeping
        // them private include paths means the only thing Swift ever sees is TSEngine.h.
        //
        // It also keeps manifest_json.generated.cpp in the same translation-unit set as the
        // `table_manifest.cpp` that references it, rather than making it a link-order question.
        .target(
            name: "TabulaSonoraBridge",
            path: ".",
            exclude: [
                "Scripts",
                "Sources/TabulaSonoraKit",
                "Tests",
                "README.md",
                "nativets/src/CMakeLists.txt",
            ],
            sources: [
                "nativets/src",
                "Sources/TabulaSonoraBridge",
            ],
            publicHeadersPath: "Sources/TabulaSonoraBridge/include",
            cxxSettings: [
                .headerSearchPath("nativets/include"),
                .headerSearchPath("nativets/src"),
                .headerSearchPath("Sources/ThirdParty"),

                // The XMF converter's deflate path. zlib ships in the Apple SDKs, so this is free.
                .define("TS_HAVE_ZLIB"),

                // Correctness requirements, not tuning -- the engine's control path is 16-bit fixed
                // point and depends on wrapping, and its float narrowing guarantees break if clang
                // fuses a*b+c into an FMA. CMake supplies these via ts::numeric_semantics; this is
                // that target, restated. Never add -ffast-math.
                .unsafeFlags(["-fwrapv", "-ffp-contract=off"]),

                // Optimised even in Debug. Unoptimised, the synth renders barely faster than
                // realtime -- measured at about 1.4x -- which a 150 ms ring cannot absorb, so a
                // debug build would stutter for reasons that have nothing to do with the code under
                // test. This is a vendored dependency, not the app being debugged.
                //
                // It does not weaken the flags above: -O2 and -ffp-contract=off are independent,
                // and contraction stays off because it is stated after the optimisation level.
                .unsafeFlags(["-O2"], .when(configuration: .debug)),
            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .target(
            name: "TabulaSonoraKit",
            dependencies: ["TabulaSonoraBridge"],
            path: "Sources/TabulaSonoraKit"
        ),
        .testTarget(
            name: "TabulaSonoraKitTests",
            dependencies: ["TabulaSonoraKit"],
            path: "Tests/TabulaSonoraKitTests"
        ),
    ],
    cxxLanguageStandard: .cxx20
)
