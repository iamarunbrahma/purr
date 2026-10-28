import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import os.log

// Parakeet via FluidAudio. Three models behind this engine:
//
// * **Batch / Meeting (English) / Voice-edit** → `AsrManager` with Parakeet
//   TDT v2 (English-only, word-level timings for the meeting diarizer).
//   Used for hold-to-talk dictation and offline transcription.
// * **Meeting (non-English)** → a second `AsrManager` with Parakeet TDT v3
//   (multilingual). Loaded only when a non-English meeting language is
//   picked, so English users never pay for the extra download - dictation
//   and voice-edit always stay on v2.
// * **Smart typing (live)** → `StreamingEouAsrManager`, Parakeet EOU at
//   320ms chunks. Partial-transcript callback fires every chunk so the
//   consumer can diff + type live; a separate EOU callback marks sustained
//   silence, where PostProcessor runs on the completed utterance.
@MainActor
final class ParakeetEngine: TranscriptionEngine {
    nonisolated let supportsStreaming: Bool = true

    private var batchManager: AsrManager?
    // Coalesces concurrent callers (an automatic warmup and a manual Settings
    // download can fire at once) onto one in-flight download.
    private var batchLoadTask: Task<Void, Error>?
    // 0..1 while downloading, nil when done, to whichever @Published the
    // coordinator wires up. `batchDownloadActive` gates late callbacks that
    // could land after the download finished.
    var onBatchProgress: ((Double?) -> Void)?
    private var batchDownloadActive = false
    private var meetingBatchManager: AsrManager?
    private var meetingBatchLoadTask: Task<Void, Error>?
    var onMeetingBatchProgress: ((Double?) -> Void)?
    private var meetingBatchDownloadActive = false
    private var streamingManager: StreamingEouAsrManager?
    private var streamingWarmupTask: Task<Void, Never>?
    var onEOUProgress: ((Double?) -> Void)?
    private var eouDownloadActive = false
    private let log = Logger(subsystem: "com.arunbrahma.hello", category: "parakeet")

    // 320ms: FluidAudio's benchmarks put it at 4.88% WER vs 8.23% at 160ms,
    // and latency is still well inside the threshold where typing feels live.
    private static let streamingChunk: StreamingChunkSize = .ms320

    func warmup() async {
        do {
            try await downloadAndLoadBatchManager()
        } catch {
            log.error("Parakeet warmup failed: \(error.localizedDescription, privacy: .public)")
        }

        // Loads the EOU model only if Smart Typing is on and it's already on
        // disk - warmup never downloads it, only the Settings button does.
        if SettingsStore.shared.smartTyping, Self.eouIsInstalled(), streamingManager == nil,
            streamingWarmupTask == nil
        {
            streamingWarmupTask = Task { [weak self] in
                await self?.loadStreamingManager()
            }
        }
    }

    // Throwing variant of warmup's batch load: propagates errors and reports
    // progress, for the Settings download button. Coalesces with any
    // concurrent warmup so the weights are only ever pulled once.
    func downloadAndLoadBatchManager() async throws {
        if batchManager != nil { return }
        if let inFlight = batchLoadTask {
            try await inFlight.value
            return
        }
        let task = Task { [weak self] () throws -> Void in
            try await self?.loadBatchManager()
        }
        batchLoadTask = task
        defer { if batchLoadTask == task { batchLoadTask = nil } }
        try await task.value
    }

