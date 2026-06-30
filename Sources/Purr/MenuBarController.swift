import AppKit
import Combine

// NSStatusItem-based menu bar surface. Icon reflects coordinator state so a
// glance at the top-right of the screen tells you whether Purr is idle,
// recording, or transcribing - even when the floating HUD is dismissed.
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private var stateCancellable: AnyCancellable?

    private let onShowAbout: () -> Void
    private let onShowSettings: () -> Void
    private let onShowOnboarding: () -> Void
    private let onQuit: () -> Void

    private lazy var iconIdle =
        templateImage(named: "purr_menubar_glyph", height: 18)
        ?? templateSymbol(named: "mic")
    private lazy var iconRecording = templateSymbol(named: "mic.fill")
    // Transcribing and meeting pair the speech glyph with a second symbol so a
    // glance distinguishes them from plain dictation: mic + waveform while a
    // transcript is being produced, mic + record-dot while a meeting records.
    private lazy var iconTranscribing = templateComposite(["mic", "waveform"])
    private lazy var iconMeeting = templateComposite(["mic.fill", "record.circle.fill"])
    private lazy var iconError = templateSymbol(named: "exclamationmark.triangle")

    init(
        coordinator: AppCoordinator,
        onShowAbout: @escaping () -> Void,
        onShowSettings: @escaping () -> Void,
        onShowOnboarding: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onShowAbout = onShowAbout
        self.onShowSettings = onShowSettings
        self.onShowOnboarding = onShowOnboarding
        self.onQuit = onQuit
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "com.arunbrahma.purr.statusItem"

        configureButton()
        rebuildMenu()

        // The coordinator folds dictation, voice-edit, and meeting activity
        // into one signal; we just map it to a glyph.
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

        menu.addItem(menuItem(title: "About Purr", selector: #selector(triggerAbout)))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Settings", selector: #selector(triggerSettings)))
        menu.addItem(menuItem(title: "Onboarding Setup", selector: #selector(triggerOnboarding)))
        menu.addItem(.separator())
        // The Quit key equivalent is cosmetic - it makes ⌃⌥Q visible next to
        // the item. The actual global hotkey is dispatched by HotkeyManager via
        // CGEventTap, and both paths converge on the same closure. Settings and
        // Onboarding Setup have no global hotkey, so they show no shortcut.
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

    @objc private func triggerAbout() { onShowAbout() }
    @objc private func triggerSettings() { onShowSettings() }
    @objc private func triggerOnboarding() { onShowOnboarding() }
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
    // (resolution-independent, stays crisp at any menu-bar scale) and falls back
    // to a PNG if present. isTemplate lets macOS tint it for light/dark bars and
    // the recording-state highlight exactly like the SF Symbol states. Returns
    // nil if no asset is found so the caller can fall back to a system symbol.
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

    // Draws several SF Symbols left-to-right into one image. Marking the result
    // isTemplate lets the menu bar tint it exactly like a single template
    // symbol, so the composite adapts to light/dark menu bars. The
    // drawingHandler re-renders at the display's scale (crisp on Retina); each
    // source symbol draws at its natural size so it matches the single-symbol
    // states, vertically centred against the tallest glyph.
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
