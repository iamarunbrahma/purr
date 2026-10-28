import AppKit
import Foundation
import os.log

// "Select text in any field, hold the voice-edit hotkey, speak the edit,
// release." Lives parallel to AppCoordinator's dictation flow rather than
// tangling with it: dictation writes new text into the cursor, editing
// rewrites a selection in place. A press with nothing selected aborts with an
// HUD hint - less surprising than silently dictating into the wrong place.
@MainActor
final class VoiceEditor {
    // Exposed so the coordinator can fold voice-edit activity into the menu bar
    // glyph; this flow drives the HUD directly and otherwise never surfaces there.
    enum State: Equatable {
        case idle
        case recording
        case transcribing
    }

    @Published private(set) var state: State = .idle

    private let recorder = AudioRecorder()
    private let inserter = TextInserter()
    private let hud: RecordingHUD
    private let engineProvider: () -> any TranscriptionEngine

    private var levelTask: Task<Void, Never>?
    private var capturedSelection: String?
    private var isActive = false
    private var recordingStartedAt: Date?

    private let log = Logger(subsystem: "com.arunbrahma.hello", category: "voice-edit")

    init(hud: RecordingHUD, engineProvider: @escaping () -> any TranscriptionEngine) {
        self.hud = hud
        self.engineProvider = engineProvider
        // Push-to-talk, so keep the mic warm between uses (the recorder skips this
        // on Bluetooth) to avoid clipping the instruction's opening words.
        recorder.allowsWarmKeeping = true
    }

    // Voice edit is hold-to-talk (no press-to-stop), so the whole active cycle
    // - recording and the post-release transcription - is non-interruptible.
    private var voiceEditBusy: Bool {
        switch state {
        case .recording, .transcribing: return true
        case .idle: return false
        }
    }