    // checkCancellation guards the assignment so a delete that cancels the
    // task mid-flight can't resurrect the manager from removed files.
    private func loadBatchManager() async throws {
        // Only surface progress when weights will actually be fetched - a
        // load-from-disk on warmup shouldn't flash "downloading…".
        let willDownload = !Self.batchIsInstalled()
        if willDownload {
            batchDownloadActive = true
            onBatchProgress?(0)
        }
        defer {
            if willDownload {
                batchDownloadActive = false
                onBatchProgress?(nil)
            }
        }
        let progressHandler: ProgressHandler? = { [weak self] progress in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                guard let self, self.batchDownloadActive else { return }
                self.onBatchProgress?(fraction)
            }
        }
        let models = try await AsrModels.downloadAndLoad(
            to: Self.batchModelDirectory, version: .v2, progressHandler: progressHandler)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        try Task.checkCancellation()
        batchManager = manager
        log.info("Parakeet TDT v2 downloaded and warmed up.")
    }

    // v3 counterpart to downloadAndLoadBatchManager() - same coalescing-task
    // shape, so a manual Settings download and a meeting hitting a
    // non-English language don't race two pulls into the same folder.
    func downloadAndLoadMeetingManager() async throws {
        if meetingBatchManager != nil { return }
        if let inFlight = meetingBatchLoadTask {
            try await inFlight.value
            return
        }
        let task = Task { [weak self] () throws -> Void in
            try await self?.loadMeetingManager()
        }
        meetingBatchLoadTask = task
        defer { if meetingBatchLoadTask == task { meetingBatchLoadTask = nil } }
        try await task.value
    }

    private func loadMeetingManager() async throws {
        let willDownload = !Self.meetingModelIsInstalled()
        if willDownload {
            meetingBatchDownloadActive = true
            onMeetingBatchProgress?(0)
        }
        defer {
            if willDownload {
                meetingBatchDownloadActive = false
                onMeetingBatchProgress?(nil)
            }
        }
        let progressHandler: ProgressHandler? = { [weak self] progress in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                guard let self, self.meetingBatchDownloadActive else { return }
                self.onMeetingBatchProgress?(fraction)
            }
        }
        let models = try await AsrModels.downloadAndLoad(
            to: Self.meetingModelDirectory, version: .v3, progressHandler: progressHandler)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        try Task.checkCancellation()
        meetingBatchManager = manager
        log.info("Parakeet TDT v3 (meeting, multilingual) downloaded and warmed up.")
    }

    func unloadMeetingManager() {
        meetingBatchLoadTask?.cancel()
        meetingBatchLoadTask = nil
        meetingBatchManager = nil
        log.info("Parakeet TDT v3 (meeting) unloaded.")
    }

    // Separate on-disk folder from batchModelDirectory - v2 and v3 are
    // different weights, so they can't share a directory the way EOU's chunk
    // variants do.
    static var meetingModelDirectory: URL {
        ModelManager.modelsDirectory.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    static func meetingModelIsInstalled() -> Bool {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                atPath: meetingModelDirectory.path)
        else { return false }
        return !contents.isEmpty
    }

    static func meetingModelDelete() throws {
        let url = meetingModelDirectory
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func loadStreamingManager() async {
        do {
            try await downloadAndLoadStreamingManager()
        } catch {
            log.error(
                "Parakeet EOU warmup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // Propagates download errors (network down, HF outage) instead of
    // swallowing them, for the Smart Typing card's Download button.
    func downloadAndLoadStreamingManager() async throws {
        guard streamingManager == nil else { return }
        let willDownload = !Self.eouIsInstalled()
        if willDownload {
            eouDownloadActive = true
            onEOUProgress?(0)
        }
        defer {
            if willDownload {
                eouDownloadActive = false
                onEOUProgress?(nil)
            }
        }
        let manager = StreamingEouAsrManager(
            configuration: MLModelConfiguration(),
            chunkSize: Self.streamingChunk,
            eouDebounceMs: 1280
        )
        let progressHandler: ProgressHandler? = { [weak self] progress in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                guard let self, self.eouDownloadActive else { return }
                self.onEOUProgress?(fraction)
            }
        }
        try await manager.loadModels(to: ModelManager.modelsDirectory, progressHandler: progressHandler)
        streamingManager = manager
        log.info(
            "Parakeet EOU streaming downloaded and warmed up (\(Self.streamingChunk.durationMs, privacy: .public) ms chunks)."
        )
    }

    func unloadStreamingManager() {
        streamingWarmupTask?.cancel()
        streamingWarmupTask = nil
        streamingManager = nil
        log.info("Parakeet EOU streaming unloaded.")
    }

    // MUST run before ModelManager.deleteAllModels - drops the in-memory
    // graphs so an on-disk delete doesn't leave a stale mmap.
    func unloadBatchManager() {
        batchLoadTask?.cancel()
        batchLoadTask = nil
        batchManager = nil
        log.info("Parakeet TDT batch unloaded.")
    }

    // Under Purr's own models folder, not FluidAudio's default, so every
    // model sits in one place that uninstalling removes.
    static var batchModelDirectory: URL {
        ModelManager.modelsDirectory.appendingPathComponent("parakeet-tdt-0.6b-v2", isDirectory: true)
    }

    static func batchIsInstalled() -> Bool {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(atPath: batchModelDirectory.path)
        else { return false }
        return !contents.isEmpty
    }

    static func batchDelete() throws {
        let url = batchModelDirectory
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // FluidAudio caches the EOU streaming graphs (160 / 320 / 1280 ms
    // variants under their own subfolders) inside this directory.
    // Deleting the parent reclaims whatever variants were fetched.
    static var eouModelDirectory: URL {
        ModelManager.modelsDirectory.appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
    }

    static func eouIsInstalled() -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: eouModelDirectory.path)
        else { return false }
        return !contents.isEmpty
    }

    static func eouDelete() throws {
        let url = eouModelDirectory
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func transcribe(samples: [Float]) async throws -> String {
        let detailed = try await transcribeDetailed(samples: samples)
        return TranscriptCleaner.clean(detailed.text)
    }

    // Returns token timings (dropped by transcribe()) for diarization merge.
    // Runs v2 (highest English recall; non-English dictation uses Whisper
    // instead). `language: .english` is a no-op on v2 - it only drives v3's
    // token filter - but keeps the call correct if v2 is ever swapped for v3.
    func transcribeDetailed(samples: [Float]) async throws -> ASRResult {
        if batchManager == nil { await warmup() }
        guard let manager = batchManager else { throw EngineError.notLoaded }
        return try await runTranscribe(
            on: manager, samples: samples, language: .english, modelLabel: "Parakeet")
    }

    // Meeting-only multilingual counterpart to transcribeDetailed(), backed by
    // the v3 manager. `language` drives v3's script-aware token filter
    // (reduces wrong-script leakage, e.g. Cyrillic tokens mid-Polish
    // transcript) - pass the meeting's configured language, or nil to let
    // the decoder run unfiltered.
    func transcribeMeeting(samples: [Float], language: Language?) async throws -> ASRResult {
        if meetingBatchManager == nil { try await downloadAndLoadMeetingManager() }
        guard let manager = meetingBatchManager else { throw EngineError.notLoaded }
        return try await runTranscribe(
            on: manager, samples: samples, language: language, modelLabel: "Parakeet v3 (meeting)")
    }

    // Bounds CoreML inference so a stuck decode can't pin the HUD on
    // "Transcribing" forever (a Parakeet prediction on the A18-class MacBook
    // Neo's ANE has been observed to never return). Audio-proportional budget
    // trips only on a genuine hang, not slow-but-working audio. Decoder state
    // is built inside the work closure to keep its `inout` off the
    // concurrency boundary.
    private func runTranscribe(
        on manager: AsrManager, samples: [Float], language: Language?, modelLabel: String
    ) async throws -> ASRResult {
        let started = Date()
        let audioSeconds = Double(samples.count) / 16_000
        let budget: Duration = .seconds(45) + .seconds(audioSeconds * 5)
        do {
            let result = try await withTimeout(budget) {
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                return try await manager.transcribe(
                    samples, decoderState: &state, language: language)
            }
            let elapsed = Date().timeIntervalSince(started)
            log.info(
                "\(modelLabel, privacy: .public) transcribed \(samples.count, privacy: .public) samples in \(String(format: "%.2f", elapsed), privacy: .public)s"
            )
            return result
        } catch is TimedOutError {
            let waited = Date().timeIntervalSince(started)
            log.error(
                "\(modelLabel, privacy: .public) transcription timed out after \(String(format: "%.1f", waited), privacy: .public)s for \(samples.count, privacy: .public) samples (\(String(format: "%.1f", audioSeconds), privacy: .public)s audio) - CoreML inference did not return. Aborting so the HUD can recover."
            )
            throw EngineError.transcriptionTimedOut
        }
    }

    func makeStreamingSession() async throws -> any StreamingSession {
        if let task = streamingWarmupTask {
            await task.value
            streamingWarmupTask = nil
        }
        if streamingManager == nil {
            await loadStreamingManager()
        }
        guard let manager = streamingManager else { throw EngineError.notLoaded }
        // Fresh decoder/cache state per session; the manager is reused
        // across sessions to avoid re-loading ~100 MB of CoreML graphs.
        await manager.reset()
        let session = StreamingEouAsrSession(manager: manager)
        try await session.start()
        return session
    }
}

// Streaming session backed by FluidAudio's StreamingEouAsrManager. Two
// callbacks feed one event stream: `setPartialCallback` (320ms cadence,
// full accumulated transcript - diffed against the last emission since
// EOU's decoder is append-only) and `setEouCallback` (fires after
// `eouDebounceMs` of silence with the raw transcript at that boundary).
// `finish()` always emits one final `.endOfUtterance` so trailing audio is
// reconciled even when no in-stream EOU fired (common on short utterances).
@MainActor
final class StreamingEouAsrSession: StreamingSession {
    nonisolated let events: AsyncStream<StreamingEvent>
    private let continuation: AsyncStream<StreamingEvent>.Continuation
    private let manager: StreamingEouAsrManager
    private let inputFormat: AVAudioFormat
    private let diff = PartialDiff()
    private let log = Logger(subsystem: "com.arunbrahma.hello", category: "parakeet.eou")

    init(manager: StreamingEouAsrManager) {
        self.manager = manager

        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        else {
            preconditionFailure("Could not construct streaming audio format")
        }
        self.inputFormat = format

        var continuation: AsyncStream<StreamingEvent>.Continuation!
        self.events = AsyncStream<StreamingEvent>(bufferingPolicy: .unbounded) { c in
            continuation = c
        }
        self.continuation = continuation
    }

    func start() async throws {
        // Handlers stay synchronous - a Task hop would race finish()'s
        // continuation.finish() and drop the last partial / EOU signal.
        let diff = self.diff
        let continuation = self.continuation
        await manager.setPartialCallback { full in
            if let suffix = diff.consume(full) {
                continuation.yield(.partial(suffix: suffix))
            }
        }
        await manager.setEouCallback { rawAccumulated in
            continuation.yield(.endOfUtterance(rawAccumulated: rawAccumulated))
        }
        log.info("EOU streaming session started.")
    }

    func feed(samples: [Float]) async throws {
        guard let buffer = makeBuffer(from: samples) else { return }
        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
        // FluidAudio's EOU detector latches until reset() - re-arm after every
        // utterance, which also clears the transcript so the next sentence
        // decodes fresh instead of appending to the previous one.
        if await manager.eouDetected {
            await manager.reset()
            diff.reset()
        }
    }

    func finish() async throws {
        // Flushes the final chunk (one more partialCallback) before
        // returning; the trailing .endOfUtterance covers utterances
        // where no in-stream EOU ever fired.
        let final = try await manager.finish()
        continuation.yield(.endOfUtterance(rawAccumulated: final))
        continuation.finish()
        log.info("EOU streaming session finished.")
    }

    func cancel() async {
        continuation.finish()
        // reset(), not cleanup() - keeps the CoreML graphs cached for reuse.
        await manager.reset()
    }

    private func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let dst = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            dst.update(from: base, count: samples.count)
        }
        return buffer
    }
}

// Shared between the @Sendable partial callback (manager actor) and the
// @MainActor session. NSLock keeps the callback synchronous; an actor
// would force a Task hop that races finish()'s stream closure.
private final class PartialDiff: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmitted: String = ""

    func consume(_ full: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        // The transcript only grows within an utterance, so this is normally
        // a clean suffix; the prefix branch is a safety hatch for any
        // out-of-order/revised emission.
        guard full.hasPrefix(lastEmitted) else {
            lastEmitted = full
            return full.isEmpty ? nil : full
        }
        guard full.count > lastEmitted.count else { return nil }
        let suffix = String(full.dropFirst(lastEmitted.count))
        lastEmitted = full
        return suffix
    }

    // Called at each EOU boundary so the next utterance diffs from empty.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastEmitted = ""
    }
}
