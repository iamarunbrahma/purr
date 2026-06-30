import Foundation
import WhisperKit
import os.log

// Wraps WhisperKit. Multilingual fallback for the long tail of languages
// (Asian, Arabic, etc.) that the English-only Parakeet v2 doesn't cover.
//
// Streaming is intentionally not implemented: WhisperKit's chunked
// streaming runs on whole-30s windows and produces awkward partial
// revisions. makeStreamingSession() throws so callers fall back to batch.
@MainActor
final class WhisperEngine: TranscriptionEngine {
    nonisolated let supportsStreaming: Bool = false
    nonisolated let modelIdentifier: String

    private var pipe: WhisperKit?
    private var loadedModel: String?
    private let log = Logger(subsystem: "com.arunbrahma.purr", category: "whisper")

    init(modelName: String) {
        self.modelIdentifier = modelName
    }

    // Pre-load the model so the first dictation doesn't pay the disk-load
    // cost. Safe to call multiple times - same-model warmups are no-ops.
    // If the weights aren't on disk, this fails-soft (logs and returns)
    // rather than triggering a background download - the Settings UI is
    // the only path that pulls models, so it can show progress and surface
    // failures inline.
    func warmup() async {
        if loadedModel == modelIdentifier, pipe != nil { return }
        do {
            let folder = try await ModelManager.localFolder(for: modelIdentifier)
            let cfg = WhisperKitConfig(
                modelFolder: folder.path,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )
            let pipe = try await WhisperKit(cfg)
            self.pipe = pipe
            self.loadedModel = modelIdentifier
            log.info("Whisper warmed up - model \(self.modelIdentifier, privacy: .public)")
        } catch {
            log.error(
                "Warmup failed for \(self.modelIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func transcribe(samples: [Float]) async throws -> String {
        if loadedModel != modelIdentifier { await warmup() }
        guard let pipe = pipe else { throw EngineError.notLoaded }

        // Translate (X→English) only when the user opted in AND the loaded
        // model can actually do it. Turbo and English-only builds silently
        // ignore the translate task and return the source language, so we
        // never request it from them.
        let translate =
            SettingsStore.shared.translateToEnglish
            && ModelManager.supportsTranslation(modelIdentifier)
        // When translating, a pinned source language skips Whisper's
        // audio-based detection, which is unreliable on short clips. Empty
        // string means auto-detect; plain transcription always auto-detects.
        let sourceLanguage = SettingsStore.shared.translationSourceLanguage
        let language: String? = (translate && !sourceLanguage.isEmpty) ? sourceLanguage : nil
        let options = DecodingOptions(
            verbose: false,
            task: translate ? .translate : .transcribe,
            language: language,
            temperature: 0.0,
            sampleLength: 224,
            usePrefillPrompt: true,
            withoutTimestamps: true,
            wordTimestamps: false
        )
        let started = Date()
        let results: [TranscriptionResult] = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        let elapsed = Date().timeIntervalSince(started)
        let raw = results.map(\.text).joined(separator: " ")
        let cleaned = TranscriptCleaner.clean(raw)
        log.info(
            "Transcribed \(samples.count, privacy: .public) samples in \(String(format: "%.2f", elapsed), privacy: .public)s (task=\(translate ? "translate" : "transcribe", privacy: .public), lang=\(language ?? "auto", privacy: .public))"
        )
        return cleaned
    }

    func makeStreamingSession() async throws -> any StreamingSession {
        throw EngineError.streamingNotSupported(engineName: "Whisper")
    }
}

enum EngineError: LocalizedError {
    case notLoaded
    case streamingNotSupported(engineName: String)
    case modelDirectoryMissing
    case transcriptionTimedOut

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "Speech model is not loaded. Open Settings → Engine and download one."
        case .streamingNotSupported(let name):
            return
                "\(name) does not support real-time streaming. Switch the engine, or turn off Smart typing."
        case .modelDirectoryMissing:
            return "Model files are missing on disk. Open Settings → Engine to download."
        case .transcriptionTimedOut:
            return
                "Transcription took too long and was stopped. If this keeps happening, switch to a Whisper model in Settings → Engine, or try a shorter recording."
        }
    }
}

// Both engines emit the same junk that Whisper learned from YouTube
// captioning: "[Music]", "(silence)", "<|endoftext|>", and so on. Cleaning
// them is identical work - share the implementation so post-process
// results match exactly across engines.
enum TranscriptCleaner {
    static func clean(_ text: String) -> String {
        var result = text
        let patterns = [
            #"\[[^\]]+\]"#,
            #"\([^)]*?(?:music|silence|noise|laugh|applause|inaudible)[^)]*?\)"#,
            #"<\|[^|]+\|>"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        result = result.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