    func handlePress() {
        if hud.shouldIgnorePress(whileBusy: voiceEditBusy) { return }

        // The instruction is interpreted by an on-device LLM with no regex fallback,
        // so fail fast before recording rather than let the user speak into a dead
        // feature.
        guard EditInterpreter.isAvailable else {
            hud.showMessage(
                EditInterpreter.Failure.noBackend.errorDescription ?? "Voice Edit is unavailable.")
            log.info("Voice-edit aborted: no LLM backend available.")
            return
        }

        // Read on press, not release, so we capture what the user had selected when
        // they triggered the hotkey rather than whatever they ended up with after
        // speaking.
        let selection: String
        do {
            selection = try AXSelection.readSelection()
        } catch let failure as AXSelection.Failure {
            hud.showMessage(failure.errorDescription ?? "Voice Edit is unavailable.")
            log.info("Voice-edit aborted: \(failure.errorDescription ?? "unknown", privacy: .public)")
            return
        } catch {
            hud.showMessage("Voice Edit is unavailable.")
            log.info("Voice-edit aborted: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Reject before recording: a too-long passage overflows the model's context
        // window, and Gemma in particular doesn't fail cleanly on that.
        guard selection.count <= EditInterpreter.maxSelectionCharacters else {
            hud.showMessage(
                EditInterpreter.Failure.selectionTooLong.errorDescription
                    ?? "That selection is too long for Voice Edit.")
            log.info("Voice-edit aborted: selection too long (\(selection.count, privacy: .public) chars).")
            return
        }

        capturedSelection = selection
        isActive = true

        do {
            try recorder.start()
            recordingStartedAt = Date()
            state = .recording
            // "Warming up…" until the mic delivers a buffer; startLevelTask() flips it.
            hud.show(.warmingUp)
            startLevelTask()
            // Warm the LLM while the user speaks so a cold model load overlaps the
            // recording window instead of stalling the edit.
            EditInterpreter.warmUp()
        } catch {
            isActive = false
            capturedSelection = nil
            log.error("Recorder failed for voice edit: \(error.localizedDescription, privacy: .public)")
            hud.showMessage(
                HUDErrorText.message(for: error) ?? "The microphone couldn't start. Try again.",
                autoHideAfter: 4)
        }
    }

    func handleRelease() {
        guard isActive else { return }
        isActive = false
        levelTask?.cancel()
        levelTask = nil
        let heldFor = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        let samples = recorder.stop()
        guard let selection = capturedSelection else {
            state = .idle
            hud.hide()
            return
        }
        capturedSelection = nil

        guard samples.count >= 16_000 * 2 / 10 else {
            // A real hold that captured almost nothing means the mic was still waking
            // up - say so and reset the device. A genuine short tap just hides.
            if heldFor >= 1.0, samples.count < 16_000 / 5 {
                let btHint =
                    AudioRecorder.defaultInputIsBluetooth()
                    ? " Bluetooth mics wake slowly; the built-in mic starts instantly."
                    : ""
                hud.showMessage(
                    "The microphone was still waking up. Try again." + btHint,
                    autoHideAfter: 3
                )
                recorder.invalidate()
            } else {
                // Less than 200 ms of audio - treat as accidental tap.
                hud.hide()
            }
            state = .idle
            return
        }

        hud.show(.transcribing)
        state = .transcribing
        let engine = engineProvider()
        let inserter = self.inserter
        let hud = self.hud
        let log = self.log

        // Same DC-removal + peak-normalise pass the dictation flow uses. Voice-edit
        // utterances are shorter, so they're the most sensitive to mic gain - a quiet
        // instruction can decode as something the LLM can't act on, and EditInterpreter
        // then throws, leaving the selection untouched.
        let prepared = AudioPreprocessor.normalize(samples)
        log.info(
            "Voice-edit audio peak: \(String(format: "%.1f", prepared.originalPeakDbFS), privacy: .public) dBFS"
        )
        let micWasVeryQuiet = prepared.originalPeakDbFS < -45

        Task { @MainActor [weak self] in
            defer { self?.state = .idle }
            do {
                let raw = try await engine.transcribe(samples: prepared.samples)
                // The instruction is dictated speech, so run the same deterministic
                // post-processing (honouring its Settings toggles) before the LLM sees it.
                let instruction = PostProcessor(
                    trimFillers: SettingsStore.shared.trimFillers,
                    customFillerWords: SettingsStore.shared.customFillerWords,
                    voiceCommandsEnabled: SettingsStore.shared.voiceCommands,
                    customVoiceCommands: SettingsStore.shared.customVoiceCommands,
                    dictionary: SettingsStore.shared.dictionary
                ).apply(raw).text
                if instruction != raw.trimmingCharacters(in: .whitespacesAndNewlines) {
                    log.info(
                        "Voice-edit instruction cleaned by post-processing → \(instruction.count, privacy: .public) chars"
                    )
                }
                let edited = try await EditInterpreter.apply(instruction: instruction, to: selection)
                log.info("Voice edit applied → \(edited.count, privacy: .public) chars")
                if !AXSelection.replaceSelection(with: edited) {
                    // AX write failed (Chrome, Electron, some apps). Pasting overwrites
                    // the selection, so the outcome matches a successful AX write.
                    inserter.insert(edited)
                }
                if micWasVeryQuiet {
                    hud.showMessage(
                        "Microphone level is very low. Speak louder or raise the input volume in System Settings → Sound.",
                        autoHideAfter: 2.5
                    )
                } else {
                    hud.hide()
                }
            } catch let failure as EditInterpreter.Failure {
                // Interpretation failed - the selection is untouched. Surface the
                // specific reason so the user knows whether to retry, rephrase, or
                // set up a model. .backend's HUD message is generic, so log the
                // wrapped error to keep the diagnostic.
                if case .backend(let inner) = failure {
                    log.error("Voice edit backend failed: \(inner.localizedDescription, privacy: .public)")
                } else {
                    log.error(
                        "Voice edit failed: \(failure.errorDescription ?? "unknown", privacy: .public)")
                }
                hud.showMessage(
                    failure.errorDescription ?? "Voice Edit failed. Try again.", autoHideAfter: 2.5)
            } catch {
                log.error(
                    "Voice edit transcription failed: \(error.localizedDescription, privacy: .public)")
                hud.showMessage("Voice Edit failed. Try again.")
            }
        }
    }

    private func startLevelTask() {
        levelTask = Task { [weak self] in
            guard let self else { return }
            var sawFirstBuffer = false
            // First buffer flips "Warming up…" to "Voice Edit"; the rest drive the waveform.
            for await level in self.recorder.levels {
                if Task.isCancelled { break }
                if !sawFirstBuffer {
                    sawFirstBuffer = true
                    self.hud.show(.voiceEdit)
                }
                self.hud.updateLevel(level)
            }
        }
    }
}
