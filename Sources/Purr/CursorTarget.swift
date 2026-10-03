import AppKit
import ApplicationServices

// Capture once at hotkey press, before asynchronous model loading. A target
// that becomes invalid stays invalid until the next recording.
@MainActor
final class CursorTarget {
    enum Failure: LocalizedError {
        case unavailable, focusChanged, userEdited
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Click an editable text field before starting live insertion."
            case .focusChanged: return "Live insertion stopped because you changed apps or text fields."
            case .userEdited: return "Live insertion stopped because you clicked or typed. Start a new dictation to continue."
            }
        }
    }

    private let pid: pid_t
    private let element: AXUIElement
    private var inputMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private(set) var failure: Failure?

    init() throws {
        guard AXIsProcessTrusted(), let focused = Self.focusedElement(),
            let app = NSWorkspace.shared.frontmostApplication,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { throw Failure.unavailable }
        var subrole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole)
        guard (subrole as? String) != (kAXSecureTextFieldSubrole as String) else { throw Failure.unavailable }
        var focusedPID: pid_t = 0
        guard AXUIElementGetPid(focused, &focusedPID) == .success,
            focusedPID == app.processIdentifier else { throw Failure.unavailable }
        pid = app.processIdentifier
        element = focused
        let hotkey = SettingsStore.shared.hotkey
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            // The existing paste path emits Command-V. Ignore only our tagged
            // events, rather than ignoring every Command-V the user might type.
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == TextInserter.syntheticEventTag { return }
            let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
            if event.type == .keyDown, let code = hotkey.keyCode,
                Int64(event.keyCode) == code,
                event.cgEvent?.flags.intersection(modifiers) == hotkey.modifiers.intersection(modifiers)
            { return }
            self?.failure = self?.failure ?? .userEdited
        }
        guard inputMonitor != nil else { throw Failure.unavailable }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard let self, app.processIdentifier != self.pid else { return }
                self.failure = self.failure ?? .focusChanged
            }
        }
    }

    func isValid() -> Bool {
        if failure != nil { return false }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
            let focused = Self.focusedElement(), CFEqual(focused, element)
        else { failure = .focusChanged; return false }
        return true
    }

    func stop() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private static func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
}
