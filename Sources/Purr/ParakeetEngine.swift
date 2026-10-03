import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation
import os.log

// Parakeet via FluidAudio. Two completely separate models live behind this
// engine, and they each serve a different UX:
//
// * **Batch / Meeting / Voice-edit** → `AsrManager` with Parakeet TDT 0.6B v2
//   (English-only, 600 M params, ~120× RTF on Apple Silicon, word-level
//   timings used by the meeting diarizer). Used for "hold-to-talk, paste on
//   release" dictation and for offline transcription of recorded audio.
//
// * **Smart typing (live)** → `StreamingEouAsrManager` with the Parakeet
//   realtime EOU 120 M model at 320 ms chunks. Cache-aware streaming
//   encoder whose partial-transcript callback fires every chunk with the
//   accumulated tokens, so the consumer can diff + type as the user
//   speaks. A separate EOU callback fires after sustained silence and
//   marks the boundary where PostProcessor runs on the just-completed
//   utterance.
//
// Both models warm up in parallel; the EOU model is ~80-120 MB and
// downloads from HuggingFace the first time the user enables Parakeet.
@MainActor
final class ParakeetEngine: TranscriptionEngine {
    nonisolated let supportsStreaming: Bool = true

    private var batchManager: AsrManager?
    // The single in-flight batch download+load. Concurrent callers (an automatic
    // warmup and a manual Settings download can fire at once) coalesce onto this
    // one task instead of each starting a parallel ~450 MB pull to the same folder.
    private var batchLoadTask: Task<Void, Error>?
    // Reports the batch download's progress (0..1 while downloading, nil when it
    // ends) to one observer, regardless of which path started the download. The
    // coordinator wires this to a @Published so the Settings card shows a live
    // bar for warm-up downloads too. `batchDownloadActive` gates late progress
    // callbacks that could otherwise land after the download finished.
    var onBatchProgress: ((Double?) -> Void)?
    private var batchDownloadActive = false
    private var streamingManager: StreamingEouAsrManager?
    private var streamingWarmupTask: Task<Void, Never>?
    // Same shape as onBatchProgress, for the EOU streaming model: reports 0..1
    // while downloading (whoever started it - warm-up or the Settings button)
    // and nil when done, so the Smart Typing card shows a bar for an
    // auto-download too. `eouDownloadActive` gates late progress callbacks.
    var onEOUProgress: ((Double?) -> Void)?
    private var eouDownloadActive = false
    private let log = Logger(subsystem: "com.arunbrahma.purr", category: "parakeet")

    // 320 ms is the documented sweet spot per FluidAudio's own benchmark
    // table (4.88 % WER on LibriSpeech test-clean vs 8.23 % at 160 ms),
    // and 320 ms latency is well inside the threshold where typing feels
    // live. 160 ms is the fallback if a future user complains about lag.
    private static let streamingChunk: StreamingChunkSize = .ms320

    func warmup() async {
        do {
            try await downloadAndLoadBatchManager()
        } catch {
            log.error("Parakeet warmup failed: \(error.localizedDescription, privacy: .public)")
        }

        // Preload the streaming EOU model only when Smart Typing is on AND the
        // model is already on disk - warm-up loads it for instant Smart Typing
        // but never downloads it. The ~440 MB download happens exclusively from
        // the Settings Download button, which is what enables the toggle.
        // Detached so the batch path doesn't wait on the load.
        if SettingsStore.shared.smartTyping, Self.eouIsInstalled(), streamingManager == nil,
            streamingWarmupTask == nil
        {
            streamingWarmupTask = Task { [weak self] in
                await self?.loadStreamingManager()
            }
        }
    }

    // Throwing variant of the batch warmup: propagates download errors instead
    // of swallowing them, and reports a 0..1 download fraction so the Settings
    // row can show progress. Lets the user fetch the ~450 MB TDT v2 weights on
    // demand (e.g. after deleting models) rather than waiting for the next
    // dictation press to trigger it.
    //
    // Concurrent calls coalesce: the first creates the load task, later callers
    // await that same task instead of starting a second download. So a manual
    // Settings download and an automatic warmup firing together still pull the
    // weights exactly once.
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

    // The actual download + load, only ever invoked through the coalescing task
    // above. Progress goes to `onBatchProgress` (0 at start, fractions during,
    // nil at end) so every initiator drives the same UI. checkCancellation
    // guards the assignment so a delete that cancels the task mid-flight can't
    // resurrect the manager from removed files.
    private func loadBatchManager() async throws {
        // Only surface progress when weights will actually be fetched; a
        // load-from-disk on warm-up shouldn't flash "downloading…".
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
        let models = try await AsrModels.downloadAndLoad(
            to: Self.batchModelDirectory, version: .v2,
            progressHandler: { [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    guard let self, self.batchDownloadActive else { return }
                    self.onBatchProgress?(fraction)
                }
            })
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        try Task.checkCancellation()
        batchManager = manager
        log.info("Parakeet TDT v2 downloaded and warmed up.")
    }

