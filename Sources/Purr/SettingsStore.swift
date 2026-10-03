import Combine
import CoreGraphics
import Foundation

// Persistent user settings, backed by UserDefaults.
//
// Hotkey is stored as two scalars - keyCode + modifierMask - because that's
// the granularity CGEventTap reports. A bare-modifier hotkey (no normal key,
// e.g. "hold Right Option") is represented by keyCode == nil and a single
// bit set in modifierMask.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    enum Keys {
        static let hotkeyKeyCode = "hotkey.keyCode"
        static let hotkeyModifiers = "hotkey.modifiers"
        static let hotkeyMode = "hotkey.mode"
        static let meetingHotkeyKey = "hotkey.meeting.keyCode"
        static let meetingHotkeyMod = "hotkey.meeting.modifiers"
        static let voiceEditKey = "hotkey.edit.keyCode"
        static let voiceEditMod = "hotkey.edit.modifiers"
        static let meetingEnabled = "feature.meeting"
        static let showMeetingHUD = "feature.showMeetingHUD"
        static let voiceEditEnabled = "feature.voiceEdit"
        static let modelName = "stt.modelName"
        static let autoPaste = "stt.autoPaste"
        static let onboardingDone = "onboarding.done"
        static let engine = "stt.engine"
        static let translateToEnglish = "stt.translateToEnglish"
        static let translationSourceLanguage = "stt.translationSourceLanguage"
        static let smartTyping = "ui.smartTyping"
        static let streamAtCursor = "ui.streamAtCursor"
        static let voiceCommands = "ui.voiceCommands"
        static let dictionary = "post.dictionary"
        static let customVoiceCommands = "post.customVoiceCommands"
        static let customFillerWords = "post.customFillerWords"
        static let trimFillers = "post.trimFillers"
        static let summarizeMeetings = "feature.summarizeMeetings"
        static let summaryBackend = "feature.summaryBackend"
        static let meetingsFolderPath = "meetings.folderPath"
        static let systemAudioNoticeShown = "meetings.systemAudioNoticeShown"
    }

    // Which on-device LLM produces the meeting summary. Apple FM is the
    // default on macOS 26+; older systems coerce to .llamaCpp at use time.
    enum SummaryBackend: String, Codable, CaseIterable, Identifiable {
        case appleFoundation
        case llamaCpp
        var id: String { rawValue }
    }

    enum Engine: String, Codable, CaseIterable, Identifiable {
        case parakeet
        case whisper
        var id: String { rawValue }
        var label: String {
            switch self {
            case .parakeet: return "Parakeet TDT v2 (recommended)"
            case .whisper: return "Whisper"
            }
        }
        var summary: String {
            switch self {
            case .parakeet:
                return
                    "10× faster on Apple Silicon. English-only, top accuracy. No silence hallucinations. Streaming-capable."
            case .whisper: return "100+ languages including Asian and Arabic. Batch only."
            }
        }
    }

    enum HotkeyMode: String, Codable, CaseIterable, Identifiable {
        case holdToTalk
        case toggle
        var id: String { rawValue }
        var label: String {
            switch self {
            case .holdToTalk: return "Hold to talk"
            case .toggle: return "Tap to toggle"
            }
        }
    }

    @Published var hotkey: Hotkey {
        didSet { persistHotkey() }
    }

    @Published var hotkeyMode: HotkeyMode {
        didSet { defaults.set(hotkeyMode.rawValue, forKey: Keys.hotkeyMode) }
    }

    @Published var meetingHotkey: Hotkey {
        didSet { persistMeetingHotkey() }
    }

    @Published var voiceEditHotkey: Hotkey {
        didSet { persistVoiceEditHotkey() }
    }

    @Published var meetingEnabled: Bool {
        didSet { defaults.set(meetingEnabled, forKey: Keys.meetingEnabled) }
    }

    // Whether the floating "Meeting · 0:00" recording pill (with its live
    // waveform) is shown while a meeting records. When off, the meeting still
    // records and the menu bar shows a recording indicator - only the
    // on-screen pill is suppressed; transcribing/summary/error HUDs still show.
    @Published var showMeetingHUD: Bool {
        didSet { defaults.set(showMeetingHUD, forKey: Keys.showMeetingHUD) }
    }

    @Published var voiceEditEnabled: Bool {
        didSet { defaults.set(voiceEditEnabled, forKey: Keys.voiceEditEnabled) }
    }

    @Published var modelName: String {
        didSet { defaults.set(modelName, forKey: Keys.modelName) }
    }

    @Published var autoPaste: Bool {
        didSet { defaults.set(autoPaste, forKey: Keys.autoPaste) }
    }

    @Published var onboardingDone: Bool {
        didSet { defaults.set(onboardingDone, forKey: Keys.onboardingDone) }
    }

    // Set once after we warn the user that a meeting captured silent system
    // audio (output was active but the System Audio Recording permission is
    // off). Persisted so the one-time notice never nags on later meetings.
    var systemAudioNoticeShown: Bool {
        get { defaults.bool(forKey: Keys.systemAudioNoticeShown) }
        set { defaults.set(newValue, forKey: Keys.systemAudioNoticeShown) }
    }

    @Published var engine: Engine {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }

    // Whisper-only: when on, transcription runs the X→English translate task
    // instead of plain same-language transcription. Inert on Parakeet and on
    // Whisper models that can't translate (turbo / English-only) — the
    // toggle is gated in Settings and WhisperEngine re-checks
    // ModelManager.supportsTranslation before honouring it.
    @Published var translateToEnglish: Bool {
        didSet { defaults.set(translateToEnglish, forKey: Keys.translateToEnglish) }
    }

    // Source language for Whisper translation. Empty string = auto-detect.
    // Pinning a language skips Whisper's audio-based detection, which is
    // unreliable on short utterances. Consulted only when translateToEnglish
    // is on; valid values are WhisperLanguage codes.
    @Published var translationSourceLanguage: String {
        didSet { defaults.set(translationSourceLanguage, forKey: Keys.translationSourceLanguage) }
    }

    // Smart typing = real-time streaming + word-by-word insertion at the
    // cursor as the user speaks. Only meaningful with a streaming-capable
    // engine (Parakeet). When the active engine doesn't support streaming
    // and this is on, the coordinator transparently falls back to batch
    // and surfaces a hint in the HUD.
    @Published var smartTyping: Bool {
        didSet { defaults.set(smartTyping, forKey: Keys.smartTyping) }
    }

    @Published var streamAtCursor: Bool {
        didSet { defaults.set(streamAtCursor, forKey: Keys.streamAtCursor) }
    }

    @Published var voiceCommands: Bool {
        didSet { defaults.set(voiceCommands, forKey: Keys.voiceCommands) }
    }

    @Published var trimFillers: Bool {
        didSet { defaults.set(trimFillers, forKey: Keys.trimFillers) }
    }

    // Off until the user has explicitly downloaded the GGUF model AND
    // opted in (macOS < 26), or until Apple Intelligence is available on
    // macOS 26+. We never run a 2.5 GB download by surprise.
    @Published var summarizeMeetings: Bool {
        didSet { defaults.set(summarizeMeetings, forKey: Keys.summarizeMeetings) }
    }

    @Published var summaryBackend: SummaryBackend {
        didSet { defaults.set(summaryBackend.rawValue, forKey: Keys.summaryBackend) }
    }

    // Where meeting transcripts (and their .summary.md sidecars) are saved.
    // Empty string = unset, which resolves to `defaultMeetingsDirectory` -
    // a folder under ~/Library/Application Support that needs no TCC consent,
    // so a save never trips a permission prompt. A non-empty path is a
    // user-chosen folder; if it ever becomes unwritable, MeetingDocument
    // falls back to the default so a transcript is never lost.
    @Published var meetingsFolderPath: String {
        didSet { defaults.set(meetingsFolderPath, forKey: Keys.meetingsFolderPath) }
    }

    // Default save location: ~/Library/Application Support/Purr/Purr Meetings.
    // Matches the App Support convention already used for models, and unlike
    // ~/Documents it is not TCC-protected, so the app can always create and
    // write here without a consent prompt.
    static var defaultMeetingsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Purr/Purr Meetings", isDirectory: true)
    }

    // Custom dictionary maps spoken-form → preferred-form, applied as a
    // case-insensitive whole-word post-process on every transcript.
    // Useful for proper nouns and brand spellings the model gets wrong.
    @Published var dictionary: [DictionaryEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(dictionary) {
                defaults.set(data, forKey: Keys.dictionary)
            }
        }
    }

    // Custom voice commands map a spoken phrase → literal replacement text,
    // applied in the voice-command post-processing pass alongside the
    // built-in commands and gated by the same `voiceCommands` toggle.
    @Published var customVoiceCommands: [VoiceCommandEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(customVoiceCommands) {
                defaults.set(data, forKey: Keys.customVoiceCommands)
            }
        }
    }

    // Custom filler words the user wants stripped, applied in the filler-trim
    // pass after the built-in hesitations and gated by the same `trimFillers`
    // toggle. Lets the user opt into removing words the built-in pass leaves
    // alone ("like", "you know", "basically", …).
    @Published var customFillerWords: [FillerWordEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(customFillerWords) {
                defaults.set(data, forKey: Keys.customFillerWords)
            }
        }
    }

    private let defaults = UserDefaults.standard

    private init() {
        let storedKey = defaults.object(forKey: Keys.hotkeyKeyCode) as? Int
        let storedMods = defaults.object(forKey: Keys.hotkeyModifiers) as? UInt
        self.hotkey = Hotkey(
            keyCode: storedKey.map { Int64($0) },
            modifiers: storedMods.map { CGEventFlags(rawValue: UInt64($0)) }
                ?? Hotkey.defaultRightOption.modifiers
        )
        let storedMode = defaults.string(forKey: Keys.hotkeyMode) ?? HotkeyMode.holdToTalk.rawValue
        self.hotkeyMode = HotkeyMode(rawValue: storedMode) ?? .holdToTalk
        self.modelName = defaults.string(forKey: Keys.modelName) ?? ModelManager.defaultModel
        self.autoPaste = defaults.object(forKey: Keys.autoPaste) as? Bool ?? true
        self.onboardingDone = defaults.bool(forKey: Keys.onboardingDone)
        let storedEngine = defaults.string(forKey: Keys.engine) ?? Engine.parakeet.rawValue
        self.engine = Engine(rawValue: storedEngine) ?? .parakeet
        self.translateToEnglish = defaults.object(forKey: Keys.translateToEnglish) as? Bool ?? false
        self.translationSourceLanguage = defaults.string(forKey: Keys.translationSourceLanguage) ?? ""
        self.smartTyping = defaults.object(forKey: Keys.smartTyping) as? Bool ?? false
        self.streamAtCursor = defaults.object(forKey: Keys.streamAtCursor) as? Bool ?? false
        self.voiceCommands = defaults.object(forKey: Keys.voiceCommands) as? Bool ?? true
        self.trimFillers = defaults.object(forKey: Keys.trimFillers) as? Bool ?? true
        self.summarizeMeetings = defaults.object(forKey: Keys.summarizeMeetings) as? Bool ?? false
        let storedBackend =
            defaults.string(forKey: Keys.summaryBackend) ?? SummaryBackend.appleFoundation.rawValue
        self.summaryBackend = SummaryBackend(rawValue: storedBackend) ?? .appleFoundation
        self.meetingsFolderPath = defaults.string(forKey: Keys.meetingsFolderPath) ?? ""
        if let data = defaults.data(forKey: Keys.dictionary),
            let entries = try? JSONDecoder().decode([DictionaryEntry].self, from: data)
        {
            self.dictionary = entries
        } else {
            self.dictionary = []
        }
        if let data = defaults.data(forKey: Keys.customVoiceCommands),
            let entries = try? JSONDecoder().decode([VoiceCommandEntry].self, from: data)
        {
            self.customVoiceCommands = entries
        } else {
            self.customVoiceCommands = []
        }
        if let data = defaults.data(forKey: Keys.customFillerWords),
            let entries = try? JSONDecoder().decode([FillerWordEntry].self, from: data)
        {
            self.customFillerWords = entries
        } else {
            self.customFillerWords = []
        }

        let mKey = defaults.object(forKey: Keys.meetingHotkeyKey) as? Int
        let mMods = defaults.object(forKey: Keys.meetingHotkeyMod) as? UInt
        self.meetingHotkey = Hotkey(
            keyCode: mKey.map { Int64($0) } ?? Hotkey.defaultMeeting.keyCode,
            modifiers: mMods.map { CGEventFlags(rawValue: UInt64($0)) } ?? Hotkey.defaultMeeting.modifiers
        )
        let eKey = defaults.object(forKey: Keys.voiceEditKey) as? Int
        let eMods = defaults.object(forKey: Keys.voiceEditMod) as? UInt
        self.voiceEditHotkey = Hotkey(
            keyCode: eKey.map { Int64($0) } ?? Hotkey.defaultVoiceEdit.keyCode,
            modifiers: eMods.map { CGEventFlags(rawValue: UInt64($0)) }
                ?? Hotkey.defaultVoiceEdit.modifiers
        )
        self.meetingEnabled = defaults.object(forKey: Keys.meetingEnabled) as? Bool ?? false
        self.showMeetingHUD = defaults.object(forKey: Keys.showMeetingHUD) as? Bool ?? true
        self.voiceEditEnabled = defaults.object(forKey: Keys.voiceEditEnabled) as? Bool ?? false

        // Seed the defaults so a fresh launch lands on the documented hotkey even if nothing was stored yet.
        if storedKey == nil && storedMods == nil {
            self.hotkey = Hotkey.defaultRightOption
        }
    }

    // Returns every user-facing preference to its first-launch defaults.
    // Leaves transitional state (onboardingDone) and disk artifacts
    // (downloaded models) alone - the user can clear those explicitly via
    // the model rows. didSet on each @Published var handles persistence.
    func resetToDefaults() {
        hotkey = .defaultRightOption
        hotkeyMode = .holdToTalk
        meetingHotkey = .defaultMeeting
        voiceEditHotkey = .defaultVoiceEdit
        meetingEnabled = false
        showMeetingHUD = true
        voiceEditEnabled = false
        engine = .parakeet
        modelName = ModelManager.defaultModel
        translateToEnglish = false
        translationSourceLanguage = ""
        autoPaste = true
        smartTyping = false
        streamAtCursor = false
        voiceCommands = true
        trimFillers = true
        summarizeMeetings = false
        summaryBackend = .appleFoundation
        meetingsFolderPath = ""
        dictionary = []
        customVoiceCommands = []
        customFillerWords = []
    }

    private func persistHotkey() {
        if let keyCode = hotkey.keyCode {
            defaults.set(Int(keyCode), forKey: Keys.hotkeyKeyCode)
        } else {
            defaults.removeObject(forKey: Keys.hotkeyKeyCode)
        }
        defaults.set(UInt(hotkey.modifiers.rawValue), forKey: Keys.hotkeyModifiers)
    }

    private func persistMeetingHotkey() {
        if let keyCode = meetingHotkey.keyCode {
            defaults.set(Int(keyCode), forKey: Keys.meetingHotkeyKey)
        } else {
            defaults.removeObject(forKey: Keys.meetingHotkeyKey)
        }
        defaults.set(UInt(meetingHotkey.modifiers.rawValue), forKey: Keys.meetingHotkeyMod)
    }

    private func persistVoiceEditHotkey() {
        if let keyCode = voiceEditHotkey.keyCode {
            defaults.set(Int(keyCode), forKey: Keys.voiceEditKey)
        } else {
            defaults.removeObject(forKey: Keys.voiceEditKey)
        }
        defaults.set(UInt(voiceEditHotkey.modifiers.rawValue), forKey: Keys.voiceEditMod)
    }
}

