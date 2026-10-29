import AppKit
import SwiftUI

// Settings as a System Settings-style sidebar of panes. Rows stay one line:
// what a setting does lives in its tooltip, and a disabled one says why
// under its name. Every model's state comes from ModelStore, which re-reads
// the disk while the window is open. Until first-launch setup is done, the
// window shows that (OnboardingView) instead.
struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var models: ModelStore
    @ObservedObject private var settings = SettingsStore.shared
    @State private var pane: SettingsPane? = .general

    // Shows General, where missing permissions are listed.
    static let showPermissions = Notification.Name("com.arunbrahma.hello.showPermissions")

    var body: some View {
        Group {
            if settings.onboardingDone {
                NavigationSplitView {
                    List(SettingsPane.allCases, selection: $pane) { pane in
                        Label(pane.title, systemImage: pane.symbol)
                    }
                    .navigationSplitViewColumnWidth(190)
                    .toolbar(removing: .sidebarToggle)
                } detail: {
                    switch pane ?? .general {
                    case .general: GeneralPane(coordinator: coordinator, models: models)
                    case .engine: EnginePane(coordinator: coordinator, models: models)
                    case .meetings: MeetingsPane(coordinator: coordinator, models: models)
                    case .voiceEdit: VoiceEditPane(coordinator: coordinator, models: models)
                    case .vocabulary: VocabularyPane()
                    case .models: ModelsPane(models: models)
                    }
                }
            } else {
                OnboardingView(coordinator: coordinator, models: models)
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .onReceive(NotificationCenter.default.publisher(for: Self.showPermissions)) { _ in
            pane = .general
        }
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, engine, meetings, voiceEdit, vocabulary, models

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .engine: return "Engine"
        case .meetings: return "Meetings"
        case .voiceEdit: return "Voice Edit"
        case .vocabulary: return "Vocabulary"
        case .models: return "Models"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .engine: return "waveform"
        case .meetings: return "person.2"
        case .voiceEdit: return "pencil"
        case .vocabulary: return "character.book.closed"
        case .models: return "internaldrive"
        }
    }
}

// ----------------------------------------------------------------------
// General - the dictation shortcut, how text is inserted, clean-up
// ----------------------------------------------------------------------

private struct GeneralPane: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var models: ModelStore
    @StateObject private var permissions = PermissionsModel()
    // Read as the pane opens (setup skipped, or a switch turned off in System
    // Settings since) and kept for the visit, so each row can show Allowed.
    @State private var showsPermissions = !Permissions.allGranted()
    @State private var confirmingReset = false

    var body: some View {
        Form {
            if showsPermissions {
                Section("Permissions") {
                    ForEach(Permissions.required) { kind in
                        PermissionRow(kind: kind, model: permissions)
                    }
                }
            }

            Section("Dictation") {
                ShortcutPicker(
                    hotkey: $settings.hotkey,
                    presets: [
                        .defaultRightOption,
                        Hotkey(keyCode: nil, modifiers: .maskCommand),
                        Hotkey(keyCode: 96, modifiers: []),
                        Hotkey(keyCode: 49, modifiers: [.maskControl, .maskAlternate]),
                    ],
                    onChange: { coordinator.reinstallHotkey() }
                )
                Picker("Mode", selection: $settings.hotkeyMode) {
                    ForEach(SettingsStore.HotkeyMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Hold the shortcut while you talk, or tap it to start and again to stop.")
            }

            Section("Typing") {
                Toggle("Paste at cursor", isOn: $settings.autoPaste)
                    .help("Types the text where your cursor is. Off: copies it to the clipboard instead.")
                    .onChange(of: settings.autoPaste) { _, isOn in
                        // Smart Typing is a form of auto-insertion - force it
                        // off too, rather than leaving it on-but-inert.
                        if !isOn { settings.smartTyping = false }
                    }
                Toggle(isOn: $settings.smartTyping) {
                    Text("Smart Typing")
                    if let blocker = smartTypingBlocker {
                        Text(blocker)
                    }
                }
                .disabled(smartTypingBlocker != nil)
                .help("Shows your words as you speak and types each sentence when you pause.")
                if settings.engine == .parakeet, settings.autoPaste, models[.smartTyping].needsAttention {
                    ModelRow(kind: .smartTyping, models: models)
                }
            }

            Section("Clean Up") {
                Toggle("Remove filler words", isOn: $settings.trimFillers)
                    .help("Drops “um”, “uh” and the filler words you add in Vocabulary.")
                Toggle("Voice commands", isOn: $settings.voiceCommands)
                    .help("Say “new line”, “comma” or “scratch that”, plus your own commands from Vocabulary.")
            }

            Section {
                LabeledContent("Reset all settings") {
                    Button("Reset…") { confirmingReset = true }
                }
                .help("Restores every preference. Downloaded models stay on this Mac.")
            }
        }
        .formStyle(.grouped)
        .onAppear { if showsPermissions { permissions.start() } }
        .onDisappear { permissions.stop() }
        .onChange(of: permissions[.accessibility]) { _, status in
            if status == .granted { coordinator.installHotkeysIfNeeded() }
        }
        .confirmationDialog("Reset all Purr settings?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) {
                settings.resetToDefaults()
                coordinator.reloadEngine()
                coordinator.reinstallHotkey()
            }
        } message: {
            Text("Downloaded models stay on this Mac.")
        }
    }

    private var smartTypingBlocker: String? {
        if settings.engine != .parakeet { return "Needs the Parakeet engine" }
        if !settings.autoPaste { return "Needs Paste at cursor" }
        if !models[.smartTyping].isOnDisk { return "Download its model below" }
        return nil
    }
}

