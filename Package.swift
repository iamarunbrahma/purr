// swift-tools-version:6.2
// 6.2 for dependency traits (see FluidAudio below); the language mode stays
// Swift 5, set at the bottom.
import PackageDescription

let package = Package(
    name: "Purr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Purr", targets: ["Purr"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // FluidAudio - Parakeet TDT v2 (English) and v3 (other meeting
        // languages), Parakeet EOU streaming for Smart Typing, and the meeting
        // speaker diarizer.
        //
        // Pinned exactly: FluidAudio has broken this build from inside a
        // version range before. 0.15.5 removed the `DownloadUtils` namespace,
        // and tag v0.15.8 is the "v0.16.0" release. Bump by hand after running
        // the transcripts through both versions.
        //
        // `traits: []` leaves out the NeMo text normalizer, a ~9 MB Rust
        // library FluidAudio links by default for its TTS and inverse text
        // normalization, neither of which Purr uses.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        // llama.cpp Apple XCFramework - runs Gemma 4 E2B for meeting summaries
        // and Voice Edit. Pinned to a specific upstream tag so the SHA256 is
        // stable; bump by hand when picking up a new release (the framework
        // ships ~200 MB zipped because it bundles every Apple platform slice,
        // but only the macos-arm64 slice ends up in the final .app, ~30 MB).
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b9106/llama-b9106-xcframework.zip",
            checksum: "a6f2aa6b00d2403385a56ac6a0746ffecaf8edc8852c4dc7c821d6acc55945be"
        ),
        // SpeexDSP echo canceller, vendored from xiph/speexdsp (BSD-3) and
        // compiled from source - see Sources/CEcho/SPEEXDSP-COPYING. Powers
        // acoustic echo cancellation of system audio out of the meeting mic.
        // HAVE_CONFIG_H selects the hand-written Sources/CEcho/config.h;
        // -w silences the vendored library's own warnings.
        .target(
            name: "CEcho",
            path: "Sources/CEcho",
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .unsafeFlags(["-w"]),
            ]
        ),
        .executableTarget(
            name: "Purr",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                "llama",
                "CEcho",
            ],
            path: "Sources/Purr",
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ]
        ),
    ],
    // Tools 6.x would otherwise switch to the Swift 6 language mode and its
    // strict concurrency checking, which Purr hasn't been migrated to.
    swiftLanguageModes: [.v5]
)