// A hotkey is either:
//   - bare modifiers (keyCode == nil, modifiers != 0)            e.g. hold Right Option
//   - modifiers + key (both present)                              e.g. ⌃⌥ Space
//   - bare key (keyCode != nil, modifiers == 0)                   e.g. F5
struct Hotkey: Equatable {
    var keyCode: Int64?
    var modifiers: CGEventFlags

    var isBareModifier: Bool { keyCode == nil && !modifiers.isEmpty }

    static let defaultRightOption = Hotkey(
        keyCode: nil,
        // CGEventFlags doesn't distinguish left/right out of the box;
        // HotkeyManager checks the device-side bit (NX_DEVICERALTKEYMASK)
        // to gate "right" specifically. We store .maskAlternate as a logical
        // hint; the manager interprets bare-modifier hotkeys as side-aware.
        modifiers: .maskAlternate
    )

    // Meeting toggle defaults to ⌃⌥M. M (kVK_ANSI_M) = 46. Picked because
    // (a) it doesn't collide with any default macOS shortcut, (b) the M
    // mnemonic is easy to remember, and (c) Control+Option together
    // require an intentional press, avoiding accidental meeting starts.
    static let defaultMeeting = Hotkey(
        keyCode: 46,
        modifiers: [.maskControl, .maskAlternate]
    )