// ----------------------------------------------------------------------
// Engine - Parakeet or Whisper, and the model each runs
// ----------------------------------------------------------------------

private struct EnginePane: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var models: ModelStore
    @State private var pickingLanguage = false

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: Binding(get: { settings.engine }, set: { select($0) })) {
                    Text("Parakeet").tag(SettingsStore.Engine.parakeet)
                    Text("Whisper").tag(SettingsStore.Engine.whisper)
                }
                .pickerStyle(.segmented)
                .help(
                    "Parakeet: English, fastest, types as you speak. Whisper: 100+ languages, can translate to English."
                )
                if settings.engine == .parakeet {
                    if models[.parakeet].needsAttention {
                        ModelRow(kind: .parakeet, models: models)
                    } else {
                        LabeledContent("Model", value: ModelKind.parakeet.title)
                    }
                } else {
                    // Picking a model that isn't on disk starts its download,
                    // shown in the row below; the Models pane manages the rest.
                    Picker("Model", selection: Binding(get: { settings.modelName }, set: { select($0) })) {
                        ForEach(ModelManager.curatedModels) { choice in
                            Text(choice.label).tag(choice.id)
                        }
                    }
                    .help(ModelManager.curatedModels.first { $0.id == settings.modelName }?.note ?? "")
                    if models[.whisper(settings.modelName)].needsAttention {
                        ModelRow(kind: .whisper(settings.modelName), models: models)
                    }
                }
            }

            if settings.engine == .whisper {
                Section("Translation") {
                    Toggle(isOn: $settings.translateToEnglish) {
                        Text("Translate to English")
                        if !selectedModelSupportsTranslation {
                            Text("Needs Base, Small or Large V3")
                        }
                    }
                    .disabled(!selectedModelSupportsTranslation)
                    .help("Speak any language; Whisper writes the transcript in English.")
                    if selectedModelSupportsTranslation, settings.translateToEnglish {
                        LanguageRow(
                            title: "Spoken language",
                            value: WhisperLanguage.named(settings.translationSourceLanguage).name
                        ) { pickingLanguage = true }
                        .help("Auto-detect can misread short clips. Pick the language for reliable results.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $pickingLanguage) {
            LanguagePickerSheet(
                title: "Spoken Language",
                selection: $settings.translationSourceLanguage,
                allLanguages: WhisperLanguage.all,
                matching: WhisperLanguage.matching,
                onClose: { pickingLanguage = false }
            )
        }
    }

    // Mirrors WhisperEngine's runtime gate so the UI never offers an option
    // the engine would ignore.
    private var selectedModelSupportsTranslation: Bool {
        ModelManager.supportsTranslation(settings.modelName)
    }

    private func select(_ engine: SettingsStore.Engine) {
        guard settings.engine != engine else { return }
        settings.switchEngine(to: engine)
        coordinator.reloadEngine()
    }

    private func select(_ modelName: String) {
        let kind = ModelKind.whisper(modelName)
        if settings.modelName == modelName, models[kind].isOnDisk { return }
        settings.modelName = modelName
        if !ModelManager.supportsTranslation(modelName) {
            settings.translateToEnglish = false
        }
        coordinator.reloadEngine()
        // Auto-download if not on disk; the reload above fails soft until the
        // weights land.
        if !models[kind].isOnDisk {
            models.download(kind)
        }
    }
}

// ----------------------------------------------------------------------
// Meetings - recording, transcript, summary
// ----------------------------------------------------------------------

private struct MeetingsPane: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var models: ModelStore
    @State private var pickingLanguage = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    isOn: Binding(
                        get: { settings.meetingEnabled },
                        set: { newValue in
                            settings.meetingEnabled = newValue
                            coordinator.reinstallHotkey()
                        }
                    )
                ) {
                    Text("Meeting recording")
                    if !models[.diarizer].isOnDisk {
                        Text("Download the speaker model below")
                    }
                }
                .disabled(!models[.diarizer].isOnDisk)
                .help(
                    "Tap the shortcut to start and stop. Purr saves a Markdown transcript of who said what."
                )
                if models[.diarizer].needsAttention {
                    ModelRow(kind: .diarizer, models: models)
                }
                if settings.meetingEnabled {
                    ShortcutPicker(
                        hotkey: $settings.meetingHotkey,
                        presets: [
                            .defaultMeeting,
                            Hotkey(keyCode: 15, modifiers: [.maskControl, .maskAlternate]),
                            Hotkey(keyCode: 101, modifiers: []),
                        ],
                        onChange: { coordinator.reinstallHotkey() }
                    )
                }
            }

            Section("Transcript") {
                LanguageRow(title: "Language", value: ParakeetLanguage.named(settings.meetingLanguage).name) {
                    pickingLanguage = true
                }
                .help("English uses Parakeet v2. Other languages use the multilingual Parakeet v3.")
                if !settings.meetingLanguage.isEmpty, models[.parakeetMultilingual].needsAttention {
                    ModelRow(kind: .parakeetMultilingual, models: models)
                        .help("Needed for this language. Downloads on your next meeting if you skip it.")
                }
                MeetingsFolderRow()
                Toggle("Keep audio", isOn: $settings.saveMeetingAudio)
                    .disabled(!settings.meetingEnabled)
                    .help("Saves a compressed .m4a next to each transcript, to check or re-transcribe later.")
                Toggle("Recording indicator", isOn: $settings.showMeetingHUD)
                    .disabled(!settings.meetingEnabled)
                    .help(
                        "A floating “Meeting · 0:00” pill with a live waveform. The menu bar shows the recording either way."
                    )
            }

            Section {
                Toggle(isOn: $settings.summarizeMeetings) {
                    Text("Summarize meetings")
                    if !canSummarize {
                        Text("Download Gemma below")
                    }
                }
                .disabled(!canSummarize)
                .help("Writes a .summary.md with a TL;DR, decisions and action items. Runs on this Mac.")
                if models.appleIntelligenceAvailable {
                    Picker("Model", selection: $settings.summaryBackend) {
                        Text("Apple Intelligence").tag(SettingsStore.SummaryBackend.appleFoundation)
                        Text(ModelKind.gemma.title).tag(SettingsStore.SummaryBackend.llamaCpp)
                    }
                    .help("Apple's model is built into macOS. Gemma is a 3.35 GB download.")
                } else {
                    AppleIntelligenceUnavailableRow()
                }
                if showsGemma {
                    ModelRow(kind: .gemma, models: models)
                }
            } header: {
                Text("Summary")
            } footer: {
                if showsGemma {
                    GemmaLicenseNote()
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $pickingLanguage) {
            LanguagePickerSheet(
                title: "Meeting Language",
                selection: $settings.meetingLanguage,
                allLanguages: ParakeetLanguage.all,
                matching: ParakeetLanguage.matching,
                onClose: { pickingLanguage = false }
            )
        }
    }

    private var canSummarize: Bool {
        models.appleIntelligenceAvailable || models[.gemma].isOnDisk
    }

    private var showsGemma: Bool {
        !models.appleIntelligenceAvailable || settings.summaryBackend == .llamaCpp
    }
}

