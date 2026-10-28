import AppKit
import SwiftUI

// First-run setup: a three-step permissions walkthrough plus a picker for where
// meetings are saved. macOS offers no mass-prompt, so each toggle is explained
// and deeplinked to its System Settings pane, and the view polls every second.
//
// Microphone updates live. Accessibility and Input Monitoring do NOT: macOS
// only exposes those grants to a freshly launched process (AXIsProcessTrusted
// and IOHIDCheckAccess keep returning the stale pre-grant value for the life of
// the process - a known, unfixed macOS behaviour). So once the user has been
// sent to System Settings for those two, the row swaps its "Grant" button for
// "Restart": relaunching is the only way to pick the grant up.
struct OnboardingView: View {
    // Dismisses the window; the app keeps running in the menu bar.
    let onFinish: () -> Void

    @State private var status: [Permissions.Kind: Bool] = [:]
    @State private var pollTimer: Timer?
    @State private var observers: [NSObjectProtocol] = []
    // Permissions sent to System Settings whose result this process can't
    // observe until it relaunches.
    @State private var awaitingRestart: Set<Permissions.Kind> = []
    @ObservedObject private var settings = SettingsStore.shared

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                Text("Welcome to Purr")
                    .font(.title2.weight(.semibold))
            }

            VStack(spacing: 10) {
                ForEach(Permissions.Kind.allCases) { kind in
                    permissionRow(kind: kind)
                }
            }

            meetingsFolderRow

            systemAudioNote

            HStack {
                // The default (accented, right-hand) button is whichever step
                // actually moves the user forward: Restart while a grant is
                // invisible to this process, otherwise Start Using Purr.
                if restartPending {
                    Button("Start Using Purr") { finish() }
                    Spacer()
                    Button("Restart Purr") { quitAndRelaunch() }
                        .keyboardShortcut(.defaultAction)
                        .help(restartHelp)
                } else {
                    Button("Restart Purr") { quitAndRelaunch() }
                        .help(restartHelp)
                    Spacer()
                    Button("Start Using Purr") { finish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        // Pin the width so the view has one definite ideal size. Without it,
        // NSHostingController can't derive a stable window size from the
        // content (text views have no intrinsic width) and the window opens
        // oversized and empty. Height stays content-driven.
        .frame(width: 520)
        .onAppear {
            // Re-register the current binary's cdhash with TCC. Every ad-hoc
            // rebuild changes the cdhash, and without this the new binary is
            // either unlisted or shadowed by a stale "Purr" row that reads as
            // denied even with the toggle on. Prompts only the first time TCC
            // sees a given (bundleID, cdhash) pair.
            _ = Permissions.requestAccessibility()
            _ = Permissions.requestInputMonitoring()

            refresh()

            // Safety net for "user toggled the switch while onboarding was
            // open". .common runloop mode keeps the timer alive during window
            // dragging and modal sheets.
            let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in self.refresh() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer

            // Eager refresh when the user comes back from System Settings, so
            // green checks appear instantly rather than up to a poll later.
            let center = NotificationCenter.default
            let onKey = center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in self.refresh() }
            }
            let onActive = center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in self.refresh() }
            }
            observers = [onKey, onActive]
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
            for token in observers {
                NotificationCenter.default.removeObserver(token)
            }
            observers.removeAll()
        }
    }

    private func refresh() {
        for kind in Permissions.Kind.allCases {
            status[kind] = Permissions.isGranted(kind)
        }
    }

    // True while a grant made in System Settings is still invisible to this
    // process; the bottom bar leads with Restart until then.
    private var restartPending: Bool {
        awaitingRestart.contains { !(status[$0] ?? false) }
    }

    private var restartHelp: String {
        "If a permission stays grey after you toggled it on in System Settings, restart Purr so macOS re-reads the trust state for this process."
    }

    private func finish() {
        SettingsStore.shared.onboardingDone = true
        onFinish()
    }

    // A detached shell helper waits for the current PID to exit, then re-opens
    // the bundle. Surviving NSApp.terminate requires the helper to be
    // reparented away from us, which `Process` + a /tmp script achieves.
    private func quitAndRelaunch() {
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

    // System Audio Recording is not a fourth row: macOS exposes no API to
    // request or track it ahead of time, so this explains it and deep-links to
    // the pane. The real prompt fires on the first meeting recording.
    private var systemAudioNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(.top, 1)
            Text("Provide system audio recording access for Meeting Mode")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Open Settings") {
                Permissions.openSystemAudioSettings()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    // Optional: left unset, meetings save to the default Application Support
    // folder, which needs no file-access consent. A custom folder is stored as
    // a plain path - the app isn't sandboxed, so no security-scoped bookmark is
    // needed.
    private var meetingsFolderRow: some View {
        let isDefault = settings.meetingsFolderPath.isEmpty
        // Show the full location in both states rather than a "Default" label.
        let folderPath =
            isDefault
            ? SettingsStore.defaultMeetingsDirectory.path
            : settings.meetingsFolderPath
        let displayPath = (folderPath as NSString).abbreviatingWithTildeInPath
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .font(.title3)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Meetings folder").font(.body.weight(.medium))
                Text(displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Button("Choose…") { chooseMeetingsFolder() }
                    .controlSize(.small)
                if !isDefault {
                    Button("Use Default") { settings.meetingsFolderPath = "" }
                        .controlSize(.small)
                        .buttonStyle(.link)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func chooseMeetingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder to save meeting transcripts"
        if !settings.meetingsFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: settings.meetingsFolderPath, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            // Probe-write now to force any macOS file-access prompt in context
            // rather than silently at the first meeting-stop. On denial, keep
            // the previous setting instead of storing an unwritable path that
            // would later fall back to the default folder without explanation.
            if canWriteMeetings(to: url) {
                settings.meetingsFolderPath = url.path
            } else {
                warnFolderNotWritable(url)
            }
        }
    }

    // Writes and deletes a zero-byte probe file. The write is what triggers the
    // macOS prompt for protected folders, resolving consent at selection time.
    private func canWriteMeetings(to dir: URL) -> Bool {
        let probe = dir.appendingPathComponent(".purr-write-probe-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    private func warnFolderNotWritable(_ url: URL) {
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

    @ViewBuilder
    private func permissionRow(kind: Permissions.Kind) -> some View {
        let granted = status[kind] ?? false
        // macOS hides Accessibility / Input Monitoring grants from the running
        // process, so the row asks for a relaunch rather than pretending the
        // grant will appear.
        let needsRestart = !granted && awaitingRestart.contains(kind)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title3)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.body.weight(.medium))
                Text(kind.why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if needsRestart {
                Button("Restart") { quitAndRelaunch() }
                    .controlSize(.small)
            } else if !granted {
                Button("Grant") {
                    switch kind {
                    case .microphone:
                        // Status updates live here, so no restart is needed.
                        Permissions.grantMicrophone { refresh() }
                    case .accessibility:
                        // Request first to register the app in the Accessibility
                        // list, then open Settings to flip the toggle.
                        Permissions.requestAccessibility()
                        Permissions.openSettings(for: kind)
                        awaitingRestart.insert(kind)
                    case .inputMonitoring:
                        Permissions.requestInputMonitoring()
                        Permissions.openSettings(for: kind)
                        awaitingRestart.insert(kind)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }
}