    // Voice-edit defaults to ⌃⌥E. E (kVK_ANSI_E) = 14. "E" for Edit.
    static let defaultVoiceEdit = Hotkey(
        keyCode: 14,
        modifiers: [.maskControl, .maskAlternate]
    )

    // Quit shortcut. Hardcoded (not user-configurable) - shadows the status-
    // bar Quit item so power users never have to reach for the mouse, and so
    // the app can be terminated when no Purr window is frontmost (the standard
    // ⌘Q only fires when a window is key). Lives on ⌃⌥ to stay clear of any
    // focused-app ⌘ shortcuts. kVK_ANSI_Q = 12.
    static let quitApp = Hotkey(
        keyCode: 12,
        modifiers: [.maskControl, .maskAlternate]
    )

    var displayName: String {
        var parts: [String] = []
        if modifiers.contains(CGEventFlags.maskControl) { parts.append("⌃") }
        if modifiers.contains(CGEventFlags.maskAlternate) { parts.append("⌥") }
        if modifiers.contains(CGEventFlags.maskShift) { parts.append("⇧") }
        if modifiers.contains(CGEventFlags.maskCommand) { parts.append("⌘") }
        if let code = keyCode {
            parts.append(KeyCodes.name(for: code))
        } else if isBareModifier {
            // Bare modifier hotkey: clarify that it's the right-side key
            // (which is the whole point of bare-modifier mode - the left
            // ones get used as actual modifiers in everyday typing).
            return "Right \(parts.joined())"
        }
        return parts.joined()
    }
}

// One row in the custom dictionary. `from` and `to` are matched
// case-insensitively as whole words; replacement preserves the surrounding
// whitespace.
struct DictionaryEntry: Codable, Equatable, Identifiable, Hashable {
    var id: UUID = UUID()
    var from: String
    var to: String
}

// One custom voice command. `phrase` is matched case-insensitively as a whole
// word; `replacement` is inserted in its place, with \n and \t escapes
// expanded so a command can produce whitespace.
struct VoiceCommandEntry: Codable, Equatable, Identifiable, Hashable {
    var id: UUID = UUID()
    var phrase: String
    var replacement: String
}

// One custom filler word or phrase. Matched case-insensitively as a whole
// word and removed during the filler-trim pass.
struct FillerWordEntry: Codable, Equatable, Identifiable, Hashable {
    var id: UUID = UUID()
    var word: String
}

enum KeyCodes {
    static func name(for code: Int64) -> String {
        // Unlisted codes fall through to "Key <n>".
        switch code {
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 49: return "Space"
        case 36: return "Return"
        case 46: return "M"
        case 14: return "E"
        case 15: return "R"
        case 9: return "V"
        case 43: return ","
        case 31: return "O"
        case 12: return "Q"
        default: return "Key \(code)"
        }
    }
}
