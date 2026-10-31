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
//   320ms chunks. Its partial transcript drives the live preview and a pause
//   ends each utterance, which the batch model re-transcribes before
//   PostProcessor runs on it.
@MainActor
final class ParakeetEngine: TranscriptionEngine {
    nonisolated let supportsStreaming: Bool = true

    private var batchManager: AsrManager?
    // Coalesces concurrent callers (an automatic warmup and a manual Settings
    // download can fire at once) onto one in-flight download.
    private var batchLoadTask: Task<Void, Error>?
    // Each model's download progress, to whichever @Published the
    // coordinator wires up.
    let batchDownload = DownloadReporter()
    private var meetingBatchManager: AsrManager?
    private var meetingBatchLoadTask: Task<Void, Error>?
    let meetingBatchDownload = DownloadReporter()
    private var streamingManager: StreamingEouAsrManager?
    private var streamingWarmupTask: Task<Void, Never>?
    let eouDownload = DownloadReporter()
    private let log = Logger(subsystem: "com.arunbrahma.purr", category: "parakeet")

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
            _ = streamingLoad()
        }
    }

    var isLoaded: Bool { batchManager != nil }
    var needsDownload: Bool { !Self.batchIsInstalled() }
    var isStreamingLoaded: Bool { streamingManager != nil }
    var isMeetingModelLoaded: Bool { meetingBatchManager != nil }

    func load() async throws {
        if batchManager != nil { return }
        do {
            if Self.batchIsInstalled() {
                log.notice("Waiting for Parakeet TDT v2 to load.")
                try await withTimeout(modelLoadTimeout) { try await self.downloadAndLoadBatchManager() }
            } else {
                try await downloadAndLoadBatchManager()
            }
        } catch is TimedOutError {
            log.error("Gave up waiting for Parakeet TDT v2 to load. It keeps loading in the background.")
            throw EngineError.modelLoadTimedOut
        } catch {
            log.error("Parakeet TDT v2 failed to load: \(error.localizedDescription, privacy: .public)")
            throw EngineError.notLoaded
        }
    }

    // Throwing variant of warmup's batch load: propagates errors and reports
    // progress, for the Settings download button. Coalesces with any
    // concurrent warmup so the weights are only ever pulled once. A model
    // still loaded after its files were deleted (in Finder, say) is fetched
    // again, so the disk matches what Settings shows.
    func downloadAndLoadBatchManager() async throws {
        if batchManager != nil, Self.batchIsInstalled() { return }
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
        let reporter = Self.batchIsInstalled() ? nil : batchDownload
        reporter?.begin()
        defer { reporter?.end() }
        let started = Date()
        log.notice("Parakeet TDT v2 loading\(reporter == nil ? "" : ", downloading first", privacy: .public).")
        let models = try await AsrModels.downloadAndLoad(
            to: Self.batchModelDirectory, version: .v2, progressHandler: reporter?.handler)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        try Task.checkCancellation()
        batchManager = manager
        log.notice(
            "Parakeet TDT v2 loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public)s."
        )
    }

    // v3 counterpart to downloadAndLoadBatchManager() - same coalescing-task
    // shape, so a manual Settings download and a meeting hitting a
    // non-English language don't race two pulls into the same folder.
    func downloadAndLoadMeetingManager() async throws {
        if meetingBatchManager != nil, Self.meetingModelIsInstalled() { return }
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
        let reporter = Self.meetingModelIsInstalled() ? nil : meetingBatchDownload
        reporter?.begin()
        defer { reporter?.end() }
        let started = Date()
        log.notice("Parakeet TDT v3 loading\(reporter == nil ? "" : ", downloading first", privacy: .public).")
        let models = try await AsrModels.downloadAndLoad(
            to: Self.meetingModelDirectory, version: .v3, progressHandler: reporter?.handler)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        try Task.checkCancellation()
        meetingBatchManager = manager
        log.notice(
            "Parakeet TDT v3 loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public)s."
        )
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
        ModelManager.filesComplete(
            ModelNames.ASR.requiredModelsV3().union([ModelNames.ASR.vocabularyFile]),
            in: meetingModelDirectory)
    }

    static func meetingModelDelete() throws {
        let url = meetingModelDirectory
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // Smart Typing's model load, shared by warmup and presses: the one in
    // flight, or a new one. Cleared when it ends, so a press after a failed
    // load starts over, and a load that outlives a press's wait is still
    // there for the next press to join.
    private func streamingLoad() -> Task<Void, Never> {
        if let inFlight = streamingWarmupTask { return inFlight }
        let task = Task { [weak self] () -> Void in
            await self?.loadStreamingManager()
        }
        streamingWarmupTask = task
        Task { [weak self] in
            await task.value
            if self?.streamingWarmupTask == task { self?.streamingWarmupTask = nil }
        }
        return task
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
        if streamingManager != nil, Self.eouIsInstalled() { return }
        let reporter = Self.eouIsInstalled() ? nil : eouDownload
        reporter?.begin()
        defer { reporter?.end() }
        let started = Date()
        log.notice("Parakeet EOU loading\(reporter == nil ? "" : ", downloading first", privacy: .public).")
        let manager = StreamingEouAsrManager(
            configuration: MLModelConfiguration(),
            chunkSize: Self.streamingChunk,
            eouDebounceMs: 1280
        )
        try await manager.loadModels(to: ModelManager.modelsDirectory, progressHandler: reporter?.handler)
        streamingManager = manager
        log.notice(
            "Parakeet EOU loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public)s (\(Self.streamingChunk.durationMs, privacy: .public) ms chunks)."
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
        ModelManager.filesComplete(
            ModelNames.ASR.requiredModels.union([ModelNames.ASR.vocabularyFile]), in: batchModelDirectory)
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

    // Checks the variant streamingChunk loads, not just the parent folder.
    static func eouIsInstalled() -> Bool {
        ModelManager.filesComplete(
            ModelNames.ParakeetEOU.requiredModels,
            in: ModelManager.modelsDirectory.appendingPathComponent(
                Repo.parakeetEou320.folderName, isDirectory: true))
    }

    static func eouDelete() throws {
        let url = eouModelDirectory
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func transcribe(samples: [Float]) async throws -> String {
        try await load()
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
    // "Transcribing" forever. Audio-proportional budget trips only on a
    // genuine hang, not slow-but-working audio. Decoder state is built inside
    // the work closure to keep its `inout` off the concurrency boundary.
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
        if streamingManager == nil {
            let task = streamingLoad()
            log.notice("Waiting for Parakeet EOU to load.")
            do {
                try await withTimeout(modelLoadTimeout) { await task.value }
            } catch is TimedOutError {
                log.error("Gave up waiting for Parakeet EOU to load. It keeps loading in the background.")
                throw EngineError.modelLoadTimedOut
            }
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
// `setPartialCallback` (320ms cadence, full accumulated transcript - diffed
// against the last emission since EOU's decoder is append-only) drives the
// live preview. feed() ends an utterance at a pause, and `finish()` emits a
// final `.endOfUtterance` for anything heard since the last one. Each
// boundary carries that utterance's audio for the batch-quality pass.
@MainActor
final class StreamingEouAsrSession: StreamingSession {
    nonisolated let events: AsyncStream<StreamingEvent>
    private let continuation: AsyncStream<StreamingEvent>.Continuation
    private let manager: StreamingEouAsrManager
    private let inputFormat: AVAudioFormat
    private let diff = PartialDiff()
    private let log = Logger(subsystem: "com.arunbrahma.purr", category: "parakeet.eou")
    // Audio since the current utterance began, handed out with its
    // .endOfUtterance. Positions count samples fed since start():
    // `utteranceStart` is the utterance's first sample, `managerOrigin` the
    // manager's time zero (token timestamps count from its last reset).
    private var utteranceSamples: [Float] = []
    private var utteranceStart = 0
    private var samplesFed = 0
    private var managerOrigin = 0
    private var activity = SpeechActivity()
    // FluidAudio's EOU head rarely fires on ordinary room noise, so ~1s with
    // no newly decoded words also ends the utterance - unless the speech
    // around the last word is still going (decoding stalls mid-phrase on
    // fillers), for up to ~3s.
    private var samplesSinceLastWord = 0
    private var lastTokenSample = 0
    private static let pauseSampleCount = 16_000
    private static let maxPauseSampleCount = 48_000
    private static let stillTalkingSampleCount = 4_800
    // One 320ms-mode chunk window, replayed after an EOU reset.
    private static let replaySampleCount = 10_240

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
        // The handler stays synchronous - a Task hop would race finish()'s
        // continuation.finish() and drop the last partial.
        let diff = self.diff
        let continuation = self.continuation
        await manager.setPartialCallback { full in
            if let suffix = diff.consume(full) {
                continuation.yield(.partial(suffix: suffix))
            }
        }
        log.info("EOU streaming session started.")
    }

    func feed(samples: [Float]) async throws {
        guard let buffer = makeBuffer(from: samples) else { return }
        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
        utteranceSamples.append(contentsOf: samples)
        samplesFed += samples.count
        activity.process(samples)
        if diff.takeNewWords() {
            samplesSinceLastWord = 0
            let lastTokenMs = await manager.getTokenTimestampsMs().last ?? 0
            lastTokenSample = managerOrigin + lastTokenMs * 16
        } else {
            samplesSinceLastWord += samples.count
        }

        // FluidAudio's EOU detector latches until reset(), so an EOU always
        // resets, but only once the speech has paused as long as a pause
        // needs: its head can call a pause over speech it decoded nothing for
        // ("scratch that" said quickly), and cutting there splits the phrase.
        // A pause leaves the decoder running: reset() drops the audio
        // buffered for the next chunk, which can already hold the next
        // sentence's first word.
        let speechPaused = utteranceSpeechEnd.map { samplesFed - $0 >= Self.pauseSampleCount } ?? true
        if await manager.eouDetected, speechPaused {
            try await endUtterance(resetDecoder: true)
        } else if diff.hasPendingText {
            let stillTalking =
                activity.speechEnd(around: lastTokenSample) > samplesFed - Self.stillTalkingSampleCount
            if samplesSinceLastWord >= (stillTalking ? Self.maxPauseSampleCount : Self.pauseSampleCount) {
                try await endUtterance(resetDecoder: false)
            }
        } else if heardSpeech, samplesFed - activity.lastSpeechEnd >= Self.pauseSampleCount {
            // Speech the streaming model decoded nothing for - the batch
            // pass still gets to read it.
            try await endUtterance(resetDecoder: false)
        }
    }

    // Whether the current utterance holds speech by energy, decoded or not.
    private var heardSpeech: Bool { activity.lastSpeechEnd > utteranceStart }

    // Where the current utterance's speech stopped: around its last decoded
    // word, else the last speech heard; nil when it holds neither.
    private var utteranceSpeechEnd: Int? {
        if diff.hasPendingText { return activity.speechEnd(around: lastTokenSample) }
        return heardSpeech ? activity.lastSpeechEnd : nil
    }

    // Hands the utterance's text and audio to the consumer. A pause is only
    // noticed ~1s after the last decoded word, when the next sentence may
    // already have begun, so the audio is cut by where the speech actually
    // stopped and the rest stays with the next utterance. An EOU over
    // silence only re-arms the detector.
    private func endUtterance(resetDecoder: Bool) async throws {
        let speechEnd = utteranceSpeechEnd
        let text = diff.commitPending()
        if let speechEnd {
            let cut = activity.cutPoint(after: speechEnd, limit: samplesFed)
            let count = min(max(cut - utteranceStart, 0), utteranceSamples.count)
            continuation.yield(.endOfUtterance(rawAccumulated: text, audio: Array(utteranceSamples[..<count])))
            utteranceSamples.removeFirst(count)
            utteranceStart += count
            activity.dropRuns(endingBefore: utteranceStart)
        }
        samplesSinceLastWord = 0
        guard resetDecoder else { return }

        await manager.reset()
        diff.reset()
        // reset() also drops the audio buffered for the next chunk - replay
        // the tail so a word already starting there isn't clipped. Only audio
        // not yet handed out, so nothing is decoded twice.
        let replay = Array(utteranceSamples.suffix(Self.replaySampleCount))
        managerOrigin = samplesFed - replay.count
        if let buffer = makeBuffer(from: replay) {
            try await manager.appendAudio(buffer)
        }
    }

    func finish() async throws {
        // Flushes the final chunk (one more partialCallback) before
        // returning. Audio with nothing decoded and no speech heard is
        // dropped rather than run through the batch model, which can
        // hallucinate a sentence over bare room noise.
        _ = try await manager.finish()
        let text = diff.commitPending()
        if !text.isEmpty || heardSpeech {
            continuation.yield(.endOfUtterance(rawAccumulated: text, audio: utteranceSamples))
        }
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

// One model download's progress, as Settings shows it: `.starting` from
// begin(), each FluidAudio reading after it only ever forward, nothing once
// end() has run, then nil.
@MainActor
final class DownloadReporter {
    var onChange: ((ModelDownloadProgress?) -> Void)?
    private var current: ModelDownloadProgress?

    func begin() {
        current = .starting
        onChange?(current)
    }

    func end() {
        current = nil
        onChange?(nil)
    }

    // FluidAudio calls it off the main actor, on every chunk of bytes.
    nonisolated var handler: ProgressHandler {
        { [weak self] progress in
            guard let reading = ModelDownloadProgress(progress) else { return }
            Task { @MainActor in self?.advance(to: reading) }
        }
    }

    private func advance(to reading: ModelDownloadProgress) {
        guard let current else { return }
        let next = current.advanced(to: reading)
        guard next != current else { return }
        self.current = next
        onChange?(next)
    }
}

// Shared between the @Sendable partial callback (manager actor) and the
// @MainActor session. NSLock keeps the callback synchronous; an actor
// would force a Task hop that races finish()'s stream closure.
private final class PartialDiff: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmitted: String = ""
    // How much of lastEmitted earlier utterances already took, and whether
    // anything was decoded since.
    private var committedCount = 0
    private var pending = false
    private var newWords = false

    func consume(_ full: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        // FluidAudio only calls back when a chunk decoded new tokens.
        newWords = true
        // The transcript only grows until a reset, so this is normally
        // a clean suffix; the prefix branch is a safety hatch for any
        // out-of-order/revised emission.
        guard full.hasPrefix(lastEmitted) else {
            lastEmitted = full
            committedCount = min(committedCount, full.count)
            pending = full.count > committedCount
            return full.isEmpty ? nil : full
        }
        guard full.count > lastEmitted.count else { return nil }
        var suffix = String(full.dropFirst(lastEmitted.count))
        lastEmitted = full
        // The first words after a boundary start a fresh preview.
        if !pending { suffix = String(suffix.drop(while: \.isWhitespace)) }
        guard !suffix.isEmpty else { return nil }
        pending = true
        return suffix
    }

    // The text decoded since the last call (trimmed), now marked as taken.
    func commitPending() -> String {
        lock.lock()
        defer { lock.unlock() }
        let text = lastEmitted.dropFirst(committedCount).trimmingCharacters(in: .whitespaces)
        committedCount = lastEmitted.count
        pending = false
        return text
    }

    // Whether anything was decoded since the last commitPending().
    var hasPendingText: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    // Called when the decoder resets, so the next utterance diffs from empty.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastEmitted = ""
        committedCount = 0
        pending = false
    }

    // Whether any words were decoded since the last call.
    func takeNewWords() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let result = newWords
        newWords = false
        return result
    }
}
