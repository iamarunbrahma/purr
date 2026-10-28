import Combine
import CoreGraphics
import Foundation

// Persistent user settings, backed by UserDefaults. Hotkey is stored as two
// scalars - keyCode + modifierMask - the granularity CGEventTap reports. A
// bare-modifier hotkey ("hold Right Option") is keyCode == nil with a
// single bit set in modifierMask.
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
        static let voiceCommands = "ui.voiceCommands"
        static let dictionary = "post.dictionary"
        static let customVoiceCommands = "post.customVoiceCommands"
        static let customFillerWords = "post.customFillerWords"
        static let trimFillers = "post.trimFillers"
        static let summarizeMeetings = "feature.summarizeMeetings"
        static let summaryBackend = "feature.summaryBackend"
        static let meetingsFolderPath = "meetings.folderPath"
        static let systemAudioNoticeShown = "meetings.systemAudioNoticeShown"
        static let meetingLanguage = "meetings.language"
        static let saveMeetingAudio = "meetings.saveAudio"
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

    // When off, the meeting still records and the menu bar shows an
    // indicator - only the floating waveform pill is suppressed.
    @Published var showMeetingHUD: Bool {
        didSet { defaults.set(showMeetingHUD, forKey: Keys.showMeetingHUD) }
    }

    // Off by default: audio is larger and more sensitive than a transcript.
    @Published var saveMeetingAudio: Bool {
        didSet { defaults.set(saveMeetingAudio, forKey: Keys.saveMeetingAudio) }
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

    // Set after the silent-system-audio warning shows once, so it never nags again.
    var systemAudioNoticeShown: Bool {
        get { defaults.bool(forKey: Keys.systemAudioNoticeShown) }
        set { defaults.set(newValue, forKey: Keys.systemAudioNoticeShown) }
    }

    @Published var engine: Engine {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }

    // Whisper-only: runs the X→English translate task instead of same-language
    // transcription. Inert on Parakeet and on models that can't translate.
    @Published var translateToEnglish: Bool {
        didSet { defaults.set(translateToEnglish, forKey: Keys.translateToEnglish) }
    }

    // Empty = auto-detect. Pinning skips Whisper's unreliable-on-short-clips
    // audio detection. Consulted only when translateToEnglish is on.
    @Published var translationSourceLanguage: String {
        didSet { defaults.set(translationSourceLanguage, forKey: Keys.translationSourceLanguage) }
    }

    // Empty string = English (Parakeet v2); otherwise a ParakeetLanguage code
    // that routes meetings through the multilingual v3 model instead.
    @Published var meetingLanguage: String {
        didSet { defaults.set(meetingLanguage, forKey: Keys.meetingLanguage) }
    }

    // Real-time streaming + word-by-word insertion. Only meaningful with a
    // streaming-capable engine (Parakeet); otherwise the coordinator falls
    // back to batch and surfaces a hint in the HUD.
    @Published var smartTyping: Bool {
        didSet { defaults.set(smartTyping, forKey: Keys.smartTyping) }
    }

    @Published var voiceCommands: Bool {
        didSet { defaults.set(voiceCommands, forKey: Keys.voiceCommands) }
    }

    @Published var trimFillers: Bool {
        didSet { defaults.set(trimFillers, forKey: Keys.trimFillers) }
    }

    // Off until the GGUF model is downloaded and opted in (macOS < 26) or
    // Apple Intelligence is available (26+) - never a 2.5GB surprise download.
    @Published var summarizeMeetings: Bool {
        didSet { defaults.set(summarizeMeetings, forKey: Keys.summarizeMeetings) }
    }

    @Published var summaryBackend: SummaryBackend {
        didSet { defaults.set(summaryBackend.rawValue, forKey: Keys.summaryBackend) }
    }

    // Empty = unset, resolves to `defaultMeetingsDirectory` (no TCC consent
    // needed). A non-empty user-chosen path that becomes unwritable falls
    // back to the default in MeetingDocument, so a transcript is never lost.
    @Published var meetingsFolderPath: String {
        didSet { defaults.set(meetingsFolderPath, forKey: Keys.meetingsFolderPath) }
    }

    // Unlike ~/Documents, not TCC-protected - writable with no consent prompt.
    static var defaultMeetingsDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Purr/Purr Meetings", isDirectory: true)
    }

    // Spoken-form → preferred-form, case-insensitive whole-word post-process
    // on every transcript. Useful for proper nouns and brand spellings.
    @Published var dictionary: [DictionaryEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(dictionary) {
                defaults.set(data, forKey: Keys.dictionary)
            }
        }
    }

    // Spoken phrase → literal replacement, alongside the built-in commands
    // and gated by the same `voiceCommands` toggle.
    @Published var customVoiceCommands: [VoiceCommandEntry] {
        didSet {
            if let data = try? JSONEncoder().encode(customVoiceCommands) {
                defaults.set(data, forKey: Keys.customVoiceCommands)
            }
        }
    }

    // Extra words to strip beyond the built-ins ("like", "you know", …),
    // gated by the same `trimFillers` toggle.
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
        self.meetingLanguage = defaults.string(forKey: Keys.meetingLanguage) ?? ""
        self.smartTyping = defaults.object(forKey: Keys.smartTyping) as? Bool ?? false
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
        self.saveMeetingAudio = defaults.object(forKey: Keys.saveMeetingAudio) as? Bool ?? false
        self.voiceEditEnabled = defaults.object(forKey: Keys.voiceEditEnabled) as? Bool ?? false

        // Seed the defaults so a fresh launch lands on the documented hotkey even if nothing was stored yet.
        if storedKey == nil && storedMods == nil {
            self.hotkey = Hotkey.defaultRightOption
        }
    }

    // Leaves onboardingDone and downloaded models alone - those clear
    // separately via the model rows.
    func resetToDefaults() {
        hotkey = .defaultRightOption
        hotkeyMode = .holdToTalk
        meetingHotkey = .defaultMeeting
        voiceEditHotkey = .defaultVoiceEdit
        meetingEnabled = false
        showMeetingHUD = true
        saveMeetingAudio = false
        voiceEditEnabled = false
        engine = .parakeet
        modelName = ModelManager.defaultModel
        translateToEnglish = false
        translationSourceLanguage = ""
        meetingLanguage = ""
        autoPaste = true
        smartTyping = false
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
        // CGEventFlags doesn't distinguish left/right; HotkeyManager checks
        // the device-side bit (NX_DEVICERALTKEYMASK) to gate "right" specifically.
        modifiers: .maskAlternate
    )

    // ⌃⌥M: no default macOS collision, easy mnemonic, and the two-modifier
    // combo avoids accidental meeting starts.
    static let defaultMeeting = Hotkey(
        keyCode: 46,
        modifiers: [.maskControl, .maskAlternate]
    )

    static let defaultVoiceEdit = Hotkey(
        keyCode: 14,
        modifiers: [.maskControl, .maskAlternate]
    )

    // Hardcoded (not user-configurable): shadows the status-bar Quit item, and
    // works when no Purr window is frontmost, unlike ⌘Q which needs a key window.
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
            // Clarify right-side - left modifiers are used in everyday typing.
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
