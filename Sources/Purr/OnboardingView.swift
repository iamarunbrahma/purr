import AppKit
import SwiftUI

// First-launch setup. It runs in the Settings window until it's finished, then
// that window turns into Settings and setup never shows again. Each step has a
// short explainer beside it, and the current step is saved, so a relaunch
// mid-setup reopens on it.
struct OnboardingView: View {
    let coordinator: AppCoordinator
    @ObservedObject var models: ModelStore
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var permissions = PermissionsModel()
    @State private var step = Step(rawValue: SettingsStore.shared.onboardingStep) ?? .welcome
    // The engine card picked, applied on Continue.
    @State private var engine = SettingsStore.shared.engine
    @State private var sample = ""
    @FocusState private var sampleFocused: Bool
    // The primary button sits in the same spot on every step, so a double
    // click would skip the next one - and the engine step starts a download.
    @State private var advancedAt = Date.distantPast

    private enum Step: Int {
        case welcome, engine, download, permissions, tryIt
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Button {
                    step = Step(rawValue: step.rawValue - 1) ?? .welcome
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.link)
                .opacity(step == .welcome ? 0 : 1)
                .disabled(step == .welcome)

                content

                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Button(primaryTitle, action: next)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            let info = explainer
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: info.symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                Text(info.title).font(.headline)
                Text(info.text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(width: 250, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .card()
            .padding(16)
        }
        .onAppear {
            // Launch skips warmup until setup is done. A relaunch past the
            // engine step still wants that model loaded for Try It.
            if step.rawValue > Step.engine.rawValue { useChosenEngine() }
        }
        .onChange(of: step) { _, step in settings.onboardingStep = step.rawValue }
        .onChange(of: permissions[.accessibility]) { _, status in
            if status == .granted { coordinator.installHotkeysIfNeeded() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
            heading(
                "Welcome to Purr",
                "Hold a key, talk, and Purr types what you said into whatever app you're in."
            )
            Text("Setup downloads a speech model (\(size(of: .parakeet))) from Hugging Face.")
                .foregroundStyle(.secondary)

        case .engine:
            heading("Choose a speech engine", "It turns your voice into text. You can switch later in Settings.")
            VStack(spacing: 10) {
                engineCard(
                    .parakeet, title: "Parakeet", detail: "English. The fastest, and it can type while you talk.")
                engineCard(.whisper, title: "Whisper", detail: "100+ languages. A little slower.")
            }

        case .download:
            let status = models[chosenModel]
            if status.isOnDisk, status.download == nil {
                heading("The speech model is ready", "It's on this Mac now, so Purr works offline.")
            } else if status.download == nil, status.failure != nil {
                heading("The download stopped", "Check your internet connection, then retry.")
            } else {
                heading(
                    "Downloading the speech model",
                    "It takes a minute or two. You can keep going while it downloads."
                )
            }
            ModelRow(kind: chosenModel, models: models, canDelete: false)
                .padding(12)
                .card()

        case .permissions:
            heading(
                "Allow access",
                "Purr asks for each one here. Accessibility takes one switch in System Settings, and Purr comes back by itself once it's on."
            )
            let kinds = Permissions.Kind.allCases.filter { permissions[$0] != nil }
            VStack(spacing: 0) {
                ForEach(kinds) { kind in
                    if kind != kinds.first { Divider().padding(.horizontal, 12) }
                    PermissionRow(kind: kind, model: permissions).padding(12)
                }
            }
            .card()
            .onAppear { permissions.start() }
            .onDisappear { permissions.stop() }

        case .tryIt:
            heading("Try it", tryInstruction)
            TextField("Your words show up here", text: $sample, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(4, reservesSpace: true)
                .focused($sampleFocused)
                .padding(10)
                .card()
                .onAppear { sampleFocused = true }
            if let note = tryNote {
                Text(note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.weight(.semibold))
            Text(detail)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func engineCard(_ choice: SettingsStore.Engine, title: String, detail: String) -> some View {
        let selected = engine == choice
        return Button {
            engine = choice
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(size(of: model(for: choice)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card(highlighted: selected)
    }

    private var explainer: (symbol: String, title: String, text: String) {
        switch step {
        case .welcome:
            return (
                "lock", "Stays on your Mac",
                "Purr turns your voice into text on this Mac. Nothing you say goes to a server, and it works offline once setup is done."
            )
        case .engine:
            return (
                "waveform", "Which one?",
                "Dictating in English? Parakeet is the quickest. Speaking other languages? Pick Whisper."
            )
        case .download:
            return (
                "arrow.down.circle", "Why a download?",
                "The speech model runs on your Mac, so it has to live on your Mac. Purr fetches it once, from Hugging Face. Models for other features download only if you turn those on."
            )
        case .permissions:
            return (
                "hand.raised", "What they're for",
                "Microphone lets Purr hear you. Accessibility lets it notice the shortcut in any app and type the text at your cursor. System audio is only for meetings, so notes include everyone on the call."
            )
        case .tryIt:
            return (
                "keyboard", "Works anywhere",
                "Purr types into any app with a text field. Change the shortcut, or switch to tapping it to start and stop, in Settings › General."
            )
        }
    }

    private var tryInstruction: String {
        let key = settings.hotkey.displayName
        switch settings.hotkeyMode {
        case .holdToTalk: return "Hold \(key) and say something, then let go. Your words show up below."
        case .toggle: return "Press \(key), say something, then press it again. Your words show up below."
        }
    }

    private var tryNote: String? {
        if !Permissions.allGranted() {
            return "The shortcut works once Microphone and Accessibility are allowed, on the step before."
        }
        let status = models[chosenModel]
        if let progress = status.download {
            return "The speech model is still downloading (\(progress.label)). Try it when that's done."
        }
        if !status.isOnDisk { return "The speech model isn't downloaded yet. Go back two steps to retry." }
        return nil
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: return "Get Started"
        case .tryIt: return "Finish"
        default: return "Continue"
        }
    }

    private func next() {
        guard Date().timeIntervalSince(advancedAt) > 0.5 else { return }
        advancedAt = Date()
        switch step {
        case .welcome: step = .engine
        case .engine:
            useChosenEngine()
            step = .download
        case .download: step = .permissions
        case .permissions: step = .tryIt
        case .tryIt:
            settings.onboardingStep = Step.welcome.rawValue
            settings.onboardingDone = true
        }
    }

    // Loads the chosen engine and starts its model's download, which on a
    // first launch waits for this step so the user picks what's fetched.
    private func useChosenEngine() {
        if settings.engine != engine { settings.switchEngine(to: engine) }
        coordinator.reloadEngine()
        if !models[chosenModel].isOnDisk { models.download(chosenModel) }
    }

    private var chosenModel: ModelKind { model(for: settings.engine) }

    private func model(for engine: SettingsStore.Engine) -> ModelKind {
        engine == .parakeet ? .parakeet : .whisper(settings.modelName)
    }

    private func size(of kind: ModelKind) -> String {
        ByteCountFormatter.string(fromByteCount: models[kind].bytesOnDisk ?? kind.downloadBytes, countStyle: .file)
    }
}

extension View {
    // The grouped-box look of Settings' rows, for setup's cards.
    fileprivate func card(highlighted: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        highlighted ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: highlighted ? 2 : 1)
            )
    }
}

// Live permission state for setup and Settings › General. Polls while shown,
// since macOS posts nothing when Microphone or system audio change, and brings
// Purr back to the front once Accessibility comes on in System Settings, so the
// user never has to find their way back.
@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var statuses: [Permissions.Kind: Permissions.Status] = [:]
    // Purr sent the user to System Settings for Accessibility...
    @Published private(set) var awaitingAccessibility = false
    // ...and they came back while it still reads off: either it isn't on yet,
    // or it is and this process can't see it, so the row offers both fixes.
    @Published private(set) var accessibilityStillOff = false
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() { refresh() }

    subscript(kind: Permissions.Kind) -> Permissions.Status? { statuses[kind] }

    func start() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // .common keeps it firing while the window is dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let app = NotificationCenter.default
        let active = app.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cameBack() }
        }
        let system = DistributedNotificationCenter.default()
        let changed = system.addObserver(forName: Permissions.accessibilityChanged, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                self?.refresh()
            }
        }
        observers = [(app, active), (system, changed)]
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    func refresh() {
        var next: [Permissions.Kind: Permissions.Status] = [:]
        for kind in Permissions.Kind.allCases { next[kind] = Permissions.status(kind) }
        if statuses != next { statuses = next }
        if awaitingAccessibility, next[.accessibility] == .granted {
            awaitingAccessibility = false
            accessibilityStillOff = false
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func request(_ kind: Permissions.Kind) {
        switch kind {
        case .microphone:
            Permissions.requestMicrophone { [weak self] _ in self?.refresh() }
        case .accessibility:
            awaitingAccessibility = true
            accessibilityStillOff = false
            Permissions.openSettings(for: kind)
        case .systemAudio:
            Permissions.requestSystemAudio { [weak self] in self?.refresh() }
        }
    }

    private func cameBack() {
        refresh()
        if awaitingAccessibility { accessibilityStillOff = true }
    }

    // For a grant this process can't see. A detached shell helper waits for
    // the current PID to exit, then re-opens the bundle, and setup reopens on
    // the same step. Surviving NSApp.terminate requires the helper to be
    // reparented away from us, which `Process` + a /tmp script achieves.
    func relaunch() {
        let appPath = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("purr-relaunch-\(UUID().uuidString).sh")
        // `open -n` forces a new instance. Without it LaunchServices can
        // briefly route back to the just-quit process's cached state,
        // defeating the relaunch.
        let script = """
            #!/bin/sh
            set -u
            i=0
            while kill -0 \(pid) 2>/dev/null; do
                i=$((i+1))
                if [ "$i" -gt 150 ]; then break; fi
                sleep 0.2
            done
            open -n "\(appPath)"
            """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = [scriptURL.path]
            try task.run()
        } catch {
            // Helper spawn failed; still quit and let the user re-open manually
            // rather than appearing stuck.
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.terminate(nil)
        }
    }
}

// One permission: what it's for, then Allow, or Allowed once macOS says so.
struct PermissionRow: View {
    let kind: Permissions.Kind
    @ObservedObject var model: PermissionsModel

    var body: some View {
        let status = model[kind]
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                Text(caption(status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch status {
            case .granted:
                Label {
                    Text("Allowed")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .foregroundStyle(.secondary)
            case .denied:
                Button("Open Settings") { Permissions.openSettings(for: kind) }
            case .notDetermined:
                if kind == .accessibility, model.awaitingAccessibility {
                    if model.accessibilityStillOff {
                        Button("Restart") { model.relaunch() }
                    }
                    Button("Open Settings") { model.request(kind) }
                } else {
                    Button("Allow") { model.request(kind) }
                }
            case nil:
                EmptyView()
            }
        }
        .controlSize(.small)
    }

    private func caption(_ status: Permissions.Status?) -> String {
        if status == .denied { return "Turned off in System Settings." }
        guard kind == .accessibility, status == .notDetermined, model.awaitingAccessibility else { return kind.why }
        return model.accessibilityStillOff
            ? "Turn on Purr in System Settings. Already on? Restart Purr."
            : "Turn on Purr in System Settings."
    }
}

// Picks the folder meeting transcripts save to, from Settings.
@MainActor
enum MeetingsFolder {
    static func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder to save meeting transcripts"
        if !SettingsStore.shared.meetingsFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: SettingsStore.shared.meetingsFolderPath, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            // Probe-write now to force any macOS file-access prompt in context
            // rather than silently at the first meeting-stop. On denial, keep
            // the previous setting instead of storing an unwritable path that
            // would later fall back to the default folder without explanation.
            if canWrite(to: url) {
                SettingsStore.shared.meetingsFolderPath = url.path
            } else {
                warnNotWritable(url)
            }
        }
    }

    // Writes and deletes a zero-byte probe file. The write is what triggers the
    // macOS prompt for protected folders, resolving consent at selection time.
    private static func canWrite(to dir: URL) -> Bool {
        let probe = dir.appendingPathComponent(".purr-write-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    private static func warnNotWritable(_ url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can't save meetings to that folder"
        alert.informativeText = """
            Purr couldn't write to "\(url.lastPathComponent)". If it's in your \
            Desktop, Documents, Downloads, or a cloud/removable drive, allow access \
            in System Settings › Privacy & Security › Files and Folders, then choose \
            it again. Until then, meetings keep saving to the default folder.
            """
        alert.runModal()
    }
}
