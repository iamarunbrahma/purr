// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Purr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Purr", targets: ["Purr"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // FluidAudio - Parakeet TDT v3 batch (multilingual, 10× faster than
        // Whisper Large V3 on Apple Silicon) plus Parakeet EOU streaming
        // (real-time chunked ASR with end-of-utterance detection).
        //
        // Pinned to the 0.15.5 minor line (not `from:`): FluidAudio 0.15.5
        // removed the `DownloadUtils` namespace and promoted `ProgressHandler`
        // to a top-level typealias, breaking `ParakeetEngine.swift`'s
        // `DownloadUtils.ProgressHandler` reference on any resolve pulling
        // 0.15.5+. SwiftPM's `from:` doesn't treat 0.x minor bumps as
        // breaking the way SemVer does, so an unbounded `from: "0.8.0"` lets
        // a routine resolve silently jump onto a breaking release - bound to
        // the minor line so the next break requires a deliberate bump here.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.15.5")),
    ],
    targets: [
        // llama.cpp Apple XCFramework - powers Gemma 3 4B meeting summaries
        // on macOS 14-25 where Apple Foundation Models isn't available.
        // Pinned to a specific upstream tag so the SHA256 is stable; bump by
        // hand when picking up a new release (the framework ships ~200 MB
        // zipped because it bundles every Apple platform slice, but only the
        // macos-arm64 slice ends up in the final .app, ~30 MB).
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
    ]
)
