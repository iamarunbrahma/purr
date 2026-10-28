import Foundation
import WhisperKit
import os.log

// Owns model files on disk. WhisperKit can download to its own cache, but we route
// everything through ~/Library/Application Support/Purr/models so users can find and
// delete models without spelunking ~/Library/Caches, and so the location survives
// `defaults delete` and Xcode-cache cleaning.
enum ModelManager {
    private static let log = Logger(subsystem: "com.arunbrahma.hello", category: "models")

    // Whisper Large V3 Turbo: 4 decoder layers (vs 32 in Large V3), ~6× decode
    // speed. The `_632MB` suffix selects argmax's quantised CoreML build, which fits
    // in memory and runs on the ANE on every supported Mac; the un-suffixed variant
    // is full-precision and ~1.5 GB, so we deliberately don't surface it.
    static let defaultModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let modelRepo = "argmaxinc/whisperkit-coreml"

    // Curated list shown in Settings: WhisperKit's repo has dozens of variants, and
    // these are the ones worth picking between for dictation.
    //
    // sizeMB is the total downloaded from argmaxinc/whisperkit-coreml for each
    // variant (every file in the variant directory, including .mlmodelc weights and
    // any .mlpackage duplicates). Keep in sync with the repo on Hugging Face.
    //
    // Notes lead with "Multilingual." or "English only." - except Turbo, where that
    // prefix misleads users into assuming translation works, so its note emphasises
    // quality at real-time speed instead.
    static let curatedModels: [ModelChoice] = [
        ModelChoice(
            id: "openai_whisper-tiny.en",
            label: "Tiny EN - lowest latency",
            sizeMB: 146,
            note: "English only. Smallest and fastest; lowest accuracy. For short commands.",
            supportsTranslation: false
        ),
        ModelChoice(
            id: "openai_whisper-base.en",
            label: "Base EN - low latency",
            sizeMB: 140,
            note: "English only. Small, low latency; better accuracy than Tiny.",
            supportsTranslation: false
        ),
        ModelChoice(
            id: "openai_whisper-base",
            label: "Base",
            sizeMB: 140,
            note: "Multilingual. Smallest, fastest multilingual; low accuracy.",
            supportsTranslation: true
        ),
        ModelChoice(
            id: "openai_whisper-small",
            label: "Small",
            sizeMB: 464,
            note: "Multilingual. Balanced accuracy and latency for everyday use.",
            supportsTranslation: true
        ),
        ModelChoice(
            id: "openai_whisper-large-v3_947MB",
            label: "Large V3",
            sizeMB: 948,
            note: "Multilingual. Highest accuracy with translation; slower than Turbo.",
            supportsTranslation: true
        ),
        ModelChoice(
            id: "openai_whisper-large-v3-v20240930_turbo_632MB",
            label: "Large V3 Turbo (recommended)",
            sizeMB: 616,
            note: "Best quality at real-time speed on Apple Silicon.",
            supportsTranslation: false
        ),
    ]

    // Unknown / uncurated names default to false so the engine never asks a model
    // to translate when it can't.
    static func supportsTranslation(_ modelName: String) -> Bool {
        curatedModels.first { $0.id == modelName }?.supportsTranslation ?? false
    }

    static var modelsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0]
        let dir = support.appendingPathComponent("Purr/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func localFolder(for modelName: String) async throws -> URL {
        let local = modelsDirectory.appendingPathComponent(modelName, isDirectory: true)
        if FileManager.default.fileExists(atPath: local.path),
            let contents = try? FileManager.default.contentsOfDirectory(atPath: local.path),
            !contents.isEmpty
        {
            return local
        }
        // Files missing, and we deliberately don't auto-pull: the warmup path would
        // race the Settings UI's explicit download (both converge on `download` and
        // clobber each other on `copyItem`), and a silent ~450 MB fetch with no
        // progress UI is worse than the "install from Settings → Engine" prompt
        // that modelDirectoryMissing surfaces on the next transcribe.
        throw EngineError.modelDirectoryMissing
    }

    static func isInstalled(_ modelName: String) -> Bool {
        let local = modelsDirectory.appendingPathComponent(modelName, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: local.path) else {
            return false
        }
        return !contents.isEmpty
    }

    @discardableResult
    static func download(modelName: String, progress: @escaping (Double) -> Void) async throws -> URL {
        log.info("Downloading model \(modelName, privacy: .public) from \(modelRepo, privacy: .public)")
        // WhisperKit caches under its own root; copy the result into our Application
        // Support tree so it lives where the rest of the app expects it.
        let cached = try await WhisperKit.download(
            variant: modelName,
            from: modelRepo
        ) { p in
            progress(p.fractionCompleted)
        }
        let dest = modelsDirectory.appendingPathComponent(modelName, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: cached, to: dest)
        log.info("Model \(modelName, privacy: .public) installed at \(dest.path, privacy: .public)")
        return dest
    }

    static func delete(_ modelName: String) throws {
        let local = modelsDirectory.appendingPathComponent(modelName, isDirectory: true)
        if FileManager.default.fileExists(atPath: local.path) {
            try FileManager.default.removeItem(at: local)
        }
    }

    // Removes every downloaded model in one sweep: Whisper checkpoints, the Gemma
    // GGUF, and the FluidAudio CoreML bundles. Meeting transcripts live in a sibling
    // folder and are deliberately left alone. Callers MUST release any in-memory
    // model sessions first so a deleted file isn't left mmap'd behind a live handle.
    static func deleteAllModels() throws {
        let dir = modelsDirectory
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}

struct ModelChoice: Identifiable, Hashable {
    let id: String
    let label: String
    let sizeMB: Int
    let note: String
    // True only for checkpoints that can run Whisper's X->English translate task, so
    // only Base, Small, and Large V3: English-only (.en) builds can't read
    // non-English at all, and Turbo is multilingual for transcription but was
    // fine-tuned without translation data. Gates the Translate toggle in Settings
    // and WhisperEngine's runtime task choice.
    let supportsTranslation: Bool
}
