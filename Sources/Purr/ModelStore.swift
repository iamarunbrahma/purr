import AppKit
import Combine
import FluidAudio
import Foundation
import os.log

// A model download as Settings shows it: the bytes arriving, then the
// on-device step after them - CoreML compiling Parakeet's graphs for this
// Mac, or hashing Gemma's file - which reports no fraction of its own.
struct ModelDownloadProgress: Equatable {
    enum Stage: Int, Comparable {
        case downloading, compiling, verifying

        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var stage: Stage
    // 0...1 of the bytes while downloading; nil before the size is known,
    // for a download that reports none, and for the stages after it.
    var fraction: Double?

    static let starting = ModelDownloadProgress(stage: .downloading, fraction: nil)

    // The later of two readings, so a callback landing late can't move the
    // bar back, and a download that reached compiling stays there.
    func advanced(to next: ModelDownloadProgress) -> ModelDownloadProgress {
        if next.stage != stage { return next.stage > stage ? next : self }
        guard let nextFraction = next.fraction else { return self }
        return ModelDownloadProgress(stage: stage, fraction: max(fraction ?? 0, nextFraction))
    }
}

extension ModelDownloadProgress {
    // FluidAudio reports a repo download as one fraction: the bytes over
    // 0...0.5, then CoreML compiling over 0.5...1 (its ProgressReporter's
    // download weight, fixed while FluidAudio stays pinned). Parakeet's TDT
    // models load their four graphs as four such operations on one handler,
    // so the raw value falls back to 0.5 three times on the way; graphs
    // already on disk report zero files, which says nothing about the
    // download. Once every byte is in, the rest is CoreML readying the graphs
    // - which the EOU load reports nothing for. Rounded to 0.1% so a byte
    // callback that moves nothing visible isn't forwarded.
    init?(_ progress: DownloadProgress) {
        switch progress.phase {
        case .listing:
            self.init(stage: .downloading, fraction: 0)
        case .downloading(_, let totalFiles):
            guard totalFiles > 0 else { return nil }
            let fraction = (min(1, progress.fractionCompleted / 0.5) * 1000).rounded() / 1000
            self.init(stage: fraction < 1 ? .downloading : .compiling, fraction: fraction < 1 ? fraction : nil)
        case .compiling:
            self.init(stage: .compiling, fraction: nil)
        }
    }
}

// Every model Purr downloads, as Settings lists them.
enum ModelKind: Hashable, Identifiable, Sendable {
    case parakeet
    case parakeetMultilingual
    case smartTyping
    case diarizer
    case gemma
    case whisper(String)

    static var all: [ModelKind] {
        [.parakeet, .smartTyping, .parakeetMultilingual, .diarizer, .gemma]
            + ModelManager.curatedModels.map { .whisper($0.id) }
    }

    var id: String {
        switch self {
        case .parakeet: return "parakeet-v2"
        case .parakeetMultilingual: return "parakeet-v3"
        case .smartTyping: return "parakeet-eou"
        case .diarizer: return "diarizer"
        case .gemma: return "gemma"
        case .whisper(let name): return name
        }
    }

    var title: String {
        switch self {
        case .parakeet: return "Parakeet TDT v2"
        case .parakeetMultilingual: return "Parakeet TDT v3"
        case .smartTyping: return "Parakeet EOU 120M"
        case .diarizer: return "Speaker Diarization"
        case .gemma: return LLMModelManager.defaultModelLabel
        case .whisper(let name): return "Whisper \(Self.whisperChoice(name)?.label ?? name)"
        }
    }

    // What the model does in Purr, shown under its name.
    var purpose: String {
        switch self {
        case .parakeet: return "Dictation, meetings and voice edit"
        case .parakeetMultilingual: return "Meetings in other languages"
        case .smartTyping: return "Smart Typing"
        case .diarizer: return "Who said what in meetings"
        case .gemma: return "Summaries and voice edit"
        case .whisper(let name): return Self.whisperChoice(name)?.note ?? "Dictation"
        }
    }

