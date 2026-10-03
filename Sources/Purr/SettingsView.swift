import SwiftUI
import os.log

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var modelVM = ModelPickerViewModel()
    @StateObject private var diarizerVM: FluidModelViewModel
    // EOU install state drives both the Smart Typing toggle's enabled gate and
    // the EOU card. The card downloads/deletes via the coordinator (so warm-up
    // and the button share one progress source) and writes the result back here.
    @State private var eouInstalled = ParakeetEngine.eouIsInstalled()
    // Shares the one Gemma model with the meeting summary section.
    @StateObject private var voiceEditLLM = LLMSummaryViewModel()
    @State private var showResetConfirmation = false
    @State private var showLanguagePicker = false
    @State private var showDeleteModelsConfirmation = false
    @State private var isDeletingModels = false
    @State private var deleteModelsError: String?
    @State private var deleteErrorToken = 0
    // Observed so the Delete Models gate reacts live to Parakeet / EOU download
    // progress, which are @Published on the coordinator.
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
                        // Smart Typing inserts live at the cursor, so it's a
                        // form of auto-insertion - it can't run while auto-paste
                        // is off. Force it off so it never sits on-but-inert.
                        if !isOn { settings.smartTyping = false }
                    }
            }

            Section("Smart Typing") {
                Toggle("Smart Typing", isOn: $settings.smartTyping)
                    .disabled(!engineSupportsStreaming || !eouInstalled || !settings.autoPaste)
                    .help(smartTypingHelpText)
                Toggle("Stream directly at cursor", isOn: $settings.streamAtCursor)
                    .disabled(!settings.smartTyping || !engineSupportsStreaming || !eouInstalled
                        || !settings.autoPaste || !coordinator.safeToQuit)
                if settings.streamAtCursor {
                    Text("Insert live words as spoken, with no floating preview. Filler cleanup, dictionary replacements, and voice commands stay in phrase mode. Insertion stops if you click, type, or switch fields.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                    // Whisper has no streaming engine; clear the toggle so
                    // it doesn't stay "on" with no effect. Switching back
                    // to Parakeet doesn't re-enable it - explicit opt-in.
                    if newValue == .whisper {
                        settings.smartTyping = false
                        // If the persisted Whisper model can't translate
                        // (Turbo or any English-only build), force Translate
                        // off so the toggle isn't stuck on against a row
                        // that disables it.
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
                                // Picking a model that can't translate
                                // (English-only or Turbo) forces the toggle
                                // off so it can't sit stale-on against a
                                // disabled control.
                                if !choice.supportsTranslation {
                                    settings.translateToEnglish = false
                                }
                                coordinator.reloadEngine()
                                // Auto-download when the user picks a model
                                // that isn't on disk. The engine reload above
                                // will fail-soft until the weights land.
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
                fluidModelCard(
                    name: "Diarization",
                    size: "~21 MB",
                    note: "Meeting speaker attribution. Records who said what.",
                    vm: diarizerVM
                )
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

    // Voice editing requires an LLM backend. When Apple's built-in model is
    // the backend nothing is shown; otherwise this shows the downloaded Gemma
    // model, or - when no backend is set up - a note pointing to the meeting
    // summary section, which downloads the same Gemma weights. We don't offer a
    // second Download button here so two sections can't race on the one file.
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

                // Points to the meeting summary section instead of a second
                // Download button: it's the same Gemma file, and that section
                // already owns the download (progress, retry, license notice).
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
                    "Remove every downloaded model to reclaim disk space: Parakeet, the Whisper models, the diarizer, and the Gemma 3 4B model. Your meeting transcripts and preferences are kept."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                if isDeletingModels {
                    // The button is replaced by an in-progress indicator while
                    // the delete runs, rather than a disabled button + spinner.
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

    // True while any model is downloading - Parakeet TDT v2, EOU, a Whisper
    // checkpoint, the diarizer, or Gemma. Gates the Delete Models button so a
    // wipe can't pull weights out from under an in-flight download.
    private var anyModelDownloading: Bool {
        coordinator.parakeetBatchProgress != nil
            || coordinator.eouDownloadProgress != nil
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

    // Shows a Delete Models notice that clears itself after a few seconds so a
    // transient "busy" message doesn't linger after the condition has cleared.
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
                        // The bar below shows progress; we don't print a numeric
                        // percent - a multi-file download's fraction jumps around
                        // and reads as misleading.
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
        return "Choose live insertion at your cursor, or preview and insert complete phrases."
    }

    private var engineSupportsStreaming: Bool {
        settings.engine == .parakeet
    }

    // The Translate toggle is meaningful only on a multilingual, non-turbo
    // Whisper model. Mirrors WhisperEngine's runtime gate so the UI never
    // offers an option the engine would ignore. Drives the toggle's
    // enabled state and the Source Language picker's visibility.
    private var selectedModelSupportsTranslation: Bool {
        ModelManager.supportsTranslation(settings.modelName)
    }

    // Compact row that opens a modal sheet owning the search and full
    // 100-language list.
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
                selection: $settings.translationSourceLanguage,
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
// Parakeet engine card - Engine tab. Unlike the EOU / diarizer cards (which
// only download on an explicit tap), Parakeet TDT v2 also auto-downloads
// during warm-up, so its progress comes from the coordinator's shared download
// state rather than a per-button view model. That's what lets an auto-download
// show a live progress bar here, not just a manual Download tap.
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
            // A download just finished (or was cleared); re-check disk so the
            // card flips to Delete / Download correctly.
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
// Parakeet EOU 120M card - Smart Typing section (General tab). Like the
// Parakeet engine card, the EOU model auto-downloads during warm-up (gated on
// Smart Typing being on), so its progress comes from the coordinator's shared
// download state - that's what shows a bar for an auto-download, not just a
// manual Download tap. `isInstalled` is bound to the parent so the Smart Typing
// toggle's enabled gate tracks the same state.
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
                // Explicit fetch, separate from the row-tap that also selects.
                // Lets users pre-download a model without switching to it, and
                // recover when an auto-download didn't kick off.
                Button("Download", action: onDownload).controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        // The whole row is one tap target for selection. Clicking on a
        // not-yet-downloaded model selects it AND kicks off the download.
        // Disabled while a download is already in flight to avoid double
        // taps queueing two HF pulls.
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
    // Per-model failure state. Inline on the row instead of a modal alert
    // so the user can compare options, switch models, or retry without
    // dismissing a system dialog. Cleared on a successful retry; persists
    // across tab switches.
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

// Map raw URLSession / POSIX errors to short, actionable copy.
// Anything we don't recognise falls through to the system-provided
// localizedDescription so we never swallow a useful message.
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
// Meeting summary section - LLM picker + auto-summarize toggle. Lives
// on the Features tab. The Gemma model is downloaded lazily on first
// real meeting summarization, but exposing a Download button here lets
// users pre-fetch the ~2.5 GB weights at a convenient time.
// ----------------------------------------------------------------------

private struct MeetingSummarySection: View {
    @ObservedObject private var settings = SettingsStore.shared
    // Shared with SettingsView's voiceEditLLM (the one Gemma VM) so this
    // section's download progress is the same instance the Delete Models gate
    // (anyModelDownloading) observes - otherwise a wipe could fire mid-download.
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
        // Re-read the model's on-disk state whenever this section appears, so
        // the Gemma row reflects reality after a download or a Delete Models
        // wipe (which lives on a different tab). The other cards already do this.
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

        // Gemma flow-down notice. Required by the Gemma Terms of Use
        // when exposing the model's functionality through a UI.
        Label {
            (Text("Gemma 3 is provided under the ")
                + Text(LLMModelManager.licenseName).underline()
                + Text(". Downloading the model accepts those terms."))
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

    // True when Apple FM is the active backend in the UI. On macOS < 26
    // it can't be selected at all; on macOS 26+ it's the default and
    // only gets unselected when the user explicitly picks Gemma.
    private var appleSelected: Bool {
        vm.appleFoundationAvailable && settings.summaryBackend == .appleFoundation
    }

    // True when Gemma is the active backend in the UI. Gemma is only
    // "active" when actually installed - selecting it without weights
    // on disk is a no-op (the row triggers a download instead).
    private var gemmaSelected: Bool {
        if !vm.appleFoundationAvailable {
            // No Apple FM on this system; Gemma is the only option,
            // and visibly "selected" once it's downloaded.
            return vm.isInstalled
        }
        return settings.summaryBackend == .llamaCpp && vm.isInstalled
    }

    // macOS 26+ path: Apple Intelligence is on, no download needed.
    // Tap to make it the active backend.
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

    // Shown in place of the Apple FM card when the system can't reach it
    // (pre-Tahoe macOS, Apple Intelligence off, unsupported locale, or an
    // ineligible Mac). Surfaces every requirement and a one-tap deep link
    // into the right System Settings pane so users don't have to hunt.
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
                    // Opens macOS 26 Tahoe's "Apple Intelligence & Siri" pane.
                    // The legacy com.apple.preference.assistant id now lands on
                    // General instead, so we use the Settings-extension bundle
                    // id that targets the right pane on Tahoe.
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

    // Gemma 3 4B (Q4_K_M GGUF, llama.cpp). Selectable only after the
    // weights are on disk; tapping the row before that triggers a
    // download instead of changing the active backend, so we never
    // silently no-op on the next meeting.
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
                // Always offer Delete when weights are on disk -
                // including when Gemma is the active backend - so the
                // user can reclaim the ~2.5 GB without first switching
                // to Apple FM (or, on systems where Apple FM is
                // unavailable, ever). vm.delete() does the right thing
                // with the summarize toggle and backend preference.
                Button("Delete", role: .destructive) { vm.delete() }
                    .controlSize(.small)
            } else if vm.progress == nil {
                // Explicit fetch affordance, like the Whisper/Parakeet rows -
                // clearer than relying on the row tap when nothing has
                // auto-downloaded.
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
    // Last download failure, surfaced inline on the Gemma row instead
    // of as a modal alert. Cleared on the next retry; persists across
    // tab switches so the user can compare backends without losing the
    // error context.
    @Published var error: String? = nil

    // True when at least one backend is ready right now: Apple
    // Foundation Model on macOS 26+ with AI on, or Gemma weights cached
    // on disk.
    var canSummarize: Bool { appleFoundationAvailable || isInstalled }

    // Shared with AppCoordinator so a download here warms the same
    // session that a meeting will use a moment later, and a delete here
    // releases that session without a stale copy lingering elsewhere.
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

    // Pulls the GGUF into ~/Library/Application Support/Purr/models/
    // with progress reporting. We deliberately don't pre-load the
    // LlamaSession after download - that happens lazily on first
    // summarize so the user doesn't wait through a model-init delay in
    // Settings.
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
        let log = Logger(subsystem: "com.arunbrahma.purr", category: "summarizer")
        log.info("Gemma delete: starting.")

        let appleFallbackUsable: Bool
        if #available(macOS 26.0, *) {
            appleFallbackUsable = MeetingSummarizer.appleFoundationAvailable
        } else {
            appleFallbackUsable = false
        }
        log.info("Gemma delete: Apple FM fallback usable = \(appleFallbackUsable, privacy: .public)")

        Task { @MainActor in
            // Release the in-memory LlamaSession FIRST. If we removed the
            // on-disk weights but left the session cached, the next
            // generation would reuse a session pointing at deleted files -
            // and we'd also leak ~2.5 GB of unified memory.
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
