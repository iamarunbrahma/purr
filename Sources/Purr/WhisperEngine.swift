import Foundation
import WhisperKit
import os.log

// Wraps WhisperKit. Multilingual fallback for the long tail of languages
// (Asian, Arabic, etc.) that the English-only Parakeet v2 doesn't cover.
//
// Streaming is intentionally not implemented: WhisperKit's chunked streaming
// runs on whole-30s windows and produces awkward partial revisions, so
// makeStreamingSession() throws and callers fall back to batch.
@MainActor
final class WhisperEngine: TranscriptionEngine {
    nonisolated let supportsStreaming: Bool = false
    nonisolated let modelIdentifier: String

    private var pipe: WhisperKit?
    private var loadedModel: String?
    private var loadTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.arunbrahma.purr", category: "whisper")

    init(modelName: String) {
        self.modelIdentifier = modelName
    }

    var isLoaded: Bool { loadedModel == modelIdentifier && pipe != nil }
    // Settings is the only path that downloads Whisper models.
    var needsDownload: Bool { false }
    var isStreamingLoaded: Bool { false }

    // Pre-loads the model so the first dictation doesn't pay the disk-load cost.
    // Same-model warmups are no-ops, and one already loading is joined rather
    // than started twice. Missing weights fail soft rather than downloading:
    // Settings is the only path that pulls models, so it can show progress and
    // surface failures inline.
    func warmup() async {
        if isLoaded { return }
        if let inFlight = loadTask {
            await inFlight.value
            return
        }
        let task = Task { [weak self] () -> Void in
            await self?.loadPipe()
        }
        loadTask = task
        defer { if loadTask == task { loadTask = nil } }
        await task.value
    }

    // A Large model's first load can spend minutes compiling for the Neural
    // Engine, longer than modelLoadTimeout allows.
    private var loadLimit: Duration {
        modelIdentifier.contains("large") ? .seconds(300) : modelLoadTimeout
    }

    func load() async throws {
        if isLoaded { return }
        log.notice("Waiting for Whisper \(self.modelIdentifier, privacy: .public) to load.")
        do {
            try await withTimeout(loadLimit) { await self.warmup() }
        } catch is TimedOutError {
            log.error(
                "Gave up waiting for Whisper \(self.modelIdentifier, privacy: .public) to load. It keeps loading in the background."
            )
            throw EngineError.modelLoadTimedOut
        }
        guard isLoaded else { throw EngineError.notLoaded }
    }

    private func loadPipe() async {
        let started = Date()
        log.notice("Whisper \(self.modelIdentifier, privacy: .public) loading.")
        do {
            let folder = try await ModelManager.localFolder(for: modelIdentifier)
            let cfg = WhisperKitConfig(
                modelFolder: folder.path,
                // WhisperKit fetches the tokenizer on first load, by default into
                // ~/Documents/huggingface. In the model's own folder it goes with
                // the model when that's deleted or Purr is uninstalled.
                tokenizerFolder: folder,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )
            let pipe = try await WhisperKit(cfg)
            self.pipe = pipe
            self.loadedModel = modelIdentifier
            log.notice(
                "Whisper \(self.modelIdentifier, privacy: .public) loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public)s."
            )
        } catch {
            log.error(
                "Warmup failed for \(self.modelIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func transcribe(samples: [Float]) async throws -> String {
        try await load()
        guard let pipe = pipe else { throw EngineError.notLoaded }

        // Turbo and English-only builds silently ignore the translate task and
        // return the source language, so never request it from them.
        let translate =
            SettingsStore.shared.translateToEnglish
            && ModelManager.supportsTranslation(modelIdentifier)
        // A pinned source language skips Whisper's audio-based detection, which
        // is unreliable on short clips. Empty string means auto-detect, which
        // has to be asked for: with the prefill prompt on and no language,
        // WhisperKit forces <|en|> and turns other languages into English.
        let sourceLanguage = SettingsStore.shared.translationSourceLanguage
        let language: String? = (translate && !sourceLanguage.isEmpty) ? sourceLanguage : nil
        let options = DecodingOptions(
            verbose: false,
            task: translate ? .translate : .transcribe,
            language: language,
            temperature: 0.0,
            sampleLength: 224,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            withoutTimestamps: true,
            wordTimestamps: false
        )
        let started = Date()
        let audioSeconds = Double(samples.count) / 16_000
        let budget: Duration = .seconds(45) + .seconds(audioSeconds * 5)
        do {
            let results: [TranscriptionResult] = try await withTimeout(budget) {
                try await pipe.transcribe(audioArray: samples, decodeOptions: options)
            }
            let elapsed = Date().timeIntervalSince(started)
            let raw = results.map(\.text).joined(separator: " ")
            let cleaned = TranscriptCleaner.clean(raw)
            log.info(
                "Transcribed \(samples.count, privacy: .public) samples in \(String(format: "%.2f", elapsed), privacy: .public)s (task=\(translate ? "translate" : "transcribe", privacy: .public), lang=\(language ?? "auto", privacy: .public))"
            )
            return cleaned
        } catch is TimedOutError {
            let waited = Date().timeIntervalSince(started)
            log.error(
                "Whisper transcription timed out after \(String(format: "%.1f", waited), privacy: .public)s for \(samples.count, privacy: .public) samples (\(String(format: "%.1f", audioSeconds), privacy: .public)s audio) - inference did not return. Aborting so the HUD can recover."
            )
            throw EngineError.transcriptionTimedOut
        }
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
    case modelLoadTimedOut
    case meetingModelLoadTimedOut(downloading: Bool)

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
        case .modelLoadTimedOut:
            return "The speech model is still loading. Try again in a minute."
        case .meetingModelLoadTimedOut(let downloading):
            return downloading
                ? "The speech model is still downloading, so this meeting wasn't transcribed."
                : "The speech model took too long to load, so this meeting wasn't transcribed."
        }
    }
}

// Both engines emit the same junk Whisper learned from YouTube captioning:
// "[Music]", "(silence)", "<|endoftext|>", and so on. Shared so post-process
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
