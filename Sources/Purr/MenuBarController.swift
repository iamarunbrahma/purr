import AppKit
import Combine
import IOKit

// NSStatusItem-based menu bar surface. The icon reflects coordinator state so
// Purr's status is readable even when the floating HUD is dismissed.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private var stateCancellable: AnyCancellable?
    // Shown when Secure Input has knocked out a shortcut - otherwise it
    // silently does nothing. See menuNeedsUpdate(_:).
    private let secureInputTitle = NSMenuItem()
    private let secureInputDetail = NSMenuItem()
    private let secureInputSeparator = NSMenuItem.separator()
    private let blockedShortcuts: () -> [String]
    // Shown while Microphone or Accessibility is off, which leaves dictation
    // dead. Also re-checked in menuNeedsUpdate(_:).
    private let permissionsItem = NSMenuItem()
    private let permissionsSeparator = NSMenuItem.separator()

    private let onShowAbout: () -> Void
    private let onShowSettings: () -> Void
    private let onShowPermissions: () -> Void
    private let onQuit: () -> Void

    private lazy var iconIdle =
        templateImage(named: "purr_menubar_glyph", height: 18)
        ?? templateSymbol(named: "mic")
    private lazy var iconRecording = templateSymbol(named: "mic.fill")
    // Transcribing and meeting pair the speech glyph with a second symbol so a
    // glance distinguishes them from plain dictation.
    private lazy var iconTranscribing = templateComposite(["mic", "waveform"])
    private lazy var iconMeeting = templateComposite(["mic.fill", "record.circle.fill"])
    private lazy var iconError = templateSymbol(named: "exclamationmark.triangle")

    init(
        coordinator: AppCoordinator,
        onShowAbout: @escaping () -> Void,
        onShowSettings: @escaping () -> Void,
        onShowPermissions: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onShowAbout = onShowAbout
        self.onShowSettings = onShowSettings
        self.onShowPermissions = onShowPermissions
        self.onQuit = onQuit
        self.blockedShortcuts = { [weak coordinator] in coordinator?.shortcutsBlockedBySecureInput ?? [] }
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.autosaveName = "com.arunbrahma.purr.statusItem"

        configureButton()
        rebuildMenu()

        stateCancellable = coordinator.$menuBarStatus.sink { [weak self] status in
            self?.applyStatus(status)
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = iconIdle
        button.toolTip = "Purr - ready"
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        secureInputTitle.image = NSImage(
            systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        for item in [secureInputTitle, secureInputDetail, secureInputSeparator] {
            item.isEnabled = false
            item.isHidden = true
            menu.addItem(item)
        }

        permissionsItem.title = "Permissions Needed…"
        permissionsItem.action = #selector(triggerPermissions)
        permissionsItem.image = NSImage(
            systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        for item in [permissionsItem, permissionsSeparator] {
            item.isHidden = Permissions.allGranted()
            menu.addItem(item)
        }

        menu.addItem(menuItem(title: "About Purr", selector: #selector(triggerAbout)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Settings", selector: #selector(triggerSettings)))
        menu.addItem(.separator())
        // The Quit key equivalent is cosmetic - it only makes ⌃⌥Q visible. The
        // actual global hotkey is dispatched by HotkeyManager via CGEventTap,
        // and both paths converge on the same closure.
        menu.addItem(
            menuItem(
                title: "Quit Purr",
                selector: #selector(triggerQuit),
                keyEquivalent: "q",
                modifiers: [.control, .option]
            ))

        for item in menu.items where item.action != nil {
            item.target = self
        }

        statusItem.menu = menu
    }

    private func menuItem(
        title: String,
        selector: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    // Re-checked on every open. Under Secure Input HotkeyManager moves key
    // combinations to Carbon hotkeys, so this lists only the ones Carbon
    // refused because another app already owns them.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let granted = Permissions.allGranted()
        permissionsItem.isHidden = granted
        permissionsSeparator.isHidden = granted

        let blocked = blockedShortcuts()
        for item in [secureInputTitle, secureInputDetail, secureInputSeparator] {
            item.isHidden = blocked.isEmpty
        }
        guard !blocked.isEmpty else { return }
        secureInputTitle.title = "\(blocked.joined(separator: ", ")) blocked by Secure Input"
        let holder = Self.secureInputHolder() ?? "another app"
        secureInputDetail.title =
            holder == "loginwindow"
            ? "Held by loginwindow - log out or restart to clear it."
            : "Held by \(holder)."
    }

    // Name of the process holding Secure Input, from the console session's
    // IORegistry entry (where `ioreg -l | grep SecureInput` finds it).
    private static func secureInputHolder() -> String? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard
            let users = IORegistryEntryCreateCFProperty(
                root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [[String: Any]],
            let pid = users.lazy.compactMap({ $0["kCGSSessionSecureInputPID"] as? Int }).first
        else { return nil }
        return NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName
    }

    @objc private func triggerAbout() { onShowAbout() }
    @objc private func triggerSettings() { onShowSettings() }
    @objc private func triggerPermissions() { onShowPermissions() }
    @objc private func triggerQuit() { onQuit() }

    // ------------------------------------------------------------------
    // State icon
    // ------------------------------------------------------------------

    private func applyStatus(_ status: AppCoordinator.MenuBarStatus) {
        guard let button = statusItem.button else { return }
        switch status {
        case .idle:
            button.image = iconIdle
            button.toolTip = "Purr - ready"
        case .recording:
            button.image = iconRecording
            button.toolTip = "Purr - recording…"
        case .transcribing:
            button.image = iconTranscribing
            button.toolTip = "Purr - transcribing…"
        case .meeting:
            button.image = iconMeeting
            button.toolTip = "Purr - recording meeting…"
        case .error(let message):
            button.image = iconError
            button.toolTip = "Purr - \(message)"
        }
    }

    private func templateSymbol(named name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Purr status")
        image?.isTemplate = true
        return image
    }

    // Loads a bundled vector glyph as a menu-bar template image, scaled to
    // `height` points (width follows the asset's aspect ratio). Prefers the PDF
    // so it stays crisp at any menu-bar scale. isTemplate lets macOS tint it
    // like the SF Symbol states. Returns nil when no asset is found, so the
    // caller can fall back to a system symbol.
    private func templateImage(named name: String, height: CGFloat) -> NSImage? {
        let url = ["pdf", "png"].lazy
            .compactMap { Bundle.main.url(forResource: name, withExtension: $0) }
            .first
        guard let url, let image = NSImage(contentsOf: url), image.size.height > 0
        else { return nil }
        image.size = NSSize(width: height * image.size.width / image.size.height, height: height)
        image.isTemplate = true
        return image
    }

    // Draws several SF Symbols left-to-right into one image. isTemplate lets the
    // menu bar tint the composite like a single symbol; the drawingHandler
    // re-renders at the display's scale (crisp on Retina). Each source symbol
    // draws at its natural size so it matches the single-symbol states.
    private func templateComposite(_ names: [String]) -> NSImage? {
        let symbols = names.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: "Purr status")
        }
        guard !symbols.isEmpty else { return nil }
        let spacing: CGFloat = 3
        let height = symbols.map(\.size.height).max() ?? 0
        let width = symbols.map(\.size.width).reduce(0, +) + spacing * CGFloat(symbols.count - 1)
        let composite = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for symbol in symbols {
                let y = (height - symbol.size.height) / 2
                symbol.draw(at: NSPoint(x: x, y: y), from: .zero, operation: .sourceOver, fraction: 1)
                x += symbol.size.width + spacing
            }
            return true
        }
        composite.isTemplate = true
        return composite
    }
}
