import AVFoundation
import AppKit
import ApplicationServices

// Reads the TCC states Purr depends on, and asks for each one from inside the
// app wherever macOS allows it:
//
//   - Microphone and system audio show macOS's own Allow prompt in place.
//   - Accessibility can't be switched on by any app itself. Purr's
//     AXIsProcessTrusted() checks are enough for System Settings to list it,
//     so Allow opens that pane for one switch, and the grant reads live.
//     Accessibility also covers the hotkey's listen-only event tap - it grants
//     both posting and listening for events - which is why Purr doesn't ask
//     for Input Monitoring.
//
// A bundle ID change or repeated ad-hoc re-signing can invalidate prior grants -
// they're bound to a code signature designation that no longer matches. The fix
// is removing the old System Settings entry (or `tccutil reset Accessibility
// com.arunbrahma.hello`) and granting again.
enum Permissions {
    enum Kind: String, CaseIterable, Identifiable {
        case microphone, accessibility, systemAudio
        var id: String { rawValue }

        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .accessibility: return "Accessibility"
            case .systemAudio: return "System Audio"
            }
        }
        var why: String {
            switch self {
            case .microphone: return "So Purr can hear you."
            case .accessibility: return "So Purr can see its shortcut and type at your cursor."
            case .systemAudio: return "Optional. Lets meeting notes include the other people on a call."
            }
        }
        var settingsURL: URL {
            // Pane IDs occasionally change between macOS versions; these have
            // been stable since Ventura. System audio sits under Screen Recording.
            switch self {
            case .microphone:
                return URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .accessibility:
                return URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .systemAudio:
                return URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            }
        }
    }

    enum Status { case granted, notDetermined, denied }

    // What dictation needs. System audio is only for meetings, which fall back
    // to the microphone without it.
    static let required: [Kind] = [.microphone, .accessibility]

    // nil only for system audio, if TCC's private calls are ever gone.
    static func status(_ kind: Kind) -> Status? {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .accessibility:
            // Do NOT "live-probe" via AXUIElementCopyAttributeValue on
            // AXUIElementCreateSystemWide() - it succeeds for our own focused
            // window even when untrusted, a false positive. macOS can't say
            // whether the switch was turned off or never on, and the fix is the
            // same switch either way.
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .systemAudio:
            guard let preflight = TCC.preflight else { return nil }
            switch preflight(TCC.audioCapture, nil) {
            case 0: return .granted
            case 1: return .denied
            default: return .notDetermined
            }
        }
    }

    static func isGranted(_ kind: Kind) -> Bool {
        status(kind) == .granted
    }

    static func allGranted() -> Bool {
        required.allSatisfy(isGranted)
    }

    // requestAccess only prompts while the status is .notDetermined; once
    // denied, macOS never re-prompts (not even after relaunch), and System
    // Settings is the only way back.
    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // Like the microphone, macOS asks once and never again after an answer.
    static func requestSystemAudio(_ completion: @escaping () -> Void) {
        guard let request = TCC.request else { return completion() }
        request(TCC.audioCapture, nil) { _ in
            DispatchQueue.main.async(execute: completion)
        }
    }

    static func openSettings(for kind: Kind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    static func openSystemAudioSettings() {
        openSettings(for: .systemAudio)
    }

    // Posted by macOS when the Accessibility list changes. Undocumented but
    // long-standing, so it only speeds things up: whoever listens also polls,
    // and re-reads a moment later, as the trust read can trail it.
    static let accessibilityChanged = Notification.Name("com.apple.accessibility.api")

    // System Audio Recording (kTCCServiceAudioCapture) has no public API to
    // read or request: macOS asks once, when a Core Audio process tap first
    // starts. TCC's own preflight and request calls do both, but they're
    // private, so they're looked up at runtime, as insidegui/AudioCap does. If
    // an update removes them, status(.systemAudio) is nil, setup leaves the
    // row out, and the first meeting asks as before.
    private enum TCC {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
        typealias Request =
            @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

        static let audioCapture = "kTCCServiceAudioCapture" as CFString
        private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
        static let preflight = handle.flatMap { dlsym($0, "TCCAccessPreflight") }
            .map { unsafeBitCast($0, to: Preflight.self) }
        static let request = handle.flatMap { dlsym($0, "TCCAccessRequest") }
            .map { unsafeBitCast($0, to: Request.self) }
    }
}