// Shows the full location in both states rather than a "Default" label.
private struct MeetingsFolderRow: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        let isDefault = settings.meetingsFolderPath.isEmpty
        let path = isDefault ? SettingsStore.defaultMeetingsDirectory.path : settings.meetingsFolderPath
        LabeledContent("Save to") {
            HStack(spacing: 8) {
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .help(path)
                if !isDefault {
                    Button {
                        settings.meetingsFolderPath = ""
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Use the default folder")
                }
                Button("Choose…") { MeetingsFolder.choose() }
            }
        }
    }
}

private struct AppleIntelligenceUnavailableRow: View {
    var body: some View {
        LabeledContent {
            if #available(macOS 26.0, *) {
                Button("Open Settings") {
                    // The legacy com.apple.preference.assistant id now lands
                    // on General; this targets Tahoe's Apple Intelligence & Siri pane.
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } label: {
            Text("Apple Intelligence")
            Text("Not available on this Mac")
        }
        .help(
            "Needs macOS 26 on Apple Silicon with Apple Intelligence on, and both the Mac and Siri set to English (United States). Restart your Mac after changing the language."
        )
    }
}

// Names the weights' license before they download.
private struct GemmaLicenseNote: View {
    var body: some View {
        Text(
            LocalizedStringKey(
                "Gemma 4 is provided by Google under the [\(LLMModelManager.licenseName)](\(LLMModelManager.licenseURL.absoluteString))."
            )
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// ----------------------------------------------------------------------
// Voice Edit - rewrite selected text by voice
// ----------------------------------------------------------------------

private struct VoiceEditPane: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var models: ModelStore

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Voice editing",
                    isOn: Binding(
                        get: { settings.voiceEditEnabled },
                        set: { newValue in
                            settings.voiceEditEnabled = newValue
                            coordinator.reinstallHotkey()
                        }
                    )
                )
                .help(
                    "Select text, hold the shortcut and say the change, like “make this shorter” or “change Friday to Monday”."
                )
                if settings.voiceEditEnabled {
                    ShortcutPicker(
                        hotkey: $settings.voiceEditHotkey,
                        presets: [
                            .defaultVoiceEdit,
                            Hotkey(keyCode: 9, modifiers: [.maskControl, .maskAlternate]),
                            Hotkey(keyCode: 100, modifiers: []),
                        ],
                        onChange: { coordinator.reinstallHotkey() }
                    )
                }
                LabeledContent("Model", value: modelName)
                    .help("Edits are understood by an AI model running on this Mac.")
                // One Gemma for summaries and edits - ModelStore runs a single
                // download whichever row starts it.
                if !models.appleIntelligenceAvailable, models[.gemma].needsAttention {
                    ModelRow(kind: .gemma, models: models)
                }
            }
        }
        .formStyle(.grouped)
    }

    // Matches EditInterpreter: Apple's model when it's available, else Gemma.
    private var modelName: String {
        if models.appleIntelligenceAvailable { return "Apple Intelligence" }
        return models[.gemma].isOnDisk ? ModelKind.gemma.title : "None"
    }
}