    // Shown until the model is on disk. Parakeet's and the diarizer's are
    // the downloaded files' total; Whisper's sizes are MiB.
    var downloadBytes: Int64 {
        switch self {
        case .parakeet: return 464_413_250
        case .parakeetMultilingual: return 483_256_769
        case .smartTyping: return 224_238_533
        case .diarizer: return 21_776_918
        case .gemma: return LLMModelManager.defaultModelExpectedSize
        case .whisper(let name): return Int64(Self.whisperChoice(name)?.sizeMB ?? 0) * 1_048_576
        }
    }

    // The model's folder (Gemma's file), for its size and Show in Finder.
    @MainActor var location: URL {
        switch self {
        case .parakeet: return ParakeetEngine.batchModelDirectory
        case .parakeetMultilingual: return ParakeetEngine.meetingModelDirectory
        case .smartTyping: return ParakeetEngine.eouModelDirectory
        case .diarizer: return Diarizer.modelDirectory
        case .gemma: return LLMModelManager.localURL
        case .whisper(let name):
            return ModelManager.modelsDirectory.appendingPathComponent(name, isDirectory: true)
        }
    }

    // Every file the model loads is on disk - an interrupted download leaves
    // a folder that isn't.
    @MainActor var isInstalled: Bool {
        switch self {
        case .parakeet: return ParakeetEngine.batchIsInstalled()
        case .parakeetMultilingual: return ParakeetEngine.meetingModelIsInstalled()
        case .smartTyping: return ParakeetEngine.eouIsInstalled()
        case .diarizer: return Diarizer.isInstalled()
        case .gemma: return LLMModelManager.isInstalled()
        case .whisper(let name): return ModelManager.isInstalled(name)
        }
    }

    private static func whisperChoice(_ name: String) -> ModelChoice? {
        ModelManager.curatedModels.first { $0.id == name }
    }
}

// Live state of every model for Settings: whether it's on this Mac - re-read
// from disk, so a model deleted in Finder shows as missing - how far a
// download has got, and what last went wrong. Parakeet's three downloads
// belong to the coordinator, since warmup and meetings start them too, so
// their progress is mirrored here; the rest start from here.
@MainActor
final class ModelStore: ObservableObject {
    struct Status: Equatable {
        var isOnDisk = false
        // Measured off the main thread once the model is on disk; rows show
        // the download size until then.
        var bytesOnDisk: Int64?
        var download: ModelDownloadProgress?
        var failure: Failure?
    }

    struct Failure: Equatable {
        let message: String
        // A failed download offers Retry; a refused delete only explains.
        let duringDownload: Bool
    }

    @Published private(set) var statuses: [ModelKind: Status] = [:]
    // Apple's built-in model, which needs no download: summaries and voice
    // edit use it in place of Gemma when it's there.
    @Published private(set) var appleIntelligenceAvailable = false

    private let coordinator: AppCoordinator
    private var observers: Set<AnyCancellable> = []
    private var pollTimer: Timer?
    private var measuring: Task<Void, Never>?
    private let log = Logger(subsystem: "com.arunbrahma.purr", category: "summarizer")

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        coordinator.$parakeetBatchProgress
            .sink { [weak self] in self?.mirror(.parakeet, $0) }
            .store(in: &observers)
        coordinator.$eouDownloadProgress
            .sink { [weak self] in self?.mirror(.smartTyping, $0) }
            .store(in: &observers)
        coordinator.$meetingLanguageModelProgress
            .sink { [weak self] in self?.mirror(.parakeetMultilingual, $0) }
            .store(in: &observers)
        refresh()
    }

    subscript(kind: ModelKind) -> Status { statuses[kind] ?? Status() }

    // Gates Delete All, so a wipe can't pull files out from under a download.
    var isDownloading: Bool { statuses.values.contains { $0.download != nil } }

    var totalBytesOnDisk: Int64 { statuses.values.compactMap(\.bytesOnDisk).reduce(0, +) }

