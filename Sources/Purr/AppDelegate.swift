import AppKit
import SwiftUI

// Owns long-lived singletons and does no work itself - the pipeline lives in
// AppCoordinator, the menu bar in MenuBarController, settings in SettingsStore.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator!
    private var menuBar: MenuBarController!
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AppCoordinator()
        menuBar = MenuBarController(
            coordinator: coordinator,
            onShowAbout: { [weak self] in self?.showAbout() },
            onShowSettings: { [weak self] in self?.showSettings() },
            onShowOnboarding: { [weak self] in self?.showOnboarding() },
            onQuit: { NSApp.terminate(nil) }
        )

        // The global Quit hotkey (⌃⌥Q) shares the status-bar item's closure, so
        // a hotkey press and a menu click are indistinguishable downstream.
        coordinator.setMenuActions(
            quit: { NSApp.terminate(nil) }
        )

        coordinator.start()

        if !SettingsStore.shared.onboardingDone || !Permissions.allGranted() {
            // First launch, or a permission was revoked in System Settings:
            // walk the user through the TCC prompts before they reach for a
            // hotkey that won't fire.
            showOnboarding()
        }
    }

    private func showOnboarding() {
        if let win = onboardingWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // onboardingWindow isn't assigned until below, so capture self and read
        // it lazily when the button fires.
        let view = OnboardingView(onFinish: { [weak self] in self?.onboardingWindow?.close() })
            .textSelection(.enabled)
        let host = NSHostingController(rootView: view)
        // OnboardingView pins its own width, so the ideal content size yields a
        // window sized exactly to the content - no clipping, no empty padding.
        host.sizingOptions = .preferredContentSize
        let win = NSWindow(contentViewController: host)
        win.title = "Welcome to Purr"
        win.styleMask = [.titled, .closable]
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = win
    }

    private func showAbout() {
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
        win.setContentSize(NSSize(width: 380, height: 320))
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow = win
    }

    private func showSettings() {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(coordinator: coordinator).textSelection(.enabled)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Purr - Settings"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.setContentSize(NSSize(width: 560, height: 600))
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = win
    }
}