// ----------------------------------------------------------------------
// Vocabulary - spellings, custom voice commands, filler words
// ----------------------------------------------------------------------

private struct VocabularyPane: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("Replacements") {
                ForEach($settings.dictionary) { $entry in
                    PairRow(from: $entry.from, to: $entry.to, fromPrompt: "Heard as", toPrompt: "Write as") {
                        settings.dictionary.removeAll { $0.id == entry.id }
                    }
                }
                AddButton("Add Replacement") {
                    settings.dictionary.append(DictionaryEntry(from: "", to: ""))
                }
                .help("Fix how names, brands and acronyms are spelled in every transcript.")
            }

            Section {
                ForEach($settings.customVoiceCommands) { $entry in
                    PairRow(from: $entry.phrase, to: $entry.replacement, fromPrompt: "Say", toPrompt: "Type") {
                        settings.customVoiceCommands.removeAll { $0.id == entry.id }
                    }
                    .help("Type \\n for a new line, \\t for a tab.")
                }
                AddButton("Add Voice Command") {
                    settings.customVoiceCommands.append(VoiceCommandEntry(phrase: "", replacement: ""))
                }
                .help("Say a phrase to type text or a symbol.")
            } header: {
                Text("Voice Commands")
            } footer: {
                if !settings.voiceCommands {
                    Text("Voice commands are off in General.")
                }
            }

            Section {
                ForEach($settings.customFillerWords) { $entry in
                    HStack {
                        TextField("Filler word", text: $entry.word, prompt: Text("Word or phrase"))
                            .labelsHidden()
                        RemoveButton {
                            settings.customFillerWords.removeAll { $0.id == entry.id }
                        }
                    }
                }
                AddButton("Add Filler Word") {
                    settings.customFillerWords.append(FillerWordEntry(word: ""))
                }
                .help("Removed from every transcript, along with “um” and “uh”.")
            } header: {
                Text("Filler Words")
            } footer: {
                if !settings.trimFillers {
                    Text("Filler word removal is off in General.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PairRow: View {
    @Binding var from: String
    @Binding var to: String
    let fromPrompt: String
    let toPrompt: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(fromPrompt, text: $from, prompt: Text(fromPrompt))
                .labelsHidden()
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            TextField(toPrompt, text: $to, prompt: Text(toPrompt))
                .labelsHidden()
            RemoveButton(action: onRemove)
        }
    }
}

