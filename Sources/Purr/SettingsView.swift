import SwiftUI
import os.log

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var modelVM = ModelPickerViewModel()
    @StateObject private var diarizerVM: FluidModelViewModel
    // Gates the Smart Typing toggle and drives the EOU card.
    @State private var eouInstalled = ParakeetEngine.eouIsInstalled()
    @State private var meetingLanguageModelInstalled = ParakeetEngine.meetingModelIsInstalled()
    // Shares the one Gemma model with the meeting summary section.
    @StateObject private var voiceEditLLM = LLMSummaryViewModel()
    @State private var showResetConfirmation = false
    @State private var showLanguagePicker = false
    @State private var showMeetingLanguagePicker = false
    @State private var showDeleteModelsConfirmation = false
    @State private var isDeletingModels = false
    @State private var deleteModelsError: String?
    @State private var deleteErrorToken = 0
    @ObservedObject var coordinator: AppCoordinator

    init(coordinator: AppCoordinator) {
        self._coordinator = ObservedObject(wrappedValue: coordinator)
        _diarizerVM = StateObject(
            wrappedValue: FluidModelViewModel(
                installedProbe: { Diarizer.isInstalled() },
                downloader: { _ in await coordinator.downloadDiarizationModel() },
                deleter: { coordinator.deleteDiarizationModel() },
                busyMessage: "A meeting is in progress. Stop it first, then try again."
            ))
    }

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            engineTab
                .tabItem { Label("Engine", systemImage: "waveform") }
            featuresTab
                .tabItem { Label("Features", systemImage: "sparkles") }
            dictionaryTab
                .tabItem { Label("Customization", systemImage: "text.book.closed") }
        }
        .padding(.top)
        .frame(minWidth: 580, minHeight: 580)
    }

    // ------------------------------------------------------------------
    // General tab - hotkey, mode, behavior toggles
    // ------------------------------------------------------------------

    private var generalTab: some View {
        Form {
            Section("Dictate Mode") {
                Picker("Trigger", selection: $settings.hotkeyMode) {
                    ForEach(SettingsStore.HotkeyMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                LabeledContent("Hotkey", value: settings.hotkey.displayName)

                HStack(spacing: 6) {
                    Button("Right Option") {
                        settings.hotkey = .defaultRightOption
                        coordinator.reinstallHotkey()
                    }
                    Button("Right Command") {
                        settings.hotkey = Hotkey(keyCode: nil, modifiers: .maskCommand)
                        coordinator.reinstallHotkey()
                    }
                    Button("F5") {
                        settings.hotkey = Hotkey(keyCode: 96, modifiers: [])
                        coordinator.reinstallHotkey()
                    }
                    Button("⌃⌥ Space") {
                        settings.hotkey = Hotkey(keyCode: 49, modifiers: [.maskControl, .maskAlternate])
                        coordinator.reinstallHotkey()
                    }
                }
                .controlSize(.small)
            }

            Section("Automatic Insertion") {
                Toggle("Paste transcribed text at cursor automatically", isOn: $settings.autoPaste)
                    .help(
                        "On: paste at the cursor (or insert live with Smart Typing). "
                            + "Off: copy transcript to clipboard so you can ⌘V it."
                    )
                    .onChange(of: settings.autoPaste) { _, isOn in
                        // Smart Typing is a form of auto-insertion - force it
                        // off too, rather than leaving it on-but-inert.
                        if !isOn { settings.smartTyping = false }
                    }
            }

            Section("Smart Typing") {
                Toggle("Smart Typing (live preview)", isOn: $settings.smartTyping)
                    .disabled(!engineSupportsStreaming || !eouInstalled || !settings.autoPaste)
                    .help(smartTypingHelpText)
                if !engineSupportsStreaming {
                    Label(
                        "Requires Parakeet. Switch the engine in the Engine tab.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if !settings.autoPaste {
                    Label(
                        "Requires \"Paste transcribed text at cursor automatically\" above.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                EOUCard(coordinator: coordinator, isInstalled: $eouInstalled)
            }

            Section("Post-processing") {
                Toggle("Trim filler words (\"um\", \"uh\")", isOn: $settings.trimFillers)
                Toggle(
                    "Voice commands (\"new line\", \"comma\", \"scratch that\")",
                    isOn: $settings.voiceCommands)
            }

            Section {
                Button("Reset to Default", role: .destructive) {
                    showResetConfirmation = true
                }
                .confirmationDialog(
                    "Reset all Purr settings to defaults?",
                    isPresented: $showResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Reset", role: .destructive) {
                        settings.resetToDefaults()
                        coordinator.reloadEngine()
                        coordinator.reinstallHotkey()
                    }
                } message: {
                    Text("Restores all preferences. Downloaded models stay on disk.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { eouInstalled = ParakeetEngine.eouIsInstalled() }
    }

    // ------------------------------------------------------------------
    // Engine tab - Parakeet vs Whisper, model picker
    // ------------------------------------------------------------------

    private var engineTab: some View {
        Form {
            Section("Speech engine") {
                Picker("Engine", selection: $settings.engine) {
                    ForEach(SettingsStore.Engine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: settings.engine) { _, newValue in
                    // Whisper has no streaming engine; clear the toggle rather
                    // than leave it "on" with no effect. Not re-enabled on
                    // switching back - explicit opt-in.
                    if newValue == .whisper {
                        settings.smartTyping = false
                        // Force off if the model can't translate, so the
                        // toggle isn't stuck on against a disabled row.
                        if !ModelManager.supportsTranslation(settings.modelName) {
                            settings.translateToEnglish = false
                        }
                    }
                    coordinator.reloadEngine()
                }

                Text(settings.engine.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if settings.engine == .whisper {
                Section("Whisper model") {
                    ForEach(ModelManager.curatedModels) { choice in
                        ModelRow(
                            choice: choice,
                            isSelected: settings.modelName == choice.id,
                            isInstalled: modelVM.installed.contains(choice.id),
                            progress: modelVM.progress[choice.id],
                            errorMessage: modelVM.errors[choice.id],
                            onSelect: {
                                settings.modelName = choice.id
                                if !choice.supportsTranslation {
                                    settings.translateToEnglish = false
                                }
                                coordinator.reloadEngine()
                                // Auto-download if not on disk; the reload
                                // above fails-soft until the weights land.
                                if !modelVM.installed.contains(choice.id),
                                    modelVM.progress[choice.id] == nil
                                {
                                    modelVM.download(choice.id)
                                }
                            },
                            onDelete: { modelVM.delete(choice.id) },
                            onRetry: { modelVM.download(choice.id) },
                            onDownload: { modelVM.download(choice.id) }
                        )
                    }
                }

                Section("Translation") {
                    if selectedModelSupportsTranslation {
                        sourceLanguageField
                    }
                    Toggle("Translate speech to English", isOn: $settings.translateToEnglish)
                        .disabled(!selectedModelSupportsTranslation)
                        .help("Speak in any language; Whisper writes the transcript in English.")
                    if !selectedModelSupportsTranslation {
                        Label(
                            "Translation only works with Base, Small, or Large V3 models above.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else if settings.translateToEnglish {
                        Text("Speak any of 100+ languages. The transcript is written out in English.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("Parakeet engine") {
                    ParakeetEngineCard(coordinator: coordinator)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            modelVM.refreshInstalled()
            eouInstalled = ParakeetEngine.eouIsInstalled()
            diarizerVM.refresh()
        }
    }

    // ------------------------------------------------------------------
    // Features tab - meeting mode, voice editing
    // ------------------------------------------------------------------

    private var featuresTab: some View {
        Form {
            Section("Meeting Mode") {
                Toggle(
                    "Enable meeting recording",
                    isOn: Binding(
                        get: { settings.meetingEnabled },
                        set: { newValue in
                            settings.meetingEnabled = newValue
                            coordinator.reinstallHotkey()
                        }
                    )
                )
                .disabled(!diarizerVM.isInstalled)
                .help(
                    diarizerVM.isInstalled
                        ? "Tap the hotkey to toggle meeting recording."
                        : "Requires the Diarization model below."
                )
                Toggle("Show Meeting Indicator", isOn: $settings.showMeetingHUD)
                    .disabled(!settings.meetingEnabled)
                    .help(
                        "Show the floating \u{201C}Meeting \u{00B7} 0:00\u{201D} pill with a live waveform while a meeting records. When off, the menu bar still shows a recording indicator."
                    )
                Toggle("Save Meeting Audio", isOn: $settings.saveMeetingAudio)
                    .disabled(!settings.meetingEnabled)
                    .help(
                        "Saves a compressed recording (.m4a) next to each meeting's transcript, so a weak transcript can be re-verified or re-transcribed later."
                    )
                fluidModelCard(
                    name: "Diarization",
                    size: "~21 MB",
                    note: "Meeting speaker attribution. Records who said what.",
                    vm: diarizerVM
                )
                meetingLanguageField
                if !settings.meetingLanguage.isEmpty {
                    MeetingLanguageModelCard(
                        coordinator: coordinator, isInstalled: $meetingLanguageModelInstalled)
                }
                Text(
                    "Tap the hotkey to toggle meeting recording. Saves the transcript as markdown to the meetings folder you picked during setup (default: ~/Library/Application Support/Purr/Purr Meetings/)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if settings.meetingEnabled {
                    LabeledContent("Hotkey", value: settings.meetingHotkey.displayName)
                    HStack(spacing: 6) {
                        Button("⌃⌥ M") {
                            settings.meetingHotkey = Hotkey.defaultMeeting
                            coordinator.reinstallHotkey()
                        }
                        Button("⌃⌥ R") {
                            settings.meetingHotkey = Hotkey(
                                keyCode: 15, modifiers: [.maskControl, .maskAlternate])
                            coordinator.reinstallHotkey()
                        }
                        Button("F9") {
                            settings.meetingHotkey = Hotkey(keyCode: 101, modifiers: [])
                            coordinator.reinstallHotkey()
                        }
                    }
                    .controlSize(.small)
                }
            }

            Section("Meeting summary") {
                MeetingSummarySection(vm: voiceEditLLM)
            }

            Section("Voice Editing Mode") {
                Toggle(
                    "Enable voice editing",
                    isOn: Binding(
                        get: { settings.voiceEditEnabled },
                        set: { newValue in
                            settings.voiceEditEnabled = newValue
                            coordinator.reinstallHotkey()
                        }
                    ))
                Text(
                    "Select text, hold the hotkey, and speak the change in any phrasing: \"change X to Y\", \"make this more concise\". An on-device AI model interprets and applies the edit."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                voiceEditModelStatus

                if settings.voiceEditEnabled {
                    LabeledContent("Hotkey", value: settings.voiceEditHotkey.displayName)
                    HStack(spacing: 6) {
                        Button("⌃⌥ E") {
                            settings.voiceEditHotkey = Hotkey.defaultVoiceEdit
                            coordinator.reinstallHotkey()
                        }
                        Button("⌃⌥ V") {
                            settings.voiceEditHotkey = Hotkey(
                                keyCode: 9, modifiers: [.maskControl, .maskAlternate])
                            coordinator.reinstallHotkey()
                        }
                        Button("F8") {
                            settings.voiceEditHotkey = Hotkey(keyCode: 100, modifiers: [])
                            coordinator.reinstallHotkey()
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            diarizerVM.refresh()
            voiceEditLLM.refresh()
        }
    }

    // No second Download button here - the meeting summary section owns the
    // one Gemma download, so two sections can't race on the same file.
    @ViewBuilder
    private var voiceEditModelStatus: some View {
        if voiceEditLLM.appleFoundationAvailable {
            EmptyView()
        } else if voiceEditLLM.isInstalled {
            Label(
                "Powered by \(LLMModelManager.defaultModelLabel), on-device.",
                systemImage: "checkmark.seal"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "Voice editing needs an on-device AI model.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(
                    "It uses the same \(LLMModelManager.defaultModelLabel) model as Auto-Summarize Meetings above."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // ------------------------------------------------------------------
    // Dictionary tab - custom vocabulary corrections
    // ------------------------------------------------------------------

    private var dictionaryTab: some View {
        Form {
            Section("Custom dictionary") {
                Text("Force spellings for proper nouns, brands, and acronyms.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach($settings.dictionary) { $entry in
                    HStack {
                        TextField("Heard as", text: $entry.from)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        TextField("Replace with", text: $entry.to)
                        Button(role: .destructive) {
                            settings.dictionary.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    settings.dictionary.append(DictionaryEntry(from: "", to: ""))
                } label: {
                    Label("Add entry", systemImage: "plus")
                }
            }

            Section("Custom voice commands") {
                Text(
                    "Map a spoken phrase to text or a symbol to insert. Use \\n for a line break, \\t for a tab."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                ForEach($settings.customVoiceCommands) { $entry in
                    HStack {
                        TextField("Say", text: $entry.phrase)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        TextField("Inserts", text: $entry.replacement)
                        Button(role: .destructive) {
                            settings.customVoiceCommands.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    settings.customVoiceCommands.append(
                        VoiceCommandEntry(phrase: "", replacement: ""))
                } label: {
                    Label("Add command", systemImage: "plus")
                }

                if !settings.voiceCommands {
                    Text("Voice commands are turned off. Turn them on for these to take effect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Custom filler words") {
                Text(
                    "Words or phrases to strip from every transcript, in addition to the built-in \"um\" and \"uh\"."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                ForEach($settings.customFillerWords) { $entry in
                    HStack {
                        TextField("Filler word or phrase", text: $entry.word)
                        Button(role: .destructive) {
                            settings.customFillerWords.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    settings.customFillerWords.append(FillerWordEntry(word: ""))
                } label: {
                    Label("Add filler word", systemImage: "plus")
                }

                if !settings.trimFillers {
                    Text("Filler trimming is turned off. Turn it on for these to take effect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Models") {
                Text(
                    "Remove every downloaded model to reclaim disk space: Parakeet, the Whisper models, the diarizer, and the Gemma 4 E2B model. Your meeting transcripts and preferences are kept."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                if isDeletingModels {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Deleting…").foregroundStyle(.secondary)
                    }
                } else {
                    Button("Delete Models", role: .destructive) {
                        showDeleteModelsConfirmation = true
                    }
                    .disabled(anyModelDownloading)
                    .confirmationDialog(
                        "Delete all downloaded models?",
                        isPresented: $showDeleteModelsConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Delete Models", role: .destructive) { deleteAllModels() }
                    } message: {
                        Text(
                            "Removes Parakeet, Whisper, the diarizer, and Gemma to free disk space, and turns off Smart Typing, meeting recording, and auto-summarize. Transcripts are kept; re-download models anytime from the Engine and Features tabs."
                        )
                    }
                    if anyModelDownloading {
                        Text("Finish the model download in progress before deleting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = deleteModelsError {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    // Gates the Delete Models button so a wipe can't pull weights out from
    // under an in-flight download.
    private var anyModelDownloading: Bool {
        coordinator.parakeetBatchProgress != nil
            || coordinator.eouDownloadProgress != nil
            || coordinator.meetingLanguageModelProgress != nil
            || !modelVM.progress.isEmpty
            || diarizerVM.isDownloading
            || voiceEditLLM.progress != nil
    }

    private func deleteAllModels() {
        deleteModelsError = nil
        isDeletingModels = true
        Task {
            let result = await coordinator.deleteAllModels()
            isDeletingModels = false
            switch result {
            case .ok:
                modelVM.refreshInstalled()
                eouInstalled = ParakeetEngine.eouIsInstalled()
                meetingLanguageModelInstalled = ParakeetEngine.meetingModelIsInstalled()
                diarizerVM.refresh()
                voiceEditLLM.refresh()
            case .busy:
                showTransientDeleteError(
                    "Can't delete models while recording, transcribing, in a meeting, or downloading a model. Try again in a moment."
                )
            case .failed(let error):
                showTransientDeleteError(error.localizedDescription)
            }
        }
    }

    // Clears itself after a few seconds so a "busy" message doesn't linger.
    private func showTransientDeleteError(_ message: String) {
        deleteModelsError = message
        deleteErrorToken += 1
        let token = deleteErrorToken
        Task {
            try? await Task.sleep(for: .seconds(6))
            if deleteErrorToken == token { deleteModelsError = nil }
        }
    }

    @ViewBuilder
    private func fluidModelCard(
        name: String, size: String, note: String, vm: FluidModelViewModel
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name).font(.body.weight(.medium))
                    Text(size).foregroundStyle(.secondary).font(.caption)
                    if vm.isDownloading {
                        // No numeric percent - a multi-file download's fraction
                        // jumps around and would read as misleading.
                        Text("downloading…").foregroundStyle(.secondary).font(.caption2)
                    } else if !vm.isInstalled, vm.error == nil {
                        Text("not yet downloaded").foregroundStyle(.secondary).font(.caption2)
                    }
                }
                Text(note).font(.caption).foregroundStyle(.secondary)
                if vm.isDownloading, let fraction = vm.fractionCompleted {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .padding(.top, 2)
                }
                if let message = vm.error {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.top, 2)
                }
            }
            Spacer()
            if vm.isDownloading {
                ProgressView().controlSize(.small)
            } else if vm.isInstalled {
                Button("Delete", role: .destructive) { vm.delete() }
                    .controlSize(.small)
            } else {
                Button("Download") { vm.download() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }

    private var smartTypingHelpText: String {
        if !engineSupportsStreaming {
            return "Available with Parakeet. Whisper has no streaming engine."
        }
        if !eouInstalled {
            return "Requires the Parakeet EOU 120M model below."
        }
        if !settings.autoPaste {
            return "Turn on \"Paste transcribed text at cursor automatically\" above to use Smart Typing."
        }
        return "Shows a live preview as you speak, then inserts each sentence when you pause."
    }

    private var engineSupportsStreaming: Bool {
        settings.engine == .parakeet
    }

    // Mirrors WhisperEngine's runtime gate so the UI never offers an option
    // the engine would ignore.
    private var selectedModelSupportsTranslation: Bool {
        ModelManager.supportsTranslation(settings.modelName)
    }

    @ViewBuilder
    private var sourceLanguageField: some View {
        let selected = WhisperLanguage.named(settings.translationSourceLanguage)

        Button {
            showLanguagePicker = true
        } label: {
            HStack {
                Text("Source Language")
                Spacer()
                Text(selected.name).foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showLanguagePicker) {
            LanguagePickerSheet(
                title: "Source Language",
                selection: $settings.translationSourceLanguage,
                allLanguages: WhisperLanguage.all,
                matching: WhisperLanguage.matching,
                onClose: { showLanguagePicker = false }
            )
        }

        Text(
            settings.translationSourceLanguage.isEmpty
                ? "Auto-detect can misread very short clips. Select a language for reliable short-phrase translation."
                : "Detection is skipped. Whisper assumes the audio is \(selected.name)."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var meetingLanguageField: some View {
        let selected = ParakeetLanguage.named(settings.meetingLanguage)

        Button {
            showMeetingLanguagePicker = true
        } label: {
            HStack {
                Text("Meeting Language")
                Spacer()
                Text(selected.name).foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showMeetingLanguagePicker) {
            LanguagePickerSheet(
                title: "Meeting Language",
                selection: $settings.meetingLanguage,
                allLanguages: ParakeetLanguage.all,
                matching: ParakeetLanguage.matching,
                onClose: { showMeetingLanguagePicker = false }
            )
        }

        Text(
            settings.meetingLanguage.isEmpty
                ? "Meetings transcribe with the English Parakeet model."
                : "Meetings transcribe with the multilingual Parakeet model, hinted for \(selected.name)."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// Generic Download/Delete view-model: one instance drives EOU streaming,
// Offline Diarizer, or any FluidAudio load-on-demand model.
@MainActor
final class FluidModelViewModel: ObservableObject {
    @Published var isInstalled: Bool
    @Published var isDownloading: Bool = false
    @Published var fractionCompleted: Double?
    @Published var error: String?

    private let installedProbe: () -> Bool
    private let downloader: ((@Sendable (Double) -> Void)?) async -> AppCoordinator.ModelDownloadResult
    private let deleter: () -> AppCoordinator.DiarizerDeleteResult
    private let busyMessage: String

    init(
        installedProbe: @escaping () -> Bool,
        downloader: @escaping ((@Sendable (Double) -> Void)?) async -> AppCoordinator.ModelDownloadResult,
        deleter: @escaping () -> AppCoordinator.DiarizerDeleteResult,
        busyMessage: String
    ) {
        self.installedProbe = installedProbe
        self.downloader = downloader
        self.deleter = deleter
        self.busyMessage = busyMessage
        self.isInstalled = installedProbe()
    }

    func refresh() { isInstalled = installedProbe() }

    func download() {
        guard !isDownloading else { return }
        error = nil
        fractionCompleted = nil
        isDownloading = true
        Task {
            let onProgress: @Sendable (Double) -> Void = { fraction in
                Task { @MainActor in self.fractionCompleted = fraction }
            }
            let result = await downloader(onProgress)
            isDownloading = false
            fractionCompleted = nil
            switch result {
            case .ok: isInstalled = true
            case .failed(let err): error = err.localizedDescription
            }
        }
    }

    func delete() {
        error = nil
        switch deleter() {
        case .ok: isInstalled = false
        case .busy: error = busyMessage
        case .failed(let err): error = err.localizedDescription
        }
    }
}

// ----------------------------------------------------------------------
// Parakeet engine card - Engine tab. v2 also auto-downloads during warmup
// (unlike EOU/diarizer, tap-only), so progress comes from the coordinator's
// shared state rather than a per-button view model.
// ----------------------------------------------------------------------

private struct ParakeetEngineCard: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var isInstalled = ParakeetEngine.batchIsInstalled()
    @State private var error: String?

    var body: some View {
        let progress = coordinator.parakeetBatchProgress
        let downloading = progress != nil
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Parakeet TDT v2").font(.body.weight(.medium))
                    Text("~450 MB").foregroundStyle(.secondary).font(.caption)
                    if downloading {
                        Text("downloading…").foregroundStyle(.secondary).font(.caption2)
                    } else if !isInstalled, error == nil {
                        Text("not yet downloaded").foregroundStyle(.secondary).font(.caption2)
                    }
                }
                Text("Batch dictation, meetings, and voice editing. Downloads on first use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .padding(.top, 2)
                }
                if let error {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.top, 2)
                }
            }
            Spacer()
            if downloading {
                // No trailing spinner - the progress bar already conveys state.
            } else if isInstalled {
                Button("Delete", role: .destructive) { delete() }
                    .controlSize(.small)
            } else {
                Button("Download") { download() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
        .onAppear { isInstalled = ParakeetEngine.batchIsInstalled() }
        .onChange(of: coordinator.parakeetBatchProgress) { _, newValue in
            if newValue == nil { isInstalled = ParakeetEngine.batchIsInstalled() }
        }
    }

    private func download() {
        error = nil
        Task {
            if case .failed(let err) = await coordinator.downloadParakeetModel() {
                error = err.localizedDescription
            }
            isInstalled = ParakeetEngine.batchIsInstalled()
        }
    }

    private func delete() {
        error = nil
        switch coordinator.deleteParakeetModel() {
        case .ok: isInstalled = false
        case .busy: error = "Finish the current dictation or meeting, then try again."
        case .failed(let err): error = err.localizedDescription
        }
    }
}

// ----------------------------------------------------------------------
// Parakeet EOU 120M card - Smart Typing section. Also auto-downloads during
// warmup (gated on Smart Typing). `isInstalled` binds to the parent so the
// Smart Typing toggle's enabled gate tracks the same state.
// ----------------------------------------------------------------------

private struct EOUCard: View {
    @ObservedObject var coordinator: AppCoordinator
    @Binding var isInstalled: Bool
    @State private var error: String?

    var body: some View {
        let progress = coordinator.eouDownloadProgress
        let downloading = progress != nil
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Parakeet EOU 120M (320 ms)").font(.body.weight(.medium))
                    Text("~440 MB").foregroundStyle(.secondary).font(.caption)
                    if downloading {
                        Text("downloading…").foregroundStyle(.secondary).font(.caption2)
                    } else if !isInstalled, error == nil {
                        Text("not yet downloaded").foregroundStyle(.secondary).font(.caption2)
                    }
                }
                Text("Live word-by-word typing. Cache-aware streaming encoder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .padding(.top, 2)
                }
                if let error {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.top, 2)
                }
            }
            Spacer()
            if downloading {
                // No trailing spinner - the progress bar already conveys state.
            } else if isInstalled {
                Button("Delete", role: .destructive) { delete() }
                    .controlSize(.small)
            } else {
                Button("Download") { download() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
        .onAppear { isInstalled = ParakeetEngine.eouIsInstalled() }
        .onChange(of: coordinator.eouDownloadProgress) { _, newValue in
            if newValue == nil { isInstalled = ParakeetEngine.eouIsInstalled() }
        }
    }

    private func download() {
        error = nil
        Task {
            if case .failed(let err) = await coordinator.downloadEOUModel() {
                error = err.localizedDescription
            }
            isInstalled = ParakeetEngine.eouIsInstalled()
        }
    }

    private func delete() {
        error = nil
        switch coordinator.deleteEOUModel() {
        case .ok: isInstalled = false
        case .busy: error = "Smart Typing session is active. Release the hotkey and try again."
        case .failed(let err): error = err.localizedDescription
        }
    }
}

// ----------------------------------------------------------------------
// Parakeet v3 (multilingual meeting) card - Features tab. Mirrors EOUCard's
// real fractional progress, since this model can also be triggered two ways:
// the Download button here, or a meeting hitting the language for the
// first time.
// ----------------------------------------------------------------------

private struct MeetingLanguageModelCard: View {
    @ObservedObject var coordinator: AppCoordinator
    @Binding var isInstalled: Bool
    @State private var error: String?

    var body: some View {
        let progress = coordinator.meetingLanguageModelProgress
        let downloading = progress != nil
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Parakeet TDT v3 (multilingual)").font(.body.weight(.medium))
                    Text("~450 MB").foregroundStyle(.secondary).font(.caption)
                    if downloading {
                        Text("downloading…").foregroundStyle(.secondary).font(.caption2)
                    } else if !isInstalled, error == nil {
                        Text("not yet downloaded").foregroundStyle(.secondary).font(.caption2)
                    }
                }
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .padding(.top, 2)
                }
                if let error {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.top, 2)
                }
            }
            Spacer()
            if downloading {
                // No trailing spinner - the progress bar already conveys state.
            } else if isInstalled {
                Button("Delete", role: .destructive) { delete() }
                    .controlSize(.small)
            } else {
                Button("Download") { download() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
        .help(
            "Needed for non-English meeting transcription. Downloads automatically on your next meeting if you skip this."
        )
        .onAppear { isInstalled = ParakeetEngine.meetingModelIsInstalled() }
        .onChange(of: coordinator.meetingLanguageModelProgress) { _, newValue in
            if newValue == nil { isInstalled = ParakeetEngine.meetingModelIsInstalled() }
        }
    }

    private func download() {
        error = nil
        Task {
            if case .failed(let err) = await coordinator.downloadMeetingLanguageModel() {
                error = err.localizedDescription
            }
            isInstalled = ParakeetEngine.meetingModelIsInstalled()
        }
    }

    private func delete() {
        error = nil
        switch coordinator.deleteMeetingLanguageModel() {
        case .ok: isInstalled = false
        case .busy: error = "Finish the current meeting, then try again."
        case .failed(let err): error = err.localizedDescription
        }
    }
}

// ----------------------------------------------------------------------
// Whisper model row - only shown on the Engine tab when Whisper is active
// ----------------------------------------------------------------------

private struct ModelRow: View {
    let choice: ModelChoice
    let isSelected: Bool
    let isInstalled: Bool
    let progress: Double?
    let errorMessage: String?
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onRetry: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(choice.label).font(.body.weight(.medium))
                    Text("\(choice.sizeMB) MB").foregroundStyle(.secondary).font(.caption)
                    if errorMessage == nil {
                        if !isInstalled, progress == nil {
                            Text("not downloaded").foregroundStyle(.secondary).font(.caption2)
                        } else if progress != nil {
                            Text("downloading…").foregroundStyle(.secondary).font(.caption2)
                        }
                    }
                }
                Text(choice.note).font(.caption).foregroundStyle(.secondary)
                if let progress = progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .padding(.top, 4)
                }
                if let errorMessage = errorMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorMessage).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.top, 4)
                }
            }
            Spacer()
            if errorMessage != nil {
                Button("Retry", action: onRetry).controlSize(.small)
            } else if isInstalled, !isSelected {
                Button("Delete", role: .destructive, action: onDelete)
                    .controlSize(.small)
            } else if !isInstalled, progress == nil {
                // Lets users pre-download without switching to it.
                Button("Download", action: onDownload).controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        // Whole row is one tap target: selects and downloads together.
        // Ignored mid-download to avoid queueing two pulls.
        .contentShape(Rectangle())
        .onTapGesture {
            if progress != nil { return }
            onSelect()
        }
    }
}

@MainActor
final class ModelPickerViewModel: ObservableObject {
    @Published var installed: Set<String> = []
    @Published var progress: [String: Double] = [:]
    // Inline on the row (not a modal alert) so options stay comparable.
    @Published var errors: [String: String] = [:]

    func refreshInstalled() {
        installed = Set(ModelManager.curatedModels.map(\.id).filter { ModelManager.isInstalled($0) })
    }

    func download(_ modelName: String) {
        errors[modelName] = nil
        progress[modelName] = 0
        Task {
            do {
                _ = try await ModelManager.download(modelName: modelName) { fraction in
                    Task { @MainActor in self.progress[modelName] = fraction }
                }
                self.progress[modelName] = nil
                self.refreshInstalled()
            } catch {
                self.progress[modelName] = nil
                self.errors[modelName] = friendlyDownloadError(error)
            }
        }
    }

    func delete(_ modelName: String) {
        do {
            try ModelManager.delete(modelName)
            refreshInstalled()
        } catch {
            NSAlert(error: error).runModal()
        }
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

// ----------------------------------------------------------------------
// Meeting summary section - LLM picker + auto-summarize toggle, Features tab.
// A Download button here lets users pre-fetch the ~3.3GB Gemma weights
// instead of waiting for the first real summarization.
// ----------------------------------------------------------------------

private struct MeetingSummarySection: View {
    @ObservedObject private var settings = SettingsStore.shared
    // Shared with SettingsView's voiceEditLLM (one Gemma VM) so the Delete
    // Models gate observes the same download instance - not a second one.
    @ObservedObject var vm: LLMSummaryViewModel

    var body: some View {
        Toggle(
            "Auto-summarize meetings",
            isOn: Binding(
                get: { settings.summarizeMeetings },
                set: { settings.summarizeMeetings = $0 }
            )
        )
        .disabled(!vm.canSummarize)
        .help(toggleHelp)
        // Re-read on-disk state so the row reflects a Delete Models wipe
        // on another tab.
        .onAppear { vm.refresh() }

        Text("Writes a sidecar `.summary.md` with TL;DR, decisions, and action items. On-device.")
            .font(.caption)
            .foregroundStyle(.secondary)

        if vm.appleFoundationAvailable {
            appleFoundationCard
        } else {
            appleFoundationUnavailableNote
        }
        gemmaCard

        // Names the weights' license before they download.
        Label {
            (Text("Gemma 4 is provided by Google under the ")
                + Text(LLMModelManager.licenseName).underline()
                + Text("."))
                .font(.caption)
        } icon: {
            Image(systemName: "info.circle")
        }
        .onTapGesture { NSWorkspace.shared.open(LLMModelManager.licenseURL) }
        .foregroundStyle(.secondary)
    }

    private var toggleHelp: String {
        if vm.appleFoundationAvailable {
            return "Uses your selected backend."
        }
        if vm.isInstalled {
            return "Writes a sidecar .summary.md after each meeting."
        }
        return "Download a model below or upgrade to macOS 26."
    }

    private var appleSelected: Bool {
        vm.appleFoundationAvailable && settings.summaryBackend == .appleFoundation
    }

    // "Active" only once actually installed - selecting Gemma before that
    // triggers a download instead of changing the backend.
    private var gemmaSelected: Bool {
        if !vm.appleFoundationAvailable { return vm.isInstalled }
        return settings.summaryBackend == .llamaCpp && vm.isInstalled
    }

    private var appleFoundationCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: appleSelected ? "largecircle.fill.circle" : "circle")
                .foregroundColor(appleSelected ? .accentColor : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Apple Foundation Model").font(.body.weight(.medium))
                    Text("built-in").foregroundStyle(.secondary).font(.caption)
                }
                Text("Built into macOS Tahoe via Apple Intelligence. No download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { settings.summaryBackend = .appleFoundation }
    }

    private var appleFoundationUnavailableNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Foundation Model").font(.body.weight(.medium))
                Text(
                    "Needs macOS Tahoe 26.0+ on Apple Silicon with Apple Intelligence on, and both the Mac and Siri set to English (United States)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(
                    "Set System Settings → General → Language & Region → Preferred Languages to English (US), then Apple Intelligence & Siri → Language to English (United States). Restart your Mac for the change to take effect."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("Open Settings") {
                    // The legacy com.apple.preference.assistant id now lands
                    // on General; this targets Tahoe's Apple Intelligence & Siri pane.
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // Selectable only once weights are on disk; tapping before that
    // downloads instead of changing the backend.
    private var gemmaCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: gemmaSelected ? "largecircle.fill.circle" : "circle")
                .foregroundColor(gemmaSelected ? .accentColor : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(LLMModelManager.defaultModelLabel).font(.body.weight(.medium))
                    Text(String(format: "%.1f GB", Double(LLMModelManager.defaultModelSizeMB) / 1000))
                        .foregroundStyle(.secondary).font(.caption)
                    if vm.error == nil {
                        if !vm.isInstalled, vm.progress == nil {
                            Text("not downloaded").foregroundStyle(.secondary).font(.caption2)
                        } else if vm.progress != nil {
                            Text("downloading…").foregroundStyle(.secondary).font(.caption2)
                        }
                    }
                }
                Text("Runs via llama.cpp with Metal acceleration on Apple Silicon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let progress = vm.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .padding(.top, 4)
                }
                if let errorMessage = vm.error {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorMessage).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.top, 4)
                }
            }
            Spacer()
            if vm.error != nil {
                Button("Retry") { vm.download() }
                    .controlSize(.small)
            } else if vm.isInstalled {
                // Offered even when Gemma is active - reclaims the ~3.3GB
                // without switching backend first; vm.delete() handles that.
                Button("Delete", role: .destructive) { vm.delete() }
                    .controlSize(.small)
            } else if vm.progress == nil {
                Button("Download") { vm.download() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if vm.progress != nil { return }
            if vm.isInstalled {
                settings.summaryBackend = .llamaCpp
            } else {
                vm.download()
            }
        }
    }
}

@MainActor
final class LLMSummaryViewModel: ObservableObject {
    @Published var isInstalled: Bool = false
    @Published var appleFoundationAvailable: Bool = false
    @Published var progress: Double? = nil
    // Inline on the Gemma row, not a modal alert.
    @Published var error: String? = nil

    var canSummarize: Bool { appleFoundationAvailable || isInstalled }

    // Shared with AppCoordinator so a download/delete here reuses the same
    // session a meeting would, instead of a stale copy lingering elsewhere.
    private let summarizer = MeetingSummarizer.shared

    init() {
        refresh()
    }

    func refresh() {
        isInstalled = LLMModelManager.isInstalled()
        if #available(macOS 26.0, *) {
            appleFoundationAvailable = MeetingSummarizer.appleFoundationAvailable
        } else {
            appleFoundationAvailable = false
        }
    }

    // Doesn't pre-load the LlamaSession after download - that happens
    // lazily on first summarize, so Settings doesn't wait through model-init.
    func download() {
        error = nil
        progress = 0
        Task {
            do {
                _ = try await LLMModelManager.download { fraction in
                    Task { @MainActor in self.progress = fraction }
                }
                self.progress = nil
                self.refresh()
            } catch {
                self.progress = nil
                self.error = friendlyDownloadError(error)
            }
        }
    }

    func delete() {
        let log = Logger(subsystem: "com.arunbrahma.hello", category: "summarizer")
        log.info("Gemma delete: starting.")

        let appleFallbackUsable: Bool
        if #available(macOS 26.0, *) {
            appleFallbackUsable = MeetingSummarizer.appleFoundationAvailable
        } else {
            appleFallbackUsable = false
        }
        log.info("Gemma delete: Apple FM fallback usable = \(appleFallbackUsable, privacy: .public)")

        Task { @MainActor in
            // Unload first - a cached session pointing at deleted weights
            // would be reused by the next generation, and leak ~3.3GB.
            await summarizer.unload()
            log.info("Gemma delete: in-memory unload complete; about to remove on-disk weights.")

            do {
                try LLMModelManager.delete()
                log.info("Gemma delete: on-disk weights removed.")
            } catch {
                log.error(
                    "Gemma delete: removeItem failed: \(error.localizedDescription, privacy: .public)")
                NSAlert(error: error).runModal()
                return
            }

            if appleFallbackUsable {
                SettingsStore.shared.summaryBackend = .appleFoundation
                log.info("Gemma delete: backend preference switched to Apple FM.")
            } else {
                SettingsStore.shared.summarizeMeetings = false
                log.info("Gemma delete: no backend left, summarize toggle turned off.")
            }

            refresh()
            log.info("Gemma delete: done.")
        }
    }
}
