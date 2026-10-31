import Foundation
import os.log

// Deterministic post-processing passes (no LLM, no network) so they stay fast
// and predictable. Order matters: filler trim → voice commands → capitals →
// dictionary → spacing cleanup.
struct PostProcessor {
    var trimFillers: Bool
    var customFillerWords: [FillerWordEntry]
    var voiceCommandsEnabled: Bool
    var customVoiceCommands: [VoiceCommandEntry]
    var dictionary: [DictionaryEntry]

    // Watch the passes live with:
    //   log stream --predicate 'subsystem == "com.arunbrahma.purr"
    //   AND category == "postprocess"' --level debug
    private let log = Logger(subsystem: "com.arunbrahma.purr", category: "postprocess")

    func apply(_ raw: String) -> ProcessResult {
        var text = raw
        var dropPreviousChunks = 0
        log.debug("raw: '\(raw, privacy: .public)'")

        if trimFillers {
            let before = text
            text = removeFillers(text)
            text = removeCustomFillers(text)
            if text != before {
                log.debug("fillers: '\(before, privacy: .public)' -> '\(text, privacy: .public)'")
            }
        }

        if voiceCommandsEnabled {
            let before = text
            let outcome = applyVoiceCommands(text)
            text = outcome.text
            dropPreviousChunks = outcome.dropPreviousChunks
            if text != before || dropPreviousChunks > 0 {
                log.debug(
                    "voice-cmd: '\(before, privacy: .public)' -> '\(text, privacy: .public)' drop=\(dropPreviousChunks, privacy: .public)"
                )
            }
        }

        text = restoreCapitals(text, raw: raw)

        let beforeDict = text
        text = applyDictionary(text)
        if text != beforeDict {
            log.debug("dictionary: '\(beforeDict, privacy: .public)' -> '\(text, privacy: .public)'")
        }

        // Whitespace cleanup, in order:
        //   1. collapse runs of spaces,
        //   2. pull a stray space into voice-command punctuation ("do it ?" -> "do
        //      it?") - sentence marks only, never the emoji faces or opening
        //      brackets that carry intentional spacing,
        //   3. strip spaces hugging a "new line" or "tab key" break ("plan \n okay"
        //      -> "plan\nokay"),
        //   4. trim leading/trailing spaces, keeping newlines and tabs so a
        //      break-only utterance still carries its break.
        // Tabs only ever come from "tab key" or a custom command, so they stay.
        text = text.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #" +([,.?!…])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #" *([\n\t]) *"#, with: "$1", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " "))

        log.debug(
            "final: '\(text, privacy: .public)' (trimFillers=\(trimFillers, privacy: .public), voiceCommands=\(voiceCommandsEnabled, privacy: .public))"
        )
        return ProcessResult(text: text, dropPreviousChunks: dropPreviousChunks)
    }

    struct ProcessResult {
        var text: String
        // "scratch that" / "delete that" with nothing to undo in this utterance:
        // the streaming coordinator drops this many already-committed chunks; the
        // batch path uses it to hint that cross-dictation undo needs Smart Typing.
        var dropPreviousChunks: Int
    }

    // ------------------------------------------------------------------
    // Pass 1: filler trim
    // ------------------------------------------------------------------