private struct RemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Remove")
    }
}

private struct AddButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
        }
        .buttonStyle(.borderless)
    }
}

// ----------------------------------------------------------------------
// Models - everything Purr has downloaded, in one place
// ----------------------------------------------------------------------

private struct ModelsPane: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject var models: ModelStore
    @State private var confirmingDeleteAll = false
    @State private var isDeletingAll = false
    @State private var deleteAllError: String?
    @State private var deleteAllErrorToken = 0

    var body: some View {
        Form {
            Section {
                LabeledContent("On this Mac") {
                    HStack(spacing: 10) {
                        Text(ByteCountFormatter.string(fromByteCount: models.totalBytesOnDisk, countStyle: .file))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([ModelManager.modelsDirectory])
                        }
                    }
                }
            }

            Section("Models") {
                ForEach([ModelKind.parakeet, .smartTyping, .parakeetMultilingual, .diarizer, .gemma]) { kind in
                    ModelRow(kind: kind, models: models, showsPurpose: true)
                }
            }

            Section("Whisper") {
                ForEach(ModelManager.curatedModels) { choice in
                    // The model in use can't be deleted out from under the engine.
                    let inUse = settings.engine == .whisper && settings.modelName == choice.id
                    ModelRow(kind: .whisper(choice.id), models: models, name: choice.label, canDelete: !inUse)
                }
            }

            Section {
                LabeledContent {
                    if isDeletingAll {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Delete All…", role: .destructive) { confirmingDeleteAll = true }
                            .disabled(models.isDownloading || models.totalBytesOnDisk == 0)
                    }
                } label: {
                    Text("Delete all models")
                    if let deleteAllError {
                        Text(deleteAllError)
                    } else if models.isDownloading {
                        Text("Wait for the download to finish")
                    }
                }
                .help("Frees the disk space. Transcripts and settings are kept.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all downloaded models?", isPresented: $confirmingDeleteAll) {
            Button("Delete All", role: .destructive) { deleteAll() }
        } message: {
            Text(
                "Smart Typing, meeting recording and Gemma summaries turn off. Transcripts and settings are kept."
            )
        }
    }

    private func deleteAll() {
        deleteAllError = nil
        isDeletingAll = true
        Task {
            let result = await models.deleteAll()
            isDeletingAll = false
            switch result {
            case .ok: break
            case .busy:
                showTransientError("Busy recording, transcribing or downloading. Try again in a moment.")
            case .failed(let error):
                showTransientError(error.localizedDescription)
            }
        }
    }

    // Clears itself after a few seconds so a "busy" message doesn't linger.
    private func showTransientError(_ message: String) {
        deleteAllError = message
        deleteAllErrorToken += 1
        let token = deleteAllErrorToken
        Task {
            try? await Task.sleep(for: .seconds(6))
            if deleteAllErrorToken == token { deleteAllError = nil }
        }
    }
}

