import AppKit
import FluidAudio
import Foundation
import os.log

// Meeting recording flow. Kept in memory - a 90-minute meeting at 16kHz
// Float32 mono is ~330MB, comfortable on any Apple Silicon Mac.
@MainActor
final class MeetingPipeline: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case processing
        case error(String)
    }

    @Published private(set) var state: State = .idle {
        didSet {
            if oldValue != state {
                log.info(
                    "Meeting state: \(String(describing: oldValue), privacy: .public) -> \(String(describing: self.state), privacy: .public)"
                )
            }
        }
    }

    private let recorder = AudioRecorder()
    // Type-erased so this class still builds against the macOS 14.0
    // deployment target (SystemAudioCapture needs 14.2+). nil = mic-only.
    private var systemCapture: AnyObject?
    private let parakeet: ParakeetEngine
    private let diarizer = Diarizer()
    private let hud: RecordingHUD
    private let summarizer: MeetingSummarizer
    private var elapsedTimer: Timer?
    private var levelTask: Task<Void, Never>?
    private var systemLevelTask: Task<Void, Never>?
    // Latest system-audio RMS, blended into the HUD waveform so it reacts to
    // remote sound too; decays each mic tick since a silent tap stops
    // delivering buffers.
    private var latestSystemLevel: Float = 0
    // A stopped meeting's audio until its transcript or the audio itself is
    // on disk, so a quit meanwhile can still save it.
    private var untranscribed: (mic: [Float], system: [Float])?
    // Writes a meeting's audio, with or without its transcript. Serial, so a
    // quit can wait out a write already running.
    private let audioQueue = DispatchQueue(label: "com.arunbrahma.purr.meeting-audio")
    private var savingUntranscribed = false
    private var summarizing = false

    private static let systemLevelDecay: Float = 0.8
    // How long a meeting waits for its model to load or download: far longer
    // than dictation, since giving up costs the meeting its transcript, but a
    // stuck load or a crawling download can't hold the meeting, and the
    // dictation it pauses, forever.
    private static let modelLoadLimit: Duration = .seconds(600)

    // FluidAudio's offline diarizer runs at over 100x real time, so this
    // gives a slow Mac 10x, plus time to load its models. Past it, the
    // meeting is saved without speaker labels rather than held.
    private static func diarizationLimit(samples: Int) -> Duration {
        modelLoadTimeout + .seconds(Double(samples) / 16_000 / 10)
    }

    private let log = Logger(subsystem: "com.arunbrahma.purr", category: "meeting")

    init(parakeet: ParakeetEngine, hud: RecordingHUD, summarizer: MeetingSummarizer) {
        self.parakeet = parakeet
        self.hud = hud
        self.summarizer = summarizer
    }

    func unloadDiarizer() {
        diarizer.unload()
    }

    func downloadDiarizer() async throws {
        try await diarizer.downloadAndWarmup()
    }

    // Where a meeting is, for the quit alert: Quit Anyway saves the audio of
    // one recording or transcribing, and skips the summary of one whose
    // transcript is saved.
    enum QuitStage {
        case recording, transcribing, summarizing
    }

    var quitStage: QuitStage? {
        if case .recording = state { return .recording }
        // From stop until the transcript or the audio is on disk.
        if untranscribed != nil || savingUntranscribed { return .transcribing }
        return summarizing ? .summarizing : nil
    }

    // Every quit ends here. Quit Anyway keeps the audio of a meeting still
    // recording or waiting on its transcript, as a failure does, and audio
    // still being written is waited out. Blocks until it's on disk, since the
    // app exits right after.
    func saveAudioBeforeQuit() {
        if case .recording = state {
            let mic = recorder.stop()
            let system = stopSystemCapture(micStartHostTime: recorder.captureStartHostTime).samples
            // Under 2 s is a stray tap, as in stop().
            if mic.count >= 16_000 * 2 { untranscribed = (mic, system) }
        }
        let meeting = untranscribed
        untranscribed = nil
        let folder = MeetingDocument.meetingsDirectory()
        audioQueue.sync {
            if let meeting { _ = writeUntranscribedAudio(meeting, folder: folder) }
        }
    }

    // .recording excluded - a press then is the *stop* gesture, not busy.
    private var meetingBusy: Bool {
        if case .processing = state { return true }
        return false
    }

    func toggle() {
        if hud.shouldIgnorePress(whileBusy: meetingBusy) { return }
        switch state {
        case .idle, .error:
            start()
        case .recording:
            Task { await stop() }
        case .processing:
            break  // never interrupt the merge pass
        }
    }

    private func start() {
        do {
            try recorder.start()
            startSystemCapture()
            state = .recording(startedAt: Date())
            // The recording pill is opt-out (Settings → Meetings). When hidden
            // the meeting still records; the menu bar carries the indicator.
            if SettingsStore.shared.showMeetingHUD {
                hud.show(.meeting(elapsed: 0))
                startElapsedTimer()
            }
            startLevelTask()
        } catch {
            log.error("Meeting recorder failed to start: \(error.localizedDescription, privacy: .public)")
            state = .error("Could not start microphone: \(error.localizedDescription)")
            hud.showMessage(
                HUDErrorText.message(for: error) ?? "Could not start the microphone. Try again.",
                autoHideAfter: 4)
        }
    }

    // Best-effort: a failure here just means no remote participants captured.
    private func startSystemCapture() {
        guard #available(macOS 14.2, *) else { return }
        let capture = SystemAudioCapture()
        do {
            try capture.start()
            systemCapture = capture
        } catch {
            log.error(
                "System audio capture failed to start: \(error.localizedDescription, privacy: .public)"
            )
            systemCapture = nil
        }
    }

    // Empty result when system audio was never running.
    private func stopSystemCapture(
        micStartHostTime: UInt64
    ) -> (
        samples: [Float], silentButActive: Bool
    ) {
        defer { systemCapture = nil }
        guard #available(macOS 14.2, *),
            let capture = systemCapture as? SystemAudioCapture
        else { return ([], false) }
        let captured = capture.stop(alignedTo: micStartHostTime)
        return (captured, capture.lastCaptureSilentButActive)
    }

    // One-time notice for a silent tap: output was active but System Audio
    // Recording permission was off, so the tap delivered only zeros.
    private func maybeShowSystemAudioNotice(silentButActive: Bool) {
        guard silentButActive, !SettingsStore.shared.systemAudioNoticeShown else { return }
        let alert = NSAlert()
        alert.messageText = "System audio wasn't captured"
        alert.informativeText =
            "This meeting saved your microphone only. To include remote voices, allow Purr under System Settings → Privacy & Security → Screen & System Audio Recording, then record again."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        // Bring Purr forward first - as a menu-bar accessory app, the alert
        // would otherwise open behind whatever's frontmost.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        // Set the flag only after the alert is dismissed, so a notice the
        // user never saw can't disable itself.
        SettingsStore.shared.systemAudioNoticeShown = true
        if response == .alertFirstButtonReturn {
            Permissions.openSystemAudioSettings()
        }
    }

    private func stop() async {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        levelTask?.cancel()
        levelTask = nil
        systemLevelTask?.cancel()
        systemLevelTask = nil
        latestSystemLevel = 0
        let samples = recorder.stop()
        // Align to the mic's continuous timeline - the tap omits silent gaps,
        // so its raw timestamps don't share the mic's clock origin.
        let systemCaptureResult = stopSystemCapture(micStartHostTime: recorder.captureStartHostTime)
        let systemSamples = systemCaptureResult.samples
        guard samples.count >= 16_000 * 2 else {
            state = .idle  // <2s is almost always an accidental tap
            hud.hide()
            return
        }
        state = .processing
        untranscribed = (samples, systemSamples)
        // Waiting on the model is its own HUD step, as for dictation.
        let loadStep = meetingModelLoadStep
        hud.show(loadStep ?? .transcribing)

        do {
            if let loadStep {
                try await loadMeetingModel(downloading: loadStep == .downloadingModel)
                hud.show(.transcribing)
            }
            let processingStarted = Date()
            log.info(
                "Meeting processing: \(samples.count, privacy: .public) mic samples + \(systemSamples.count, privacy: .public) system samples (~\(String(format: "%.2f", Double(samples.count) / 16_000.0), privacy: .public)s)"
            )
            let duration = TimeInterval(samples.count) / 16_000.0
            let document: MeetingDocument.Output
            let audioLocalSamples: [Float]
            let audioRemoteSamples: [Float]?
            if systemSamples.isEmpty {
                // Mic-only: no diarization, since a single track can't
                // reliably separate in-room speakers - every utterance is "You".
                let asr = try await transcribeMeetingAudio(samples: samples)
                logASRResult(asr, track: "mic")
                log.info(
                    "Meeting transcribe complete in \(String(format: "%.2f", Date().timeIntervalSince(processingStarted)), privacy: .public)s: \(asr.tokenTimings?.count ?? 0, privacy: .public) tokens, single local speaker (You)"
                )
                document = MeetingDocument.format(
                    localOnly: asr,
                    engine: meetingModelName,
                    duration: duration,
                    recordedAt: Date()
                )
                audioLocalSamples = samples
                audioRemoteSamples = nil
            } else {
                // System audio carries the remote participants (diarized into
                // Speaker N); echo-cancelled mic carries the local user (You).
                // The two Parakeet passes share one AsrManager, so they run
                // sequentially; diarization runs concurrently with them.
                let cleanedMic = await Task.detached {
                    EchoCanceller.process(mic: samples, reference: systemSamples)
                }.value
                let diarize: @Sendable () async throws -> [TimedSpeakerSegment] = { [diarizer] in
                    try await diarizer.diarize(samples: systemSamples)
                }
                async let remoteSegmentsTask = withTimeout(
                    Self.diarizationLimit(samples: systemSamples.count), operation: diarize)
                let remoteASR = try await transcribeMeetingAudio(samples: systemSamples)
                let localASR = try await transcribeMeetingAudio(samples: cleanedMic)
                // A diarization failure (no remote speech, music, silence)
                // must not sink the meeting - keep both transcripts, remote
                // just won't carry Speaker N labels.
                let remoteSegments: [TimedSpeakerSegment]
                do {
                    remoteSegments = try await remoteSegmentsTask
                } catch is TimedOutError {
                    log.error(
                        "Meeting diarization ran past its limit - saving transcripts without remote speaker labels."
                    )
                    remoteSegments = []
                } catch {
                    log.error(
                        "Meeting diarization failed on the system track (\(error.localizedDescription, privacy: .public)) - saving transcripts without remote speaker labels."
                    )
                    remoteSegments = []
                }
                log.info(
                    "Meeting dual-track complete in \(String(format: "%.2f", Date().timeIntervalSince(processingStarted)), privacy: .public)s: local \(localASR.tokenTimings?.count ?? 0, privacy: .public) tokens, remote \(remoteASR.tokenTimings?.count ?? 0, privacy: .public) tokens, \(remoteSegments.count, privacy: .public) speaker segments"
                )
                document = MeetingDocument.format(
                    localASR: localASR,
                    remoteASR: remoteASR,
                    remoteSegments: remoteSegments,
                    cancellation: {
                        EchoCanceller.cancellation(
                            mic: samples, cleaned: cleanedMic, reference: systemSamples,
                            from: $0, to: $1)
                    },
                    engine: meetingModelName,
                    duration: duration,
                    recordedAt: Date()
                )
                // Echo-cancelled, not raw - the same audio the local ASR pass
                // transcribed, so the sidecar matches what "You" actually heard.
                audioLocalSamples = cleanedMic
                audioRemoteSamples = systemSamples
            }
            let url = try MeetingDocument.write(document)
            untranscribed = nil
            log.info("Meeting saved → \(url.path, privacy: .public)")

            // A failure here must not sink the meeting - the transcript already
            // saved - so it's logged rather than thrown. On the audio queue,
            // since encoding is pure CPU work: the meeting moves on meanwhile,
            // and a quit waits for the file rather than cutting it short.
            if SettingsStore.shared.saveMeetingAudio {
                audioQueue.async { [log] in
                    do {
                        let audioURL = try MeetingDocument.writeAudio(
                            localSamples: audioLocalSamples, remoteSamples: audioRemoteSamples,
                            alongside: url)
                        log.info("Meeting audio saved → \(audioURL.path, privacy: .public)")
                    } catch {
                        log.error(
                            "Meeting audio save failed: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }

            // Reveal the best file in Finder - summary if it exists, else transcript.
            let summary = await runSummaryIfEnabled(transcriptURL: url)
            switch summary {
            case .produced(let sidecarURL):
                NSWorkspace.shared.activateFileViewerSelecting([sidecarURL])
                hud.hide()
            case .skipped:
                NSWorkspace.shared.activateFileViewerSelecting([url])
                hud.hide()
            case .failed:
                // Don't hide - the HUD's auto-hiding failure message would be cut off.
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            maybeShowSystemAudioNotice(silentButActive: systemCaptureResult.silentButActive)
            state = .idle
        } catch {
            log.error("Meeting pipeline failed: \(error.localizedDescription, privacy: .public)")
            // Saved while still .processing, so a press can't start the next
            // meeting meanwhile.
            let audioURL = await saveAudioOfUntranscribedMeeting()
            state = .error(error.localizedDescription)
            let mapped = HUDErrorText.message(for: error)
            if let audioURL {
                if case EngineError.meetingModelLoadTimedOut(downloading: true) = error {
                    // Not an error to act on: the download carries on, and
                    // Finder shows the saved audio.
                    hud.showMessage("Still downloading model", icon: .downloadingModel, autoHideAfter: 4)
                } else {
                    hud.showMessage(
                        (mapped ?? "Couldn't transcribe this meeting.") + " Its audio was saved.", autoHideAfter: 4)
                }
                NSWorkspace.shared.activateFileViewerSelecting([audioURL])
            } else {
                hud.showMessage(mapped ?? "Meeting processing failed. Try again.", autoHideAfter: 4)
            }
            try? await Task.sleep(for: .seconds(4))
            state = .idle
        }
    }

    // Nothing is on disk until a transcript is, so a meeting without one keeps
    // its audio, with Keep audio on or off: it's the only copy. The mic track
    // is the raw recording: the echo-cancelled copy is local to the pass that
    // failed.
    private func saveAudioOfUntranscribedMeeting() async -> URL? {
        guard let meeting = untranscribed else { return nil }
        untranscribed = nil
        savingUntranscribed = true
        defer { savingUntranscribed = false }
        let folder = MeetingDocument.meetingsDirectory()
        return await withCheckedContinuation { continuation in
            audioQueue.async {
                continuation.resume(returning: self.writeUntranscribedAudio(meeting, folder: folder))
            }
        }
    }

    // Off the main actor, since encoding is pure CPU work.
    private nonisolated func writeUntranscribedAudio(
        _ meeting: (mic: [Float], system: [Float]), folder: URL
    ) -> URL? {
        do {
            let url = try MeetingDocument.writeAudio(
                localSamples: meeting.mic, remoteSamples: meeting.system, recordedAt: Date(), folder: folder)
            log.info("Meeting audio saved without a transcript → \(url.path, privacy: .public)")
            return url
        } catch {
            log.error("Meeting audio save failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // The transcript is already on disk by the time this runs, so `.failed`
    // is non-fatal - the reason just goes on the HUD instead of being silent.
    private enum SummaryOutcome {
        case produced(URL)
        case skipped
        case failed
    }

    private func runSummaryIfEnabled(transcriptURL: URL) async -> SummaryOutcome {
        guard SettingsStore.shared.summarizeMeetings else {
            log.info("Summary skipped: auto-summarize toggle is off.")
            return .skipped
        }
        let backend = MeetingSummarizer.currentBackend()
        log.info("Summary backend resolved: \(String(describing: backend), privacy: .public)")
        guard MeetingSummarizer.canSummarizeNow else {
            log.info("Summary skipped: no backend available (Apple FM off + Gemma not installed).")
            return .skipped
        }
        hud.show(.summarizing)
        summarizing = true
        defer { summarizing = false }
        let started = Date()
        do {
            let url = try await summarizer.summarize(transcriptURL: transcriptURL)
            let elapsed = Date().timeIntervalSince(started)
            log.info(
                "Summary saved in \(String(format: "%.2f", elapsed), privacy: .public)s → \(url.path, privacy: .public)"
            )
            return .produced(url)
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            log.error(
                "Meeting summary failed after \(String(format: "%.2f", elapsed), privacy: .public)s: \(error.localizedDescription, privacy: .public)"
            )
            // The transcript saved fine - a silently missing summary leaves
            // the user guessing, so put the reason on the HUD briefly.
            hud.showMessage(Self.summaryFailureMessage(error), autoHideAfter: 4)
            return .failed
        }
    }

    // Generic HUD copy for cases with a raw underlying error (full detail is
    // already logged); cases with their own actionable text pass through as-is.
    private static func summaryFailureMessage(_ error: Error) -> String {
        let generic = "Meeting summary failed. Your transcript was saved."
        guard let summarizerError = error as? MeetingSummarizer.SummarizerError else {
            return generic
        }
        switch summarizerError {
        case .backendUnavailable:
            return "Meeting summaries need an AI model. Set one up in Settings → Meetings."
        case .unsupportedLocale:
            return summarizerError.errorDescription ?? generic
        case .contentFlagged(let reason):
            return "Summary failed: \"\(reason)\""
        case .modelLoadFailed, .emptyResponse, .generationFailed:
            return generic
        }
    }

    // Routes to Parakeet v2 (English default) or v3 (multilingual) per
    // Settings' meeting language - dictation and voice-edit never see this.
    private func transcribeMeetingAudio(samples: [Float]) async throws -> ASRResult {
        guard let language = ParakeetLanguage.named(SettingsStore.shared.meetingLanguage).fluidAudioLanguage
        else {
            return try await parakeet.transcribeDetailed(samples: samples)
        }
        return try await parakeet.transcribeMeeting(samples: samples, language: language)
    }

    // The HUD step for loading the model transcribeMeetingAudio routes to, or
    // nil when it's loaded.
    private var meetingModelLoadStep: RecordingHUD.Mode? {
        if ParakeetLanguage.named(SettingsStore.shared.meetingLanguage).fluidAudioLanguage == nil {
            if parakeet.isLoaded { return nil }
            return parakeet.needsDownload ? .downloadingModel : .loadingModel
        }
        if parakeet.isMeetingModelLoaded { return nil }
        return ParakeetEngine.meetingModelIsInstalled() ? .loadingModel : .downloadingModel
    }

    // Loads that model, downloading it first if needed, within modelLoadLimit.
    // Past it this throws, and the load carries on in the background for the
    // next meeting.
    private func loadMeetingModel(downloading: Bool) async throws {
        let english = ParakeetLanguage.named(SettingsStore.shared.meetingLanguage).fluidAudioLanguage == nil
        let load: @Sendable () async throws -> Void = { [parakeet] in
            if english {
                try await parakeet.downloadAndLoadBatchManager()
            } else {
                try await parakeet.downloadAndLoadMeetingManager()
            }
        }
        do {
            try await withTimeout(Self.modelLoadLimit, operation: load)
        } catch is TimedOutError {
            log.error(
                "Gave up waiting for \(self.meetingModelName, privacy: .public) to \(downloading ? "download" : "load", privacy: .public). It carries on in the background."
            )
            throw EngineError.meetingModelLoadTimedOut(downloading: downloading)
        }
    }

    // The model transcribeMeetingAudio routes to, for the document header.
    private var meetingModelName: String {
        ParakeetLanguage.named(SettingsStore.shared.meetingLanguage).fluidAudioLanguage == nil
            ? "Parakeet TDT v2" : "Parakeet TDT v3"
    }

    // Surfaces counts/confidence for diagnosing "no speech detected" without
    // copying transcript content into unified logs.
    private func logASRResult(_ asr: ASRResult, track: String) {
        let trimmed = asr.text.trimmingCharacters(in: .whitespacesAndNewlines)
        log.info(
            "ASR[\(track, privacy: .public)]: \(asr.text.count, privacy: .public) chars, \(asr.tokenTimings?.count ?? 0, privacy: .public) tokens, confidence \(String(format: "%.2f", asr.confidence), privacy: .public), audio \(String(format: "%.2f", asr.duration), privacy: .public)s, empty \(trimmed.isEmpty, privacy: .public)"
        )
    }

    private func startElapsedTimer() {
        guard case .recording(let startedAt) = state else { return }
        // .common runloop mode so the timer keeps firing during window
        // drags/menus/mouse-down, which would pause the default mode.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, case .recording = self.state else { return }
                let now = Date().timeIntervalSince(startedAt)
                // update(_:), not show(_:) - the latter also
                // reorders/repositions, firing a SwiftUI publishing warning.
                self.hud.update(.meeting(elapsed: now))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func startLevelTask() {
        // Blends system-audio RMS into the mic level so the waveform reacts
        // to remote sound too. Streams are drained even when the pill is
        // hidden, so they don't buffer unboundedly over a long meeting.
        let feedsHUD = SettingsStore.shared.showMeetingHUD
        levelTask = Task { [weak self] in
            guard let self else { return }
            for await level in self.recorder.levels {
                if Task.isCancelled { break }
                // Fade toward rest so a silent tap doesn't pin the last loud value.
                self.latestSystemLevel *= Self.systemLevelDecay
                if feedsHUD { self.hud.updateLevel(max(level, self.latestSystemLevel)) }
            }
        }
        startSystemLevelTask()
    }

    // No-op when system capture is unavailable or didn't start.
    private func startSystemLevelTask() {
        guard #available(macOS 14.2, *), let capture = systemCapture as? SystemAudioCapture else {
            return
        }
        systemLevelTask = Task { [weak self] in
            for await level in capture.levels {
                if Task.isCancelled { break }
                self?.latestSystemLevel = level
            }
        }
    }
}