    // While Settings is open, so a model deleted in Finder, or a download
    // that finishes, shows up without reopening the window.
    func startWatching() {
        refresh()
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // Re-reads the disk. The probes are a few file checks, so they run here;
    // a size walks every file, so it's summed off the main thread, once per
    // install.
    func refresh() {
        let appleAvailable = Self.appleFoundationAvailable
        if appleIntelligenceAvailable != appleAvailable { appleIntelligenceAvailable = appleAvailable }
        var unmeasured: [(ModelKind, URL)] = []
        for kind in ModelKind.all {
            let installed = kind.isInstalled
            update(kind) {
                $0.isOnDisk = installed
                if !installed { $0.bytesOnDisk = nil }
            }
            if installed, self[kind].bytesOnDisk == nil { unmeasured.append((kind, kind.location)) }
        }
        guard !unmeasured.isEmpty, measuring == nil else { return }
        measuring = Task {
            let sizes = await Task.detached(priority: .utility) {
                unmeasured.map { ($0.0, ModelManager.bytesOnDisk(at: $0.1)) }
            }.value
            measuring = nil
            for (kind, bytes) in sizes where self[kind].isOnDisk {
                update(kind) { $0.bytesOnDisk = bytes }
            }
        }
    }

    func download(_ kind: ModelKind) {
        guard self[kind].download == nil else { return }
        update(kind) {
            $0.failure = nil
            $0.download = .starting
        }
        Task {
            do {
                try await fetch(kind)
            } catch {
                update(kind) { $0.failure = Failure(message: friendlyDownloadError(error), duringDownload: true) }
            }
            // Parakeet's own reports end with nil; this ends the rest, and a
            // fetch that found the files already there.
            update(kind) { $0.download = nil }
            refresh()
        }
    }

    private func fetch(_ kind: ModelKind) async throws {
        switch kind {
        case .parakeet:
            try Self.check(await coordinator.downloadParakeetModel())
        case .parakeetMultilingual:
            try Self.check(await coordinator.downloadMeetingLanguageModel())
        case .smartTyping:
            try Self.check(await coordinator.downloadEOUModel())
        case .diarizer:
            // FluidAudio's diarizer takes no progress handler, so its ~22 MB
            // shows as an indeterminate bar, then as compiling once every file
            // is on disk (FluidAudio moves each one into place whole).
            let compileWatch = Task { [weak self] in
                while !Diarizer.isInstalled() {
                    try await Task.sleep(for: .milliseconds(500))
                }
                self?.advance(kind, to: ModelDownloadProgress(stage: .compiling, fraction: nil))
            }
            defer { compileWatch.cancel() }
            try Self.check(await coordinator.downloadDiarizationModel())
        case .gemma:
            // Doesn't pre-load the LlamaSession - that happens lazily on first
            // summarize, so Settings doesn't wait through model-init.
            try await LLMModelManager.download { [weak self] fraction in
                Task { @MainActor in
                    // The SHA-256 check runs once the last byte lands.
                    let reading =
                        fraction < 1
                        ? ModelDownloadProgress(stage: .downloading, fraction: (fraction * 1000).rounded() / 1000)
                        : ModelDownloadProgress(stage: .verifying, fraction: nil)
                    self?.advance(kind, to: reading)
                }
            }
        case .whisper(let name):
            try await ModelManager.download(modelName: name) { [weak self] fraction in
                Task { @MainActor in
                    self?.advance(kind, to: ModelDownloadProgress(stage: .downloading, fraction: fraction))
                }
            }
            // Picking a model warms the engine before its files exist, which
            // fails quietly. Load it now, so the first dictation doesn't wait.
            let settings = SettingsStore.shared
            if settings.engine == .whisper, settings.modelName == name {
                coordinator.reloadEngine()
            }
        }
    }

    func delete(_ kind: ModelKind) {
        update(kind) { $0.failure = nil }
        switch kind {
        case .parakeet:
            report(kind, coordinator.deleteParakeetModel(), busy: "Finish dictating or the meeting, then try again.")
        case .parakeetMultilingual:
            report(kind, coordinator.deleteMeetingLanguageModel(), busy: "Finish the meeting, then try again.")
        case .smartTyping:
            report(kind, coordinator.deleteEOUModel(), busy: "Release the dictation shortcut, then try again.")
        case .diarizer:
            report(kind, coordinator.deleteDiarizationModel(), busy: "Stop the meeting, then try again.")
        case .whisper(let name):
            do {
                try ModelManager.delete(name)
            } catch {
                update(kind) { $0.failure = Failure(message: error.localizedDescription, duringDownload: false) }
            }
        case .gemma:
            Task { await deleteGemma() }
            return
        }
        refresh()
    }

    func deleteAll() async -> AppCoordinator.DeleteAllModelsResult {
        let result = await coordinator.deleteAllModels()
        refresh()
        return result
    }

    // Unloads first - a cached session pointing at deleted weights would be
    // reused by the next generation, and leak ~3.3GB - then falls back to
    // Apple's model, or turns summaries off when nothing is left.
    private func deleteGemma() async {
        log.info("Gemma delete: starting.")
        let appleFallbackUsable = Self.appleFoundationAvailable
        await MeetingSummarizer.shared.unload()
        do {
            try LLMModelManager.delete()
            log.info("Gemma delete: on-disk weights removed.")
        } catch {
            log.error("Gemma delete: removeItem failed: \(error.localizedDescription, privacy: .public)")
            update(.gemma) { $0.failure = Failure(message: error.localizedDescription, duringDownload: false) }
            return
        }
        if appleFallbackUsable {
            SettingsStore.shared.summaryBackend = .appleFoundation
        } else {
            SettingsStore.shared.summarizeMeetings = false
        }
        refresh()
    }

    private func mirror(_ kind: ModelKind, _ progress: ModelDownloadProgress?) {
        let ended = progress == nil && self[kind].download != nil
        update(kind) {
            $0.download = progress
            if progress != nil { $0.failure = nil }
        }
        if ended { refresh() }
    }

    // Ignored once the download is over, so a callback landing late can't
    // bring a finished bar back.
    private func advance(_ kind: ModelKind, to reading: ModelDownloadProgress) {
        update(kind) { status in
            guard let current = status.download else { return }
            status.download = current.advanced(to: reading)
        }
    }

    private func report(
        _ kind: ModelKind, _ result: AppCoordinator.DiarizerDeleteResult, busy: String
    ) {
        switch result {
        case .ok: break
        case .busy:
            update(kind) { $0.failure = Failure(message: busy, duringDownload: false) }
        case .failed(let error):
            update(kind) { $0.failure = Failure(message: error.localizedDescription, duringDownload: false) }
        }
    }

    // Publishes only real changes, so a poll that finds nothing new doesn't
    // redraw every row.
    private func update(_ kind: ModelKind, _ change: (inout Status) -> Void) {
        var status = self[kind]
        change(&status)
        if statuses[kind] != status { statuses[kind] = status }
    }

    private static var appleFoundationAvailable: Bool {
        if #available(macOS 26.0, *) { return MeetingSummarizer.appleFoundationAvailable }
        return false
    }

    private static func check(_ result: AppCoordinator.ModelDownloadResult) throws {
        if case .failed(let error) = result { throw error }
    }
}

// Unrecognized errors fall through to localizedDescription.
private func friendlyDownloadError(_ error: Error) -> String {
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
        switch ns.code {
        case NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotConnectToHost:
            return "No internet connection. Check your network and retry."
        case NSURLErrorTimedOut:
            return "Download timed out. Retry."
        case NSURLErrorCancelled:
            return "Download cancelled."
        default:
            return "Network error. \(ns.localizedDescription)"
        }
    }
    if ns.domain == NSPOSIXErrorDomain, ns.code == 28 {
        return "Not enough free disk space."
    }
    return "Download failed. \(ns.localizedDescription)"
}