// ----------------------------------------------------------------------
// Shared rows
// ----------------------------------------------------------------------

extension ModelStore.Status {
    // Worth a row in a feature's own pane: missing or downloading. The
    // Models pane lists every model either way.
    var needsAttention: Bool { !isOnDisk || download != nil }
}

extension ModelDownloadProgress {
    var label: String {
        switch stage {
        case .downloading:
            guard let fraction else { return "Downloading…" }
            return fraction.formatted(.percent.precision(.fractionLength(0)))
        case .compiling: return "Optimizing…"
        case .verifying: return "Verifying…"
        }
    }

    var detail: String {
        switch stage {
        case .downloading: return "Downloading from Hugging Face."
        case .compiling: return "Compiling the model for this Mac's Neural Engine."
        case .verifying: return "Checking the file's SHA-256 before it's used."
        }
    }
}

// One model: its name and size, then a Download button, a progress bar while
// it downloads, or a delete button once it's on this Mac.
struct ModelRow: View {
    let kind: ModelKind
    @ObservedObject var models: ModelStore
    // In place of kind.title, where a section already names the family.
    var name: String? = nil
    var showsPurpose = false
    var canDelete = true
    @State private var confirmingDelete = false

    var body: some View {
        let status = models[kind]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name ?? kind.title)
                    if showsPurpose {
                        Text(kind.purpose)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                trailing(status)
            }
            if let progress = status.download {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .help(progress.detail)
            }
            if let failure = status.failure {
                Label {
                    Text(failure.message).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .help(kind.purpose)
        .confirmationDialog("Delete \(kind.title)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { models.delete(kind) }
        } message: {
            Text("It can be downloaded again anytime.")
        }
    }

    @ViewBuilder
    private func trailing(_ status: ModelStore.Status) -> some View {
        if let progress = status.download {
            Text(progress.label)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else if status.isOnDisk {
            HStack(spacing: 8) {
                sizeText(status)
                if canDelete {
                    Button {
                        confirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete from this Mac")
                }
            }
        } else {
            HStack(spacing: 8) {
                sizeText(status)
                Button(status.failure?.duringDownload == true ? "Retry" : "Download") {
                    models.download(kind)
                }
                .controlSize(.small)
            }
        }
    }

    // What's on disk once measured, the download's size until then.
    private func sizeText(_ status: ModelStore.Status) -> some View {
        Text(ByteCountFormatter.string(fromByteCount: status.bytesOnDisk ?? kind.downloadBytes, countStyle: .file))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

// The presets as a menu, plus the current shortcut when it's none of them.
private struct ShortcutPicker: View {
    @Binding var hotkey: Hotkey
    let presets: [Hotkey]
    let onChange: () -> Void

    var body: some View {
        let options = presets.contains(hotkey) ? presets : [hotkey] + presets
        Picker(
            "Shortcut",
            selection: Binding(
                get: { options.firstIndex(of: hotkey) ?? 0 },
                set: { index in
                    hotkey = options[index]
                    onChange()
                }
            )
        ) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].displayName).tag(index)
            }
        }
    }
}

private struct LanguageRow: View {
    let title: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
