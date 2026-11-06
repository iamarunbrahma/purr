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
        // FluidAudio - Parakeet TDT v2 (English) and Parakeet Ultra (other
        // meeting languages), Parakeet EOU streaming for Smart Typing, and the
        // meeting speaker diarizer.
        //
        // Pinned exactly: FluidAudio has broken this build from inside a
        // version range before. 0.15.5 removed the `DownloadUtils` namespace,
        // and tag v0.15.8 is the "v0.16.0" release. Bump by hand after running
        // the transcripts through both versions.
        //
        // The Diarizer trait alone keeps the speaker diarizer and leaves out
        // TTS and the NeMo text normalizer, a ~9 MB Rust library, neither of
        // which Purr uses.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0", traits: ["Diarizer"]),
        // Sparkle - checks for updates, shows each release's notes, and
        // installs and relaunches. Pinned exactly so the framework Makefile
        // signs is the one that was tested.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // llama.cpp Apple XCFramework - runs Gemma 4 E2B for meeting summaries
        // and Voice Edit. Pinned to a specific upstream tag so the SHA256 is
        // stable; bump by hand when picking up a new release (the framework
        // ships ~67 MB zipped with its iOS and macOS slices, but only the
        // macos-arm64 slice ends up in the final .app).
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b12003/llama-b12003-xcframework.zip",
            checksum: "59afc160e12658d1061f8e1a97f686b4a985b6b6ae28583713c71c5895493e64"
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
                .product(name: "Sparkle", package: "Sparkle"),
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
