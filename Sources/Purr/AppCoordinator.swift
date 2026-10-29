import AppKit
import Combine
import Foundation
import os.log

// Central orchestrator, owning the audio + engine + insertion pipeline.
// Three flows, all driven by the multi-binding HotkeyManager:
//
// * **Dictation** - record while held, on release run batch transcribe +
//   paste or EOU streaming + live typing (`shouldStreamThisRecording()`).
// * **Meeting** - tap-to-toggle long-form recording with offline diarize
//   on stop, written to Markdown. Lives in `MeetingPipeline`.
// * **Voice edit** - hold while text is selected; speech is parsed as an
//   edit instruction and applied via Accessibility. Lives in `VoiceEditor`.
//
// Dictation is suspended at the hotkey layer while a meeting records, so a
// reflex press can't insert a transcript over meeting notes.
@MainActor
final class AppCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
    }

    // Folds the three independent flows into one signal for the status item.
    enum MenuBarStatus: Equatable {
        case idle
        case recording
        case transcribing
        case meeting
        case error(String)
    }

    enum DiarizerDeleteResult {
        case ok
        case busy
        case failed(Error)
    }

    enum ModelDownloadResult {
        case ok
        case failed(Error)
    }

    enum DeleteAllModelsResult {
        case ok
        case busy
        case failed(Error)
    }

    enum UninstallResult {
        case ok
        case busy
        case failed(Error)
    }

    @Published private(set) var state: State = .idle {
        didSet {
            if oldValue != state {  // avoid spamming the log on a re-asserted state
                log.info(
                    "State: \(String(describing: oldValue), privacy: .public) -> \(String(describing: self.state), privacy: .public)"
                )
            }
            refreshSafeToQuit()
            refreshMenuBarStatus()
        }
    }

    // Lets SwiftUI (the updater UI) disable destructive actions mid-recording.
    @Published private(set) var safeToQuit: Bool = true

    @Published private(set) var menuBarStatus: MenuBarStatus = .idle

    // Non-nil while downloading - drives Settings' model rows for both an
    // automatic warmup download and a manual Download tap.
    @Published private(set) var parakeetBatchProgress: ModelDownloadProgress?
    @Published private(set) var eouDownloadProgress: ModelDownloadProgress?
    // Unlike the other two, this one never auto-downloads during warmup.
    @Published private(set) var meetingLanguageModelProgress: ModelDownloadProgress?

    // Feeds menuBarStatus - a meeting outranks dictation/voice-edit for the glyph.
    private var meetingActive = false

    // Mirrors voiceEditor.state from the emitted value, not read live: inside
    // its own sink, @Published's willSet means the property still holds the
    // *previous* value, which would leave the glyph a step behind.
    private var voiceEditState: VoiceEditor.State = .idle

    private let recorder = AudioRecorder()
    private let inserter = TextInserter()
    private let hud = RecordingHUD()
    private let hotkey = HotkeyManager()

    // Shortcuts dead right now: Secure Input is on and the Carbon fallback
    // couldn't take them over. Read by the menu bar on each open.
    var shortcutsBlockedBySecureInput: [String] { hotkey.secureInputGaps }

    // Rebuilt on Settings engine switch; only one lives at a time so both
    // ~1GB pipes are never loaded together.
    private var engine: any TranscriptionEngine = ParakeetEngine()
    private var parakeet = ParakeetEngine()
    private let summarizer = MeetingSummarizer.shared
    private var meeting: MeetingPipeline!
    private var voiceEditor: VoiceEditor!
    private var meetingObserver: AnyCancellable?
    private var voiceEditObserver: AnyCancellable?
    private var accessibilityObserver: NSObjectProtocol?

    private var levelTask: Task<Void, Never>?
    // Lets a genuine mic-still-waking failure be told apart from a quick
    // accidental tap.
    private var recordingStartedAt: Date?
    private var streamingTask: Task<Void, Never>?
    private var streamingSession: (any StreamingSession)?
    // Owned here, not nested in streamingTask, so finishStreamingRecording()
    // can await it - draining every buffered chunk - before calling finish().
    private var feedTask: Task<Void, Never>?
    // A streaming session needs an `await` to load, during which the user may
    // already release the hotkey - tracked here so setup can bail cleanly.
    private var streamingStartupInFlight = false
    private var releasedDuringStartup = false

    // Lets the global quit hotkey drive the same path as the status-bar item.
    private var onQuit: (() -> Void)?

    private let log = Logger(subsystem: "com.arunbrahma.purr", category: "coordinator")
    // Own category so the per-utterance flow reads without state-transition noise.
    private let postLog = Logger(subsystem: "com.arunbrahma.purr", category: "postprocess")

    func setMenuActions(quit: @escaping () -> Void) {
        self.onQuit = quit
    }

    func start() {
        rebuildEngine(initial: true)

        parakeet.batchDownload.onChange = { [weak self] progress in
            self?.parakeetBatchProgress = progress
        }
        parakeet.eouDownload.onChange = { [weak self] progress in
            self?.eouDownloadProgress = progress
        }
        parakeet.meetingBatchDownload.onChange = { [weak self] progress in
            self?.meetingLanguageModelProgress = progress
        }

        // A stale "on" without the EOU model on disk (an older build, or EOU
        // removed) gets turned off rather than silently pulling ~440MB.
        if SettingsStore.shared.smartTyping, !ParakeetEngine.eouIsInstalled() {
            SettingsStore.shared.smartTyping = false
        }

        // Off the main actor: the first launch after the Gemma 4 switch
        // removes the 2.5 GB Gemma 3 file.
        Task.detached(priority: .utility) { LLMModelManager.removeLegacyModels() }

        // The recorder self-skips warming on Bluetooth to avoid pinning SCO mode.
        recorder.allowsWarmKeeping = true
        // Off the main actor: on a cold system this takes ~2 s, which the first
        // dictation would otherwise wait on.
        Task.detached(priority: .userInitiated) { AudioRecorder.prepareForFirstStart() }

        meeting = MeetingPipeline(parakeet: parakeet, hud: hud, summarizer: summarizer)
        voiceEditor = VoiceEditor(hud: hud) { [weak self] in
            self?.engine ?? ParakeetEngine()
        }

        meetingObserver = meeting.$state.sink { [weak self] state in
            guard let self else { return }
            switch state {
            case .recording, .processing:
                self.hotkey.suspendDictation(true)
                self.meetingActive = true
            case .idle, .error:
                self.hotkey.suspendDictation(false)
                self.meetingActive = false
            }
            self.refreshSafeToQuit()
            self.refreshMenuBarStatus()
        }

        // Voice edit drives the HUD directly and never touches `state` -
        // mirror its activity into the glyph, or the menu bar would miss it.
        voiceEditObserver = voiceEditor.$state.sink { [weak self] newState in
            guard let self else { return }
            self.voiceEditState = newState
            self.refreshMenuBarStatus()
        }

        installHotkeys()
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: Permissions.accessibilityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // The trust read can trail the notification by a moment.
                try? await Task.sleep(for: .milliseconds(500))
                self?.installHotkeysIfNeeded()
            }
        }

        // Eager, so the first press pays no load cost - except before setup,
        // whose engine step decides which model gets downloaded.
        if SettingsStore.shared.onboardingDone {
            Task { await engine.warmup() }
        }
    }

    func reloadEngine() {
        rebuildEngine(initial: false)
        Task { await engine.warmup() }
    }

    func reinstallHotkey() {
        installHotkeys()
    }

    // The hotkey tap can't exist until Accessibility is on, so one that failed
    // is retried when macOS reports the switch changed, and when the
    // permission rows see the grant themselves.
    func installHotkeysIfNeeded() {
        guard !hotkey.isInstalled, Permissions.isGranted(.accessibility) else { return }
        installHotkeys()
    }

    @discardableResult
    func deleteDiarizationModel() -> DiarizerDeleteResult {
        switch meeting.state {
        case .recording, .processing: return .busy
        case .idle, .error: break
        }
        meeting.unloadDiarizer()
        do {
            try Diarizer.delete()
        } catch {
            return .failed(error)
        }
        SettingsStore.shared.meetingEnabled = false
        installHotkeys()
        log.info("Diarizer delete: on-disk removed; meetingEnabled flipped off.")
        return .ok
    }

    func downloadDiarizationModel() async -> ModelDownloadResult {
        do {
            try await meeting.downloadDiarizer()
            return .ok
        } catch {
            return .failed(error)
        }
    }

    func downloadEOUModel() async -> ModelDownloadResult {
        do {
            try await parakeet.downloadAndLoadStreamingManager()
            return .ok
        } catch {
            return .failed(error)
        }
    }

    func downloadParakeetModel() async -> ModelDownloadResult {
        do {
            try await parakeet.downloadAndLoadBatchManager()
            return .ok
        } catch {
            return .failed(error)
        }
    }

    // v2 backs dictation, meetings, and voice editing - refuse while any is
    // mid-flight rather than unloading it out from under a running utterance.
    @discardableResult
    func deleteParakeetModel() -> DiarizerDeleteResult {
        switch state {
        case .recording, .transcribing: return .busy
        case .idle, .error: break
        }
        if streamingSession != nil || streamingStartupInFlight { return .busy }
        if parakeetBatchProgress != nil { return .busy }
        switch meeting.state {
        case .recording, .processing: return .busy
        case .idle, .error: break
        }
        if voiceEditState != .idle { return .busy }
        parakeet.unloadBatchManager()
        do {
            try ParakeetEngine.batchDelete()
        } catch {
            return .failed(error)
        }
        log.info("Parakeet TDT batch deleted on user request.")
        return .ok
    }

    @discardableResult
    func deleteEOUModel() -> DiarizerDeleteResult {
        if streamingSession != nil { return .busy }
        if streamingStartupInFlight { return .busy }
        parakeet.unloadStreamingManager()
        do {
            try ParakeetEngine.eouDelete()
        } catch {
            return .failed(error)
        }
        SettingsStore.shared.smartTyping = false
        log.info("EOU delete: on-disk removed; smartTyping flipped off.")
        return .ok
    }

    func downloadMeetingLanguageModel() async -> ModelDownloadResult {
        do {
            try await parakeet.downloadAndLoadMeetingManager()
            return .ok
        } catch {
            return .failed(error)
        }
    }

    // Doesn't touch meetingLanguage - a language pointed at a now-deleted
    // model just re-downloads it on the next meeting.
    @discardableResult
    func deleteMeetingLanguageModel() -> DiarizerDeleteResult {
        switch meeting.state {
        case .recording, .processing: return .busy
        case .idle, .error: break
        }
        if meetingLanguageModelProgress != nil { return .busy }
        parakeet.unloadMeetingManager()
        do {
            try ParakeetEngine.meetingModelDelete()
        } catch {
            return .failed(error)
        }
        log.info("Parakeet TDT v3 (meeting) deleted on user request.")
        return .ok
    }

    // Wipes every downloaded model. Releases in-memory handles first, then
    // removes on-disk weights, then turns off features whose model is gone.
    // Meeting transcripts and preferences are left untouched.
    @discardableResult
    func deleteAllModels() async -> DeleteAllModelsResult {
        guard await releaseModelsIfIdle() else { return .busy }

        do {
            try ModelManager.deleteAllModels()
        } catch {
            log.error("Delete all models failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error)
        }

        // Auto-summarize keeps working via Apple's built-in model (no
        // download needed); fall back to off only when no backend is left.
        let s = SettingsStore.shared
        s.smartTyping = false
        s.meetingEnabled = false
        let appleFallbackUsable: Bool
        if #available(macOS 26.0, *) {
            appleFallbackUsable = MeetingSummarizer.appleFoundationAvailable
        } else {
            appleFallbackUsable = false
        }
        if appleFallbackUsable {
            s.summaryBackend = .appleFoundation
        } else {
            s.summarizeMeetings = false
        }

        // No warmup here - that would immediately re-download.
        rebuildEngine(initial: false)
        installHotkeys()
        log.info("All models deleted; dependent features turned off.")
        return .ok
    }

    // Settings › General › Uninstall. On .ok the caller quits straight away:
    // Purr's files are in the Trash, its permissions are reset, and the
    // cleanup helper is waiting for this process to exit.
    func uninstall() async -> UninstallResult {
        guard await releaseModelsIfIdle() else { return .busy }
        do {
            try Uninstaller.run()
            return .ok
        } catch {
            log.error("Uninstall failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error)
        }
    }

    // Shared by deleteAllModels and uninstall: refuses while anything records,
    // transcribes or downloads, then unloads every model so no deleted file
    // stays mmap'd behind a live handle.
    private func releaseModelsIfIdle() async -> Bool {
        guard isIdle() else { return false }
        await summarizer.unload()
        // A hotkey can start a recording while unload() awaits.
        guard isIdle() else { return false }
        meeting.unloadDiarizer()
        parakeet.unloadStreamingManager()
        parakeet.unloadBatchManager()
        parakeet.unloadMeetingManager()
        return true
    }

    private func isIdle() -> Bool {
        guard canQuitSafely() else { return false }
        if streamingSession != nil || streamingStartupInFlight { return false }
        if voiceEditState != .idle { return false }
        if parakeetBatchProgress != nil || eouDownloadProgress != nil { return false }
        return meetingLanguageModelProgress == nil
    }

    private func rebuildEngine(initial: Bool) {
        let chosen = SettingsStore.shared.engine
        switch chosen {
        case .parakeet:
            engine = parakeet
        case .whisper:
            engine = WhisperEngine(modelName: SettingsStore.shared.modelName)
        }
        if !initial {
            log.info("Engine switched to \(chosen.rawValue, privacy: .public)")
        }
    }

    private func installHotkeys() {
        let s = SettingsStore.shared
        var bindings: [HotkeyManager.Binding] = [
            .init(
                action: .transcribe,
                hotkey: s.hotkey,
                onPress: { [weak self] in self?.handleTranscribePress() },
                onRelease: { [weak self] in self?.handleTranscribeRelease() }
            )
        ]
        if s.meetingEnabled {
            bindings.append(
                .init(
                    action: .meetingToggle,
                    hotkey: s.meetingHotkey,
                    onPress: { [weak self] in self?.meeting.toggle() },
                    onRelease: { /* tap-only; release is a no-op */  }
                ))
        }
        if s.voiceEditEnabled {
            bindings.append(
                .init(
                    action: .voiceEdit,
                    hotkey: s.voiceEditHotkey,
                    onPress: { [weak self] in self?.voiceEditor.handlePress() },
                    onRelease: { [weak self] in self?.voiceEditor.handleRelease() }
                ))
        }
        // Hardcoded, always-on, gated on canQuitSafely(). Settings lives in
        // the menu bar dropdown only - no global shortcut.
        bindings.append(
            .init(
                action: .quit,
                hotkey: .quitApp,
                onPress: { [weak self] in self?.handleQuitHotkey() },
                onRelease: {}
            ))
        hotkey.setBindings(bindings)
        hotkey.install()
    }

    private func handleQuitHotkey() {
        guard canQuitSafely() else {
            log.info(
                "Quit hotkey ignored: in-progress state=\(String(describing: self.state), privacy: .public)"
            )
            return
        }
        onQuit?()
    }

    private func canQuitSafely() -> Bool {
        switch state {
        case .recording, .transcribing: return false
        case .idle, .error: break
        }
        if let meeting = meeting {
            switch meeting.state {
            case .recording, .processing: return false
            case .idle, .error: break
            }
        }
        return true
    }

    private func refreshSafeToQuit() {
        let next = canQuitSafely()
        if safeToQuit != next { safeToQuit = next }
    }

    private func refreshMenuBarStatus() {
        let next = computeMenuBarStatus()
        if menuBarStatus != next { menuBarStatus = next }
    }

    // Meeting outranks the per-press flows. Dictation is checked before
    // voice-edit only because it's the common path - the two don't run at once.
    private func computeMenuBarStatus() -> MenuBarStatus {
        if meetingActive { return .meeting }
        switch state {
        case .error(let message): return .error(message)
        case .transcribing: return .transcribing
        case .recording: return .recording
        case .idle:
            switch voiceEditState {
            case .transcribing: return .transcribing
            case .recording: return .recording
            case .idle: return .idle
            }
        }
    }

    // ------------------------------------------------------------------
    // Dictation hotkey lifecycle
    // ------------------------------------------------------------------

    // .recording excluded: a press then is the toggle-mode stop gesture, and
    // a hold-to-talk re-press is already a no-op in beginRecording().
    private var dictationBusy: Bool {
        if streamingStartupInFlight { return true }
        if case .transcribing = state { return true }
        return false
    }

    private func handleTranscribePress() {
        if hud.shouldIgnorePress(whileBusy: dictationBusy) {
            log.info("Transcribe press ignored: HUD message up or transcription in flight.")
            return
        }
        log.info(
            "Transcribe press received (state=\(String(describing: self.state), privacy: .public), mode=\(SettingsStore.shared.hotkeyMode.rawValue, privacy: .public))"
        )
        switch SettingsStore.shared.hotkeyMode {
        case .holdToTalk:
            beginRecording()
        case .toggle:
            switch state {
            case .idle, .error: beginRecording()
            case .recording: Task { await finishRecording() }
            case .transcribing: break
            }
        }
    }

    private func handleTranscribeRelease() {
        log.info(
            "Transcribe release received (state=\(String(describing: self.state), privacy: .public), startupInFlight=\(self.streamingStartupInFlight, privacy: .public))"
        )
        guard SettingsStore.shared.hotkeyMode == .holdToTalk else { return }
        if state == .recording {
            Task { await finishRecording() }
        } else if streamingStartupInFlight {
            // Let go before the session finished loading - mark it so setup
            // tears down cleanly instead of starting an abandoned recording.
            releasedDuringStartup = true
        }
    }

    private func shouldStreamThisRecording() -> Bool {
        SettingsStore.shared.autoPaste
            && SettingsStore.shared.smartTyping
            && engine.supportsStreaming
    }

    private func beginRecording() {
        switch state {
        case .recording, .transcribing: return
        case .idle, .error: break
        }
        // Refuse while starting up, so a second press can't kick off a
        // parallel setup Task and leave an orphaned session behind.
        if streamingStartupInFlight { return }

        if shouldStreamThisRecording() {
            beginStreamingRecording()
        } else {
            beginBatchRecording()
        }
    }

    private func finishRecording() async {
        if streamingSession != nil {
            await finishStreamingRecording()
        } else {
            await finishBatchRecording()
        }
    }

    // ------------------------------------------------------------------
    // Batch flow
    // ------------------------------------------------------------------

    private func beginBatchRecording() {
        do {
            try recorder.start()
            state = .recording
            recordingStartedAt = Date()
            hud.show(.warmingUp)  // startLevelTask() flips to "Listening" on first buffer
            startLevelTask()
        } catch {
            log.error("Recorder failed to start: \(error.localizedDescription, privacy: .public)")
            state = .error("Could not start microphone: \(error.localizedDescription)")
            hud.showMessage(
                HUDErrorText.message(for: error) ?? "Could not start the microphone. Try again.",
                autoHideAfter: 4)
        }
    }

    private func finishBatchRecording() async {
        levelTask?.cancel()
        levelTask = nil
        let heldFor = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        let samples = recorder.stop()
        let seconds = Double(samples.count) / 16_000.0
        log.info(
            "Batch recording finished: \(samples.count, privacy: .public) samples (\(String(format: "%.2f", seconds), privacy: .public)s)"
        )
        guard samples.count >= 16_000 * 4 / 10 else {
            // A key held for a real moment but almost no audio means the mic
            // was still waking up, not an accidental tap - give it an honest
            // message instead of a silent discard.
            if heldFor >= 1.0, samples.count < 16_000 / 5 {
                let btHint =
                    AudioRecorder.defaultInputIsBluetooth()
                    ? " Bluetooth mics wake slowly; the built-in mic starts instantly."
                    : ""
                log.info(
                    "Batch recording captured almost no audio over \(String(format: "%.2f", heldFor), privacy: .public)s - likely mic wake-up."
                )
                hud.showMessage(
                    "The microphone was still waking up. Try again." + btHint,
                    autoHideAfter: 3
                )
                recorder.invalidate()
            } else {
                log.info("Batch recording too short (<400 ms), discarding.")
                hud.hide()
            }
            state = .idle
            return
        }
        state = .transcribing
        hud.show(.transcribing)

        // Parakeet TDT hallucinates whole utterances on too-quiet input
        // ("How are you doing?" -> "What were you giving?" is the classic
        // signature), so normalize before handing off; log the peak for
        // diagnosing mic gain reports.
        let prepared = AudioPreprocessor.normalize(samples)
        log.info(
            "Audio peak before normalisation: \(String(format: "%.1f", prepared.originalPeakDbFS), privacy: .public) dBFS"
        )
        let micWasVeryQuiet = prepared.originalPeakDbFS < -45

        do {
            let raw = try await engine.transcribe(samples: prepared.samples)
            let processed = makePostProcessor().apply(raw)
            if processed.text.isEmpty {
                log.info("Transcript empty - nothing to paste.")
                state = .idle
                if processed.dropPreviousChunks > 0 {
                    hud.showMessage("Nothing to scratch here", autoHideAfter: 2.5)
                } else {
                    hud.hide()
                }
            } else if SettingsStore.shared.autoPaste {
                log.info("Pasting \(processed.text.count, privacy: .public) characters.")
                inserter.insert(processed.text + " ")
                state = .idle
                if micWasVeryQuiet {
                    hud.showMessage(
                        "Microphone level is very low. Speak louder or raise the input volume in System Settings → Sound.",
                        autoHideAfter: 2.5
                    )
                } else {
                    hud.hide()
                }
            } else {
                copyToClipboard(processed.text)
                state = .idle
                hud.flashCopied()
            }
        } catch {
            log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            await reportError(error)
        }
    }

    // ------------------------------------------------------------------
    // Streaming flow
    // ------------------------------------------------------------------

    private func beginStreamingRecording() {
        streamingStartupInFlight = true
        releasedDuringStartup = false
        Task {
            do {
                let session = try await engine.makeStreamingSession()

                // Hotkey released mid-load - tear down without ever
                // entering recording state.
                if releasedDuringStartup {
                    await session.cancel()
                    streamingStartupInFlight = false
                    state = .idle
                    hud.hide()
                    return
                }

                self.streamingSession = session

                do {
                    try recorder.start()
                } catch {
                    // Cancel the session so the next press isn't routed
                    // into a half-built streaming flow.
                    await session.cancel()
                    self.streamingSession = nil
                    streamingStartupInFlight = false
                    await reportError(error)
                    return
                }

                state = .recording
                recordingStartedAt = Date()
                // Reserve the pill's preview area before the first buffer
                // flips it to .recording, so it sizes once and stays put.
                hud.setPreviewActive(true)
                hud.show(.warmingUp)
                startLevelTask()
                streamingStartupInFlight = false

                // Two concurrent tasks: feed chunks in, drain events out. The
                // feed task is owned here (not nested in the event task) so
                // finishStreamingRecording() can await it - draining every
                // buffered chunk - before calling finish(), which only
                // transcribes audio already fed. Otherwise a chunk still in
                // flight is lost as trailing words on a quick key release.
                feedTask = Task { [recorder, weak self] in
                    for await chunk in recorder.chunks {
                        guard self != nil else { break }
                        try? await session.feed(samples: chunk)
                    }
                }
                streamingTask = Task { [weak self] in
                    await self?.runStreamingTask(session: session)
                }
            } catch let EngineError.streamingNotSupported(name) {
                log.error("Streaming not supported by \(name, privacy: .public) - falling back to batch.")
                self.streamingSession = nil
                streamingStartupInFlight = false
                beginBatchRecording()
            } catch {
                self.streamingSession = nil
                streamingStartupInFlight = false
                await reportError(error)
            }
        }
    }

    private func runStreamingTask(session: any StreamingSession) async {
        // Per-sentence commit: partials only drive the HUD preview, nothing
        // touches the document until a pause pastes the sentence once, at
        // batch quality - committed text is never re-edited. `committed`
        // holds the exact pasted strings so "scratch that" can delete them
        // precisely, and the app each went to: the backspaces land in whatever
        // app is frontmost, so they're only sent while that's still the one.
        var committed: [(text: String, app: pid_t?)] = []
        var preview = ""

        for await event in session.events {
            switch event {
            case .partial(let suffix):
                preview += suffix
                hud.updatePreview(preview)
            case .endOfUtterance(let utteranceRaw, let audio):
                preview = ""
                hud.updatePreview("")
                // The session only ends utterances that decoded words or held
                // speech, so bare room noise never reaches the batch model.
                let raw = await batchQualityText(audio: audio, streamed: utteranceRaw)
                let result = makePostProcessor().apply(raw)
                postLog.debug(
                    "EOU commit: '\(result.text, privacy: .public)' drop=\(result.dropPreviousChunks, privacy: .public)"
                )

                // "scratch that" resolves to empty text + a drop signal: delete
                // exactly the characters we pasted for the last sentence(s).
                if result.dropPreviousChunks > 0 {
                    let drop = min(result.dropPreviousChunks, committed.count)
                    let pieces = committed.suffix(drop)
                    committed.removeLast(drop)
                    let frontApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    if pieces.allSatisfy({ $0.app == frontApp }) {
                        let chars = pieces.reduce(0) { $0 + $1.text.count }
                        if chars > 0 { inserter.deleteBackward(chars) }
                    } else {
                        log.info("Scratch that: the sentence went to another app - not deleting.")
                    }
                }

                guard !result.text.isEmpty else { continue }
                // One space between sentences, unless either side already
                // carries a break (a "new line" command, or a trimmed leading space).
                let prevNeedsGap = committed.last?.text.last.map { !$0.isWhitespace } ?? false
                let nextNeedsGap = result.text.first.map { !$0.isWhitespace } ?? true
                let piece = (prevNeedsGap && nextNeedsGap ? " " : "") + result.text
                inserter.insert(piece)
                committed.append((piece, NSWorkspace.shared.frontmostApplication?.processIdentifier))
            }
        }
        hud.updatePreview("")

        // Separate dictation sessions so the next press doesn't butt up
        // ("worldfoo"): one trailing space, unless the last sentence already
        // ended in whitespace (e.g. a "new line" command). Direct keystroke,
        // not insert() - see insertLiteralSpace's comment.
        if let last = committed.last?.text.last, !last.isWhitespace {
            inserter.insertLiteralSpace()
        }
    }

    // The streaming model is fast but rough (lowercase, no punctuation, weaker
    // words), so it only drives the preview and finds the pauses: each
    // finished utterance's audio is re-transcribed by the batch model, prepared
    // the same way as a batch recording. The streamed text is the fallback if
    // that pass fails.
    private func batchQualityText(audio: [Float], streamed: String) async -> String {
        postLog.debug("streamed: '\(streamed, privacy: .public)'")
        do {
            let prepared = AudioPreprocessor.normalize(audio)
            return try await engine.transcribe(samples: prepared.samples)
        } catch {
            log.error(
                "Batch pass failed, pasting the streamed text: \(error.localizedDescription, privacy: .public)"
            )
            return streamed
        }
    }

    private func finishStreamingRecording() async {
        levelTask?.cancel()
        levelTask = nil
        _ = recorder.stop()
        hud.setPreviewActive(false)
        state = .transcribing
        hud.show(.transcribing)

        guard let session = streamingSession else {
            state = .idle
            hud.hide()
            return
        }
        do {
            // recorder.stop() closed recorder.chunks, so the feed loop drains
            // the last buffered chunks and ends - await it BEFORE finish(),
            // which only transcribes audio already fed; otherwise chunks
            // still in flight drop as trailing words.
            await feedTask?.value
            feedTask = nil

            // Awaiting (not cancelling) streamingTask guarantees the trailing
            // .endOfUtterance that finish() yields gets committed - and its
            // trailing space appended - before we tear down. Bounded: finish()
            // already closed the stream, so the loop terminates.
            try await session.finish()
            await streamingTask?.value
            streamingSession = nil
            streamingTask = nil
            state = .idle
            hud.hide()
        } catch {
            // finish() threw before closing the stream - close it explicitly
            // so the consumer loop terminates, then drain both tasks instead
            // of leaking them.
            await session.cancel()
            await streamingTask?.value
            feedTask?.cancel()
            feedTask = nil
            streamingSession = nil
            streamingTask = nil
            await reportError(error)
        }
    }

    // ------------------------------------------------------------------
    // Shared helpers
    // ------------------------------------------------------------------

    private func startLevelTask() {
        levelTask = Task { [weak self] in
            guard let self else { return }
            var sawFirstBuffer = false  // flips HUD from "Warming up…" to "Listening"
            for await level in self.recorder.levels {
                if Task.isCancelled { break }
                if !sawFirstBuffer {
                    sawFirstBuffer = true
                    self.hud.show(.recording)
                }
                self.hud.updateLevel(level)
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func makePostProcessor() -> PostProcessor {
        PostProcessor(
            trimFillers: SettingsStore.shared.trimFillers,
            customFillerWords: SettingsStore.shared.customFillerWords,
            voiceCommandsEnabled: SettingsStore.shared.voiceCommands,
            customVoiceCommands: SettingsStore.shared.customVoiceCommands,
            dictionary: SettingsStore.shared.dictionary
        )
    }

    private func reportError(_ error: Error) async {
        // Full detail stays in the log; the HUD gets a short message (or
        // "Try again"), shown longer when there's specific guidance to read.
        log.error("Dictation error: \(error.localizedDescription, privacy: .public)")
        state = .error(error.localizedDescription)
        let mapped = HUDErrorText.message(for: error)
        let duration: TimeInterval = mapped == nil ? 2 : 4
        hud.showMessage(mapped ?? "Try again", autoHideAfter: duration)
        try? await Task.sleep(for: .seconds(duration))
        if case .error = state {
            state = .idle
        }
    }
}
