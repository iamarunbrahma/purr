import AppKit
import Combine
import SwiftUI

// Owns long-lived singletons and does no work itself - the pipeline lives in
// AppCoordinator, the menu bar in MenuBarController, settings in SettingsStore.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator!
    private var menuBar: MenuBarController!
    private var settingsWindow: NSWindow?
    private var settingsWindowStyle: AnyCancellable?
    private var modelStore: ModelStore?
    private var aboutWindow: NSWindow?
    private let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AppCoordinator()
        menuBar = MenuBarController(
            coordinator: coordinator,
            onShowAbout: { [weak self] in self?.showAbout() },
            onShowSettings: { [weak self] in self?.showSettings() },
            onShowPermissions: { [weak self] in
                self?.showSettings()
                NotificationCenter.default.post(name: SettingsView.showPermissions, object: nil)
            },
            onQuit: { NSApp.terminate(nil) }
        )

        // The global Quit hotkey (⌃⌥Q) shares the status-bar item's closure, so
        // a hotkey press and a menu click are indistinguishable downstream.
        coordinator.setMenuActions(
            quit: { NSApp.terminate(nil) }
        )

        coordinator.start()

        // Setup runs once, in the Settings window, which turns into Settings
        // when it's done. A permission turned off later shows up in the menu
        // and in Settings › General instead.
        if !SettingsStore.shared.onboardingDone {
            showSettings()
        }
    }

    // Every quit lands here - the menu's Quit Purr, ⌘Q, the updater, logging
    // out - so none can drop a recording unasked. A meeting lives only in
    // memory until it's transcribed, so Quit Anyway saves the audio of one
    // still recording or waiting on its transcript. It's the way out of a
    // transcription that never finishes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if coordinator == nil || coordinator.safeToQuit { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Purr?"
        alert.informativeText = quitWarning()
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        // Bring Purr forward first - as a menu-bar accessory app, the alert
        // would otherwise open behind whatever's frontmost.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        return .terminateNow
    }

    // Every quit that gets past the alert, or needed none, ends here: Quit
    // Anyway's meeting audio is saved, and meeting audio still being written
    // is finished. Synchronous, since .terminateLater hangs when the quit
    // itself comes from a main-actor task.
    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.saveMeetingAudioBeforeQuit()
    }

    @MainActor
    private func quitWarning() -> String {
        switch coordinator.meetingQuitStage {
        case .recording:
            return "Purr is still recording a meeting. Quitting now saves its audio without a transcript."
        case .transcribing:
            return "Purr is still transcribing a meeting. Quitting now saves its audio without a transcript."
        case .summarizing:
            return
                "Purr is still summarizing a meeting. Its transcript is saved, but quitting now skips the summary."
        case nil:
            return "Purr is still recording or transcribing. Quitting now loses that recording."
        }
    }

    private func showAbout() {
        Task { await updater.checkForUpdatesUnlessBusy() }
        if let win = aboutWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = AboutView(updater: updater, coordinator: coordinator).textSelection(.enabled)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "About Purr"
        win.styleMask = [.titled, .closable]
        // See showSettings.
        win.collectionBehavior = .moveToActiveSpace
        win.setContentSize(NSSize(width: 380, height: 320))
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow = win
    }

    @MainActor
    private func showSettings() {
        if let win = settingsWindow {
            modelStore?.startWatching()
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let models = ModelStore(coordinator: coordinator)
        let host = NSHostingController(rootView: SettingsView(coordinator: coordinator, models: models))
        // Sized by the window, so it can be resized past the view's minimum.
        host.sizingOptions = [.minSize]
        let win = NSWindow(contentViewController: host)
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // Activating Purr brings this window to the Space the user is on. By
        // default macOS would switch to the Space it was left on, and an
        // alert opened during that switch lands on the Space just left.
        win.collectionBehavior = .moveToActiveSpace
        // Setup's steps name themselves, so its title bar stays empty until
        // the window becomes Settings.
        settingsWindowStyle = SettingsStore.shared.$onboardingDone.sink { [weak win] done in
            win?.title = done ? "Purr Settings" : "Welcome to Purr"
            win?.titleVisibility = done ? .visible : .hidden
            win?.titlebarAppearsTransparent = !done
        }
        win.setContentSize(NSSize(width: 740, height: 560))
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        models.startWatching()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
        modelStore = models
    }
}

extension AppDelegate: NSWindowDelegate {
    // The Settings window is kept for reuse, so its disk polling stops here
    // and showSettings() restarts it.
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            modelStore?.stopWatching()
        }
    }
}