    private func removeFillers(_ text: String) -> String {
        // Sound-based hesitations only. We deliberately do NOT strip "like", "you
        // know", "basically", etc. - they're discourse markers that often *are*
        // what the user intended ("I like apples"), so false positives hurt more
        // than the noise helps.
        //
        // Longer alternatives precede shorter ones (uhm before um/uh, erm before
        // er, ahem before ah, mhm before hm) so the regex engine doesn't snap the
        // shorter prefix and leave a stray letter behind.
        let fillerPattern =
            #"\b(?:u+h+[\s-]*h+u+h+|u+h+m+|u+m+|u+h+|e+r+m+|e+r+|a+h+e+m+|a+h+|m+m+[\s-]*h+m*|m+h+m+|h+m+|m+m+m+)\b[,.!?]?\s*"#
        return text.replacingOccurrences(
            of: fillerPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    // Strip the user's custom filler words/phrases - how they opt into removing
    // words the built-in pass deliberately keeps. Absorbs a trailing comma/period
    // and the following space, as the built-in pass does, so a removed filler
    // doesn't leave an orphan comma or double space behind.
    private func removeCustomFillers(_ text: String) -> String {
        var result = text
        for entry in customFillerWords {
            let word = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            let pattern =
                #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b[,.!?]?\s*"#
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    // ------------------------------------------------------------------
    // Pass 2: voice commands
    // ------------------------------------------------------------------

    private struct VoiceCommandOutcome {
        var text: String
        var dropPreviousChunks: Int
    }

    private func applyVoiceCommands(_ text: String) -> VoiceCommandOutcome {
        var outcome = VoiceCommandOutcome(text: text, dropPreviousChunks: 0)

        let backtrack = applyBacktrack(text)
        outcome.dropPreviousChunks = backtrack.reachedBeyond
        guard !backtrack.text.isEmpty else {
            outcome.text = ""
            return outcome
        }

        var t = backtrack.text
        for category in Self.builtInCommandCatalog {
            for (pattern, replacement) in category.replacements {
                t = t.replacingOccurrences(
                    of: pattern,
                    with: replacement,
                    options: [.regularExpression, .caseInsensitive]
                )
            }
        }
        t = applyCustomCommands(t)
        outcome.text = t
        return outcome
    }

    // Sentence-level "scratch that" / "delete that" backtrack. Returns the text
    // with each command sentence and the sentence it undoes removed, plus the
    // count of commands that had nothing before them to delete in this utterance.
    private func applyBacktrack(_ text: String) -> (text: String, reachedBeyond: Int) {
        // Cheap guard: skip the split entirely when no command is present, so
        // ordinary dictation keeps its exact original spacing.
        let lower = text.lowercased()
        guard lower.contains("scratch that") || lower.contains("delete that") else {
            return (text, 0)
        }

        var kept: [String] = []
        var reachedBeyond = 0
        for sentence in splitIntoSentences(text) {
            if isBacktrackCommand(sentence) {
                if kept.isEmpty {
                    reachedBeyond += 1
                } else {
                    kept.removeLast()
                }
            } else {
                kept.append(sentence)
            }
        }
        return (kept.joined(separator: " "), reachedBeyond)
    }

    // True only when a sentence is exactly "scratch that" / "delete that", ignoring
    // case and trailing punctuation (Parakeet emits "Scratch that.", sometimes
    // "Scratch that!"), so "scratch that idea" stays text.
    private func isBacktrackCommand(_ sentence: String) -> Bool {
        var s = sentence.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = s.last, ".?!…,".contains(last) { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)
        return s == "scratch that" || s == "delete that"
    }

    // Split into sentences, keeping each one's terminal punctuation. Marks the
    // boundary after a run of . ? ! … followed by whitespace, then splits on it.
    private func splitIntoSentences(_ text: String) -> [String] {
        let marked = text.replacingOccurrences(
            of: #"([.?!…]+)\s+"#, with: "$1\u{1}", options: .regularExpression)
        return marked.split(separator: "\u{1}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // Applied after the built-ins, longest phrases first so a command that is a
    // prefix of another isn't shadowed. A custom phrase duplicating a built-in
    // won't fire - the built-in already replaced it.
    private func applyCustomCommands(_ text: String) -> String {
        var result = text
        let entries =
            customVoiceCommands
            .filter { !$0.phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.phrase.count > $1.phrase.count }
        for entry in entries {
            let phrase = entry.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: phrase) + #"\b\.?"#
            // escapedTemplate keeps $ and \ in the user's replacement literal —
            // a regex-mode `with:` is otherwise a capture-group template.
            let replacement = NSRegularExpression.escapedTemplate(
                for: Self.unescape(entry.replacement))
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    // Expand \n, \t, and \\ escapes in a custom command's replacement so a
    // command can insert whitespace. Any other \x is left literal.
    private static func unescape(_ s: String) -> String {
        var result = ""
        var iterator = s.makeIterator()
        while let ch = iterator.next() {
            guard ch == "\\" else {
                result.append(ch)
                continue
            }
            guard let next = iterator.next() else {
                result.append("\\")
                break
            }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "\\": result.append("\\")
            default:
                result.append("\\")
                result.append(next)
            }
        }
        return result
    }

    private struct CommandCategory {
        let replacements: [(pattern: String, replacement: String)]
    }

    // Built-in voice commands, grouped by category. Within a category, longer
    // phrases precede shorter ones (e.g. "new paragraph" before "new line") so
    // the regex engine doesn't consume a prefix and leave a stray word.
    // Categories are applied in array order.
    private static let builtInCommandCatalog: [CommandCategory] = [
        // A break absorbs the mark the ASR model puts after the command and a
        // comma before it ("Eggs, new line, milk." -> "Eggs\nmilk."). A period
        // before it stays, since it ends the sentence.
        CommandCategory(
            replacements: [
                (#"(?:,[ \t]*)?\bnew paragraph\b[,.;:?!]?"#, "\n\n"),
                (#"(?:,[ \t]*)?\bnew line\b[,.;:?!]?"#, "\n"),
                (#"(?:,[ \t]*)?\btab key\b[,.;:?!]?"#, "\t"),
            ]),
        // Sentence punctuation also absorbs a mark the ASR model already put on
        // either side of the spoken command ("questions, question mark." ->
        // "questions?", not "questions,?"). Before the command that's , . ; :
        // or the command's own mark ("work? Question mark." -> "work?"), so
        // "question mark exclamation mark" still gives "?!". Spaces are only
        // taken along with a leading mark: a bare "close quote period" must
        // keep its " ." apart so the quote's own `\.?` can't swallow the
        // period. Semicolon and colon take the space before them too, since
        // the cleanup in apply() leaves ; and : alone for the emoji faces.
        CommandCategory(
            replacements: [
                (#"(?:[,.;:?][ \t]*)?\bquestion mark\b[,.;:?!]?"#, "?"),
                (#"(?:[,.;:!][ \t]*)?\bexclamation (?:point|mark)\b[,.;:?!]?"#, "!"),
                (#"(?:[,.;:][ \t]*)?\bfull stop\b[,.;:?!]?"#, "."),
                (#"(?:[,.;:][ \t]*)?\bperiod\b[,.;:?!]?"#, "."),
                (#"(?:[,.;:][ \t]*)?\bcomma\b[,.;:?!]?"#, ","),
                (#"[ \t]*(?:[,.;:][ \t]*)?\bsemicolon\b[,.;:?!]?"#, ";"),
                (#"[ \t]*(?:[,.;:][ \t]*)?\bcolon\b[,.;:?!]?"#, ":"),
                (#"(?:[,.;:][ \t]*)?\bellipsis\b[,.;:?!]?"#, "…"),
            ]),
        CommandCategory(
            replacements: [
                (#"\bem dash\b\.?"#, " — "),
                (#"\ben dash\b\.?"#, " – "),
                (#"\bdash\b\.?"#, " - "),
                (#"\bhyphen\b\.?"#, "-"),
            ]),
        CommandCategory(
            replacements: [
                (#"\bopen quote\b\.?"#, " \""),
                (#"\bclose quote\b\.?"#, "\""),
                (#"\bopen single quote\b\.?"#, " '"),
                (#"\bclose single quote\b\.?"#, "'"),
                (#"\bdouble quote\b\.?"#, "\""),
                (#"\bsingle quote\b\.?"#, "'"),
                (#"\bapostrophe\b\.?"#, "'"),
            ]),
        CommandCategory(
            replacements: [
                (#"\bopen square bracket\b\.?"#, " ["),
                (#"\bclose square bracket\b\.?"#, "]"),
                (#"\bopen angle bracket\b\.?"#, " <"),
                (#"\bclose angle bracket\b\.?"#, ">"),
                (#"\bopen paren(?:thesis)?\b\.?"#, " ("),
                (#"\bclose paren(?:thesis)?\b\.?"#, ")"),
                (#"\bopen bracket\b\.?"#, " ["),
                (#"\bclose bracket\b\.?"#, "]"),
                (#"\bopen brace\b\.?"#, " {"),
                (#"\bclose brace\b\.?"#, "}"),
            ]),
        CommandCategory(
            replacements: [
                (#"\bampersand\b\.?"#, "&"),
                (#"\basterisk\b\.?"#, "*"),
                (#"\bat sign\b\.?"#, "@"),
                (#"\bbackslash\b\.?"#, #"\"#),
                (#"\bforward slash\b\.?"#, "/"),
                (#"\bslash\b\.?"#, "/"),
                (#"\bcaret\b\.?"#, "^"),
                (#"\bvertical bar\b\.?"#, "|"),
            ]),
        CommandCategory(
            replacements: [
                (#"\bhashtag\b\.?"#, "#"),
                (#"\bpound sign\b\.?"#, "#"),
                (#"\bpercent sign\b\.?"#, "%"),
                (#"\bunderscore\b\.?"#, "_"),
                (#"\bplus sign\b\.?"#, "+"),
                (#"\bequals sign\b\.?"#, "="),
                (#"\bdegree sign\b\.?"#, "°"),
                (#"\btilde\b\.?"#, "~"),
            ]),
        CommandCategory(
            replacements: [
                (#"\bpound sterling sign\b\.?"#, "£"),
                (#"\bdollar sign\b\.?"#, "$"),
                (#"\bcent sign\b\.?"#, "¢"),
                (#"\beuro sign\b\.?"#, "€"),
                (#"\byen sign\b\.?"#, "¥"),
            ]),
        CommandCategory(
            replacements: [
                (#"\bregistered trademark\b\.?"#, "®"),
                (#"\bregistered symbol\b\.?"#, "®"),
                (#"\bcopyright symbol\b\.?"#, "©"),
                (#"\btrademark symbol\b\.?"#, "™"),
            ]),
        CommandCategory(
            replacements: [
                (#"\bcross-eyed laughing face\b\.?"#, " XD"),
                (#"\bsmiley face\b\.?"#, " :-)"),
                (#"\bfrowny face\b\.?"#, " :-("),
                (#"\bwinky face\b\.?"#, " ;-)"),
            ]),
        CommandCategory(
            replacements: [
                (#"\bgreater than or equal to\b\.?"#, " ≥ "),
                (#"\bless than or equal to\b\.?"#, " ≤ "),
                (#"\bnot equal to\b\.?"#, " ≠ "),
            ]),
    ]

    // ------------------------------------------------------------------
    // Pass 3: capitals
    // ------------------------------------------------------------------

    // A removed filler or command can take a capital with it. This gives it back to:
    //   - the first word, when the model started the utterance with a capital
    //     ("Um, so I think" -> "So I think"),
    //   - the first word after a break that follows a sentence end
    //     ("ready. New paragraph, please" -> "ready.\n\nPlease"),
    //   - the first word of a paragraph, even when the model heard a comma
    //     before the command ("works, new paragraph, thanks" -> "works\n\nThanks").
    // Runs before the dictionary, so a lowercase replacement there stays lowercase.
    private func restoreCapitals(_ text: String, raw: String) -> String {
        var result = text
        if raw.first?.isUppercase == true {
            result = Self.capitalize(matching: #"^\s*(\p{Ll})"#, in: result)
        }
        return Self.capitalize(matching: #"(?:[.?!…][ \t]*|\n[ \t]*)\n\s*(\p{Ll})"#, in: result)
    }

    // Uppercases each letter `pattern` captures, unless its word already has a
    // capital inside ("iPhone", "macOS").
    private static func capitalize(matching pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern + #"(?![\p{L}'’]*\p{Lu})"#) else {
            return text
        }
        let result = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: result.length))
        for match in matches.reversed() {
            let letter = match.range(at: 1)
            result.replaceCharacters(in: letter, with: result.substring(with: letter).uppercased())
        }
        return result as String
    }

    // ------------------------------------------------------------------
    // Pass 4: user dictionary
    // ------------------------------------------------------------------

    private func applyDictionary(_ text: String) -> String {
        guard !dictionary.isEmpty else { return text }
        var result = text
        for entry in dictionary {
            let escaped = NSRegularExpression.escapedPattern(for: entry.from)
            let pattern = #"\b"# + escaped + #"\b"#
            // entry.to is user-typed; escape it so "$1" / "\0" stay literal instead
            // of becoming back-references that silently mangle the matched text
            // (e.g. dollar amounts, file paths).
            let replacement = NSRegularExpression.escapedTemplate(for: entry.to)
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }
}
