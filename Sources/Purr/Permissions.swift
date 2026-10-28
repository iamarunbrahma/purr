import AVFoundation
import AppKit
import ApplicationServices
import IOKit.hid

// Reads the three TCC states we depend on, and requests the two that can be
// requested programmatically (Accessibility and Input Monitoring).
//
// Calling AXIsProcessTrustedWithOptions and IOHIDRequestAccess does two things
// macOS won't do automatically:
//   1. Registers the app in the right System Settings pane. Until these are
//      called once, the app isn't listed at all.
//   2. Shows the system prompt the FIRST time only. After deny/dismiss the user
//      must toggle manually, which is why "Grant" also opens the pane.
//
// A bundle ID change or repeated ad-hoc re-signing can invalidate prior grants -
// they're bound to a code signature designation that no longer matches. The fix
// is removing the old System Settings entry (or `tccutil reset Accessibility
// com.arunbrahma.hello` / `tccutil reset ListenEvent com.arunbrahma.hello`)
// and granting again.
enum Permissions {
    enum Kind: String, CaseIterable, Identifiable {
        case microphone, accessibility, inputMonitoring
        var id: String { rawValue }

        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .accessibility: return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            }
        }
        var why: String {
            switch self {
            case .microphone:
                return "Purr needs access to record your voice."
            case .accessibility:
                return "Required so Purr can paste your transcript at the cursor."
            case .inputMonitoring:
                return "Required so Purr can listen for the global hotkey across every app."
            }
        }
        var settingsURL: URL {
            // Pane IDs occasionally change between macOS versions; these three
            // have been stable since Ventura.
            switch self {
            case .microphone:
                return URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .accessibility:
                return URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .inputMonitoring:
                return URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
            }
        }
    }

    static func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility:
            // Do NOT "live-probe" via AXUIElementCopyAttributeValue on
            // AXUIElementCreateSystemWide() - it succeeds for our own focused
            // window even when untrusted, a false positive. This result can lag
            // for the life of the process when the user toggles the switch on a
            // running app; the relaunch button is the documented workaround.
            return AXIsProcessTrusted()
        case .inputMonitoring:
            // IOHIDCheckAccess is the canonical prompt-free read.
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        }
    }

    static func allGranted() -> Bool {
        Kind.allCases.allSatisfy(isGranted)
    }

    static func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // requestAccess only prompts while the status is .notDetermined; once
    // denied it returns false with no UI at all (macOS never re-prompts a denied
    // app, not even after relaunch), so the denied case deep-links to System
    // Settings - the only way back.
    static func grantMicrophone(_ completion: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            requestMicrophone { _ in completion() }
        default:
            openSettings(for: .microphone)
            completion()
        }
    }

    // Adds Purr to the Accessibility list in System Settings; prompts on the
    // first call only.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // Same idea for Input Monitoring (macOS 10.15+).
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openSettings(for kind: Kind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    // System Audio Recording (kTCCServiceAudioCapture) is not one of the three
    // Kinds: it has no public status API and no programmatic request - the only
    // prompt fires when a Core Audio process tap first starts, and never again
    // once answered. So there's no live status or prompting "Grant", only a
    // deep-link to the pane, which macOS groups under ScreenCapture.
    static let systemAudioSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static func openSystemAudioSettings() {
        NSWorkspace.shared.open(systemAudioSettingsURL)
    }
}
