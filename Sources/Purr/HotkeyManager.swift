import AppKit
import Carbon.HIToolbox
import os.log

// Global hotkey via `CGEvent.tapCreate`. Carbon's `RegisterEventHotKey` is
// deliberately not used because:
//
//   - It can't fire on bare modifiers (e.g. hold Right Option alone), which is
//     the interaction users expect from a dictation app and requires watching
//     the raw event stream.
//   - It can't distinguish left from right modifier keys, only the logical
//     "any option/command/etc."
//
// CGEventTap sees the device-side code for each right modifier separately.
final class HotkeyManager {
    typealias Callback = () -> Void

    enum Action: Hashable {
        case transcribe
        case meetingToggle
        case voiceEdit
        case quit
    }

    struct Binding {
        let action: Action
        let hotkey: Hotkey
        let onPress: Callback
        let onRelease: Callback
    }

    private var bindings: [Binding] = []
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // Per-binding press state so two bindings stay independent - holding
    // voice-edit while dictation is in toggle mode must not interfere.
    private var heldDown: [Action: Bool] = [:]
    private var dictationSuspended = false

    private let log = Logger(subsystem: "com.arunbrahma.hello", category: "hotkey")

    // Right-side modifier device codes (NSEvent.keyCode on flagsChanged).
    // Hardcoded from IOHIDFamily because Carbon's kVK_* constants don't
    // distinguish sides.
    private static let kRightCommand: Int64 = 54
    private static let kRightShift: Int64 = 60
    private static let kRightOption: Int64 = 61
    private static let kRightControl: Int64 = 62

    init() {}

    deinit { uninstall() }

    func setBindings(_ new: [Binding]) {
        self.bindings = new
        self.heldDown = Dictionary(uniqueKeysWithValues: new.map { ($0.action, false) })
    }

    // Silences the dictation hotkey only (meeting + voice-edit still fire),
    // so a recording meeting can't leak a batch transcript into a window.
    func suspendDictation(_ suspend: Bool) {
        dictationSuspended = suspend
        if suspend { heldDown[.transcribe] = false }
    }

    func install() {
        uninstall()

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                    manager.handle(type: type, event: event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: userInfo
            )
        else {
            log.error("CGEvent.tapCreate failed - Input Monitoring permission probably not granted yet.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        log.info("Hotkey tap installed with \(self.bindings.count, privacy: .public) bindings.")
    }

    func uninstall() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        tap = nil
        runLoopSource = nil
        heldDown = heldDown.mapValues { _ in false }
    }

    // ------------------------------------------------------------------
    // Event handling
    // ------------------------------------------------------------------

    private func handle(type: CGEventType, event: CGEvent) {
        // The OS occasionally disables our tap (timeout, sleep). Re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        for binding in bindings {
            if dictationSuspended, binding.action == .transcribe { continue }
            if binding.hotkey.isBareModifier {
                handleBareModifier(type: type, event: event, binding: binding)
            } else {
                handleKeyCombination(type: type, event: event, binding: binding)
            }
        }
    }

    private func handleBareModifier(type: CGEventType, event: CGEvent, binding: Binding) {
        // Only flagsChanged events carry meaningful info for bare modifiers.
        guard type == .flagsChanged else { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let targetKeyCode = bareModifierTargetKeyCode(binding.hotkey)
        guard keyCode == targetKeyCode else { return }

        let modifierBit = bareModifierBit(binding.hotkey)
        let isDown = event.flags.contains(modifierBit)
        let wasDown = heldDown[binding.action] ?? false

        if isDown && !wasDown {
            heldDown[binding.action] = true
            log.debug(
                "Bare-modifier press: action=\(String(describing: binding.action), privacy: .public)")
            DispatchQueue.main.async { binding.onPress() }
        } else if !isDown && wasDown {
            heldDown[binding.action] = false
            log.debug(
                "Bare-modifier release: action=\(String(describing: binding.action), privacy: .public)"
            )
            DispatchQueue.main.async { binding.onRelease() }
        }
    }

    private func handleKeyCombination(type: CGEventType, event: CGEvent, binding: Binding) {
        guard let targetKeyCode = binding.hotkey.keyCode else { return }
        guard type == .keyDown || type == .keyUp else { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == targetKeyCode else { return }

        let wasDown = heldDown[binding.action] ?? false

        if type == .keyUp {
            // A keyUp ends the hold regardless of modifier state at release
            // time. Users routinely lift the modifiers a few ms before the
            // letter, so requiring an exact match here would strand the binding
            // permanently "held" and never call onRelease.
            guard wasDown else { return }
            heldDown[binding.action] = false
            log.debug(
                "Combo release: action=\(String(describing: binding.action), privacy: .public)")
            DispatchQueue.main.async { binding.onRelease() }
            return
        }

        // keyDown: only START the hold on the exact modifier combination.
        let relevantMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        let active = event.flags.intersection(relevantMask)
        let required = binding.hotkey.modifiers.intersection(relevantMask)
        guard active == required else { return }

        if wasDown { return }
        heldDown[binding.action] = true
        log.debug("Combo press: action=\(String(describing: binding.action), privacy: .public)")
        DispatchQueue.main.async { binding.onPress() }
    }

    private func bareModifierTargetKeyCode(_ hotkey: Hotkey) -> Int64 {
        let mods = hotkey.modifiers
        if mods.contains(CGEventFlags.maskAlternate) { return Self.kRightOption }
        if mods.contains(CGEventFlags.maskCommand) { return Self.kRightCommand }
        if mods.contains(CGEventFlags.maskShift) { return Self.kRightShift }
        if mods.contains(CGEventFlags.maskControl) { return Self.kRightControl }
        return Self.kRightOption
    }

    private func bareModifierBit(_ hotkey: Hotkey) -> CGEventFlags {
        let mods = hotkey.modifiers
        if mods.contains(CGEventFlags.maskAlternate) { return CGEventFlags.maskAlternate }
        if mods.contains(CGEventFlags.maskCommand) { return CGEventFlags.maskCommand }
        if mods.contains(CGEventFlags.maskShift) { return CGEventFlags.maskShift }
        if mods.contains(CGEventFlags.maskControl) { return CGEventFlags.maskControl }
        return CGEventFlags.maskAlternate
    }
}
