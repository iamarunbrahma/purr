import FluidAudio
import Foundation

// Meeting language picker options. `code` matches FluidAudio's `Language`
// rawValue exactly (round-trips via `fluidAudioLanguage`, no translation
// table). English is the sentinel (empty code): it keeps meetings on the
// always-installed v2 model; any other choice routes through v3, with the
// language passed as its script-aware token filter hint.
struct ParakeetLanguage: LanguageOption {
    let code: String
    let name: String

    var id: String { code }

    static let english = ParakeetLanguage(code: "", name: "English (default)")

    static let all: [ParakeetLanguage] = [
        english,
        ParakeetLanguage(code: "be", name: "Belarusian"),
        ParakeetLanguage(code: "bs", name: "Bosnian"),
        ParakeetLanguage(code: "bg", name: "Bulgarian"),
        ParakeetLanguage(code: "hr", name: "Croatian"),
        ParakeetLanguage(code: "cs", name: "Czech"),
        ParakeetLanguage(code: "da", name: "Danish"),
        ParakeetLanguage(code: "nl", name: "Dutch"),
        ParakeetLanguage(code: "et", name: "Estonian"),
        ParakeetLanguage(code: "fi", name: "Finnish"),
        ParakeetLanguage(code: "fr", name: "French"),
        ParakeetLanguage(code: "de", name: "German"),
        ParakeetLanguage(code: "el", name: "Greek"),
        ParakeetLanguage(code: "hu", name: "Hungarian"),
        ParakeetLanguage(code: "it", name: "Italian"),
        ParakeetLanguage(code: "lv", name: "Latvian"),
        ParakeetLanguage(code: "lt", name: "Lithuanian"),
        ParakeetLanguage(code: "mt", name: "Maltese"),
        ParakeetLanguage(code: "pl", name: "Polish"),
        ParakeetLanguage(code: "pt", name: "Portuguese"),
        ParakeetLanguage(code: "ro", name: "Romanian"),
        ParakeetLanguage(code: "ru", name: "Russian"),
        ParakeetLanguage(code: "sr", name: "Serbian"),
        ParakeetLanguage(code: "sk", name: "Slovak"),
        ParakeetLanguage(code: "sl", name: "Slovenian"),
        ParakeetLanguage(code: "es", name: "Spanish"),
        ParakeetLanguage(code: "sv", name: "Swedish"),
        ParakeetLanguage(code: "uk", name: "Ukrainian"),
    ]

    // Falls back to English so a stale/unknown stored code is never fatal.
    static func named(_ code: String) -> ParakeetLanguage {
        all.first { $0.code == code } ?? english
    }

    // Ranked, prefix-first matching for the search field. English is
    // excluded - an empty field already represents it.
    static func matching(_ query: String) -> [ParakeetLanguage] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all.filter { !$0.code.isEmpty } }
        var prefixMatches: [ParakeetLanguage] = []
        var substringMatches: [ParakeetLanguage] = []
        for lang in all where !lang.code.isEmpty {
            let lower = lang.name.lowercased()
            if lang.code == q || lower == q {
                prefixMatches.insert(lang, at: 0)
            } else if lower.hasPrefix(q) {
                prefixMatches.append(lang)
            } else if lower.contains(q) {
                substringMatches.append(lang)
            }
        }
        return prefixMatches + substringMatches
    }

    // nil for the English sentinel - transcribeMeeting() then knows to skip
    // v3 entirely and stay on the shared v2 manager.
    var fluidAudioLanguage: Language? {
        Language(rawValue: code)
    }
}