    private func loadStreamingManager() async {
        do {
            try await downloadAndLoadStreamingManager()
        } catch {
            log.error(
                "Parakeet EOU warmup failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // Throwing variant: propagates download errors (network down, HF outage)
    // instead of swallowing them. Progress goes to `onEOUProgress` (0 at start,
    // fractions during, nil at end) so every initiator - warm-up or the Settings
    // button - drives the same Smart Typing card.
    func downloadAndLoadStreamingManager() async throws {
        guard streamingManager == nil else { return }
        // Only surface progress when the model will actually be fetched; a
        // load-from-disk on warm-up shouldn't flash "downloading…".
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
        try await manager.loadModels(
            to: ModelManager.modelsDirectory,
            progressHandler: { [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    guard let self, self.eouDownloadActive else { return }
                    self.onEOUProgress?(fraction)
                }
            })
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

    // Drops the in-memory batch CoreML graphs (and cancels any in-flight load) so
    // a subsequent on-disk delete doesn't leave a stale mmap pointing at removed
    // files. The next transcribe re-warms (and re-downloads if the weights are
    // gone). MUST run before ModelManager.deleteAllModels.
    func unloadBatchManager() {
        batchLoadTask?.cancel()
        batchLoadTask = nil
        batchManager = nil
        log.info("Parakeet TDT batch unloaded.")
    }

    // Where the batch Parakeet TDT v2 weights live. Routed under Purr's own
    // models folder (instead of FluidAudio's default) so every Purr model sits
    // in one place that uninstalling removes. `downloadAndLoad(to:)` treats
    // this as the model's own directory and writes/reads the CoreML bundles here.
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

    // Returns token timings (dropped by transcribe()) for speaker-segment
    // alignment when merging diarization output.
    //
    // We run the English-only v2 model (highest English recall on the Open
    // ASR Leaderboard; non-English dictation uses the Whisper engine instead).
    // `language: .english` is a no-op on v2 - it only drives v3's multilingual
    // script-aware token filter - but is left in so the call is correct if the
    // model version is ever switched back.
    func transcribeDetailed(samples: [Float]) async throws -> ASRResult {
        if batchManager == nil { await warmup() }
        guard let manager = batchManager else { throw EngineError.notLoaded }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let started = Date()
        let result = try await manager.transcribe(
            samples, decoderState: &state, language: .english)
        let elapsed = Date().timeIntervalSince(started)
        log.info(
            "Parakeet transcribed \(samples.count, privacy: .public) samples in \(String(format: "%.2f", elapsed), privacy: .public)s"
        )
        return result
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

// Streaming session backed by FluidAudio's StreamingEouAsrManager.
// Two callbacks feed one event stream:
//
// * `setPartialCallback` — 320 ms cadence, full accumulated transcript.
//   Consumers receive the full snapshot so revisions cannot masquerade as
//   a new suffix and duplicate already-inserted words.
// * `setEouCallback` — fires after the configured silence debounce with
//   the accumulated transcript at that phrase boundary.
//
// `finish()` always emits one final `.endOfUtterance` before closing
// the stream so trailing audio is reconciled even when no in-stream
// EOU fired (short utterances often skip the in-stream signal).
@MainActor
final class StreamingEouAsrSession: StreamingSession {
    nonisolated let events: AsyncStream<StreamingEvent>
    private let continuation: AsyncStream<StreamingEvent>.Continuation
    private let manager: StreamingEouAsrManager
    private let inputFormat: AVAudioFormat
    private let log = Logger(subsystem: "com.arunbrahma.purr", category: "parakeet.eou")

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
        let continuation = self.continuation
        await manager.setPartialCallback { full in
            continuation.yield(.partial(text: full))
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
        // FluidAudio's EOU detector latches: once it fires, `eouDetected` stays
        // true and no further EOU is raised until reset(). So re-arm after every
        // utterance. reset() also clears the accumulated transcript, so the next
        // sentence is decoded fresh and reaches the consumer as a complete
        // utterance (not appended to the previous one). The EOU callback has
        // already yielded this sentence's transcript by the time we get here, and
        // the manager is an actor so this reset can't race the next process().
        if await manager.eouDetected {
            await manager.reset()
        }
    }

    func finish() async throws {
        // manager.finish() flushes the padded final chunk (which fires
        // one more partialCallback) before returning the full transcript.
        // The trailing .endOfUtterance covers utterances where no in-
        // stream EOU ever fired.
        let final = try await manager.finish()
        continuation.yield(.endOfUtterance(rawAccumulated: final))
        continuation.finish()
        log.info("EOU streaming session finished.")
    }

    func cancel() async {
        continuation.finish()
        // Reset clears decoder + audio buffer state; cleanup() would
        // unload the CoreML graphs, which we want to keep cached for the
        // next session.
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
