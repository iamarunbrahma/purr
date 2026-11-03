import Foundation
import os.log

#if canImport(FoundationModels)
import FoundationModels
#endif

// Interprets a spoken instruction against a selected passage and returns the
// edited text, with an on-device LLM doing the interpreting.
//
// Surgical by construction: for a targeted edit the model names find/replace
// spans and `applyPlan` performs the substitution in Swift, so untouched text
// cannot change. A whole-passage rewrite ("make this concise") is the one case
// the model returns full text.
//
// Both backends are asked for the same fenced text protocol; `parsePlan`
// decodes it. Gemma 4 E2B via llama.cpp, sharing the summariser's weights,
// runs once it's downloaded. Until then, or when picked in Settings › Voice
// Edit, Apple Foundation Models (macOS 26+) does, and a downloaded Gemma
// retries any edit Apple's model can't make.
@MainActor
enum EditInterpreter {
    // Apple FM's 4096-token window is the tighter of the two backends; 4000
    // characters leaves room for the instructions and the response. Enforced
    // at hotkey press so an oversized selection is refused before recording
    // starts.
    static let maxSelectionCharacters = 4000

    enum Failure: LocalizedError {
        case noBackend
        case selectionTooLong
        case emptyInstruction
        case interpretationFailed
        case appleModelFailed
        case languageUnsupported
        case backend(Error)

        var errorDescription: String? {
            switch self {
            case .noBackend:
                return "Voice Edit needs an AI model. Download Gemma in Settings → Voice Edit."
            case .selectionTooLong:
                return "That selection is too long for Voice Edit. Select less text and try again."
            case .emptyInstruction:
                return "Didn't catch an edit. Try again."
            case .interpretationFailed:
                return "Couldn't apply that edit. Try rephrasing it."
            case .appleModelFailed:
                return "Apple Intelligence couldn't make this edit. Try Gemma in Settings → Voice Edit."
            case .languageUnsupported:
                return
                    "Voice Edit isn't available in this language. Switch to Gemma in Settings → Voice Edit."
            case .backend:
                // Raw backend errors are too technical for the pill; the caller
                // logs the underlying error.
                return "Voice Edit failed. Try again."
            }
        }
    }

    private static let log = Logger(
        subsystem: "com.arunbrahma.purr", category: "edit-interpreter")

    static var isAvailable: Bool {
        appleFoundationReady || LLMModelManager.isInstalled()
    }

    private static var appleFoundationReady: Bool {
        if #available(macOS 26.0, *) {
            return MeetingSummarizer.appleFoundationAvailable
        }
        return false
    }

    // Gemma once it's downloaded, unless Apple's model was picked in Settings:
    // Gemma made 96 of 96 test edits exactly, Apple's model 68. Until it's
    // downloaded, Apple's model keeps Voice Edit working, as MeetingSummarizer
    // does for summaries.
    private static var prefersGemma: Bool {
        SettingsStore.shared.voiceEditBackend != .appleFoundation && LLMModelManager.isInstalled()
    }

    #if canImport(FoundationModels)
    // The Apple session warmUp(selection:) prewarmed, kept for that selection's
    // edit. AnyObject because LanguageModelSession needs macOS 26.
    private static var prewarmed: (session: AnyObject, selection: String)?
    #endif

    // Called the moment the voice-edit hotkey is pressed. Everything in the
    // prompt before the instruction is known by then, so the model reads it
    // while the user speaks, and a cold Gemma load overlaps the recording too.
    static func warmUp(selection: String) {
        if appleFoundationReady, !prefersGemma {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let session = editSession()
                session.prewarm(promptPrefix: Prompt(userTurnPrefix(selection: selection)))
                prewarmed = (session, selection)
            }
            #endif
            return
        }
        if LLMModelManager.isInstalled() {
            let prefix = gemmaPromptPrefix(selection: selection)
            Task { await LlamaRuntime.shared.warmUp(prefix: prefix) }
        }
    }

    // On any throw the caller leaves the selection untouched.
    static func apply(
        instruction rawInstruction: String, to selection: String
    ) async throws
        -> String
    {
        let instruction = rawInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { throw Failure.emptyInstruction }
        guard selection.count <= maxSelectionCharacters else { throw Failure.selectionTooLong }

        if appleFoundationReady, !prefersGemma {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                do {
                    let plan = try await interpretWithAppleFM(instruction: instruction, selection: selection)
                    let edited = try edit(selection, with: plan, instruction: instruction)
                    guard edited != selection.trimmingCharacters(in: .whitespacesAndNewlines) else {
                        log.info("Apple FM's edit changed nothing.")
                        throw Failure.interpretationFailed
                    }
                    return edited
                } catch Failure.languageUnsupported where LLMModelManager.isInstalled() {
                    log.info("Apple FM rejected the instruction locale; retrying with Gemma.")
                } catch Failure.interpretationFailed {
                    // A refusal, or an edit Purr can't use. Gemma gets one try at
                    // this edit; the next one starts with Apple's model again.
                    guard LLMModelManager.isInstalled() else { throw Failure.appleModelFailed }
                    log.info("Apple FM gave no usable edit; retrying with Gemma.")
                }
            }
            #endif
        }
        guard LLMModelManager.isInstalled() else { throw Failure.noBackend }
        let plan = try await interpretWithGemma(instruction: instruction, selection: selection)
        return try edit(selection, with: plan, instruction: instruction)
    }

    // MARK: - Backends

    #if canImport(FoundationModels)
    // Voice Edit rewrites the user's own text, which the default guardrails
    // can refuse: they flagged "End with a period." on "hello world".
    @available(macOS 26.0, *)
    private static func editSession() -> LanguageModelSession {
        LanguageModelSession(
            model: SystemLanguageModel(guardrails: .permissiveContentTransformations),
            instructions: systemPrompt)
    }

    // Each prewarmed session serves one edit at most.
    @available(macOS 26.0, *)
    private static func takePrewarmedSession(for selection: String) -> LanguageModelSession? {
        defer { prewarmed = nil }
        guard prewarmed?.selection == selection else { return nil }
        return prewarmed?.session as? LanguageModelSession
    }

    @available(macOS 26.0, *)
    private static func interpretWithAppleFM(
        instruction: String, selection: String
    ) async throws
        -> VoiceEditPlan
    {
        // A fresh session per edit - reusing one would accumulate prior turns
        // against the 4096-token context budget. A prewarmed one is still fresh.
        let session = takePrewarmedSession(for: selection) ?? editSession()
        let prompt = userTurn(instruction: instruction, selection: selection)
        let raw: String
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 1500)
            )
            raw = response.content
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error { throw Failure.selectionTooLong }
            // Apple FM can reject the instruction's language at generation time
            // even when `supportsLocale()` passed — it returns true for "close"
            // languages too. `apply` falls through to Gemma when installed,
            // matching MeetingSummarizer's locale fallback.
            if case .unsupportedLanguageOrLocale = error { throw Failure.languageUnsupported }
            // Permissive guardrails don't throw for a text reply, but Apple's
            // model can still refuse, so both count as an unusable reply.
            switch error {
            case .guardrailViolation, .refusal:
                log.info("Apple FM declined the edit.")
                throw Failure.interpretationFailed
            default:
                throw Failure.backend(error)
            }
        }
        guard let plan = parsePlan(raw) else {
            log.error("Apple FM edit plan did not parse; raw length \(raw.count, privacy: .public).")
            throw Failure.interpretationFailed
        }
        return plan
    }
    #endif

    private static func interpretWithGemma(
        instruction: String, selection: String
    ) async throws
        -> VoiceEditPlan
    {
        let prompt = gemmaPrompt(instruction: instruction, selection: selection)
        // 1400 output tokens covers a holistic rewrite of a max-size selection;
        // targeted edits stop early at end-of-turn. 1.0 turns the repetition
        // penalty off. Replies repeat their markers and copy words into the
        // replacement, and the penalty made Gemma end replies before @@END@@
        // and capitalize copied words.
        let parameters = LlamaSession.Parameters(maxTokens: 1400, temperature: 0.2, repetitionPenalty: 1.0)

        let work = Task { try await LlamaRuntime.shared.generate(prompt: prompt, parameters: parameters) }
        let watchdog = Task<Void, Error> {
            try await Task.sleep(for: .seconds(25))
            work.cancel()
        }
        let raw: String
        do {
            raw = try await work.value
            watchdog.cancel()
        } catch {
            watchdog.cancel()
            // Scripts that tokenize densely can overflow even under the
            // character cap.
            if case LlamaSession.LlamaError.promptTooLong = error { throw Failure.selectionTooLong }
            throw Failure.backend(error)
        }

        guard let plan = parsePlan(raw) else {
            log.error("Gemma edit plan did not parse; raw length \(raw.count, privacy: .public).")
            throw Failure.interpretationFailed
        }
        return plan
    }

    // MARK: - Apply the plan

    // Throws interpretationFailed when the plan can't be applied.
    private static func edit(
        _ selection: String, with plan: VoiceEditPlan, instruction: String
    ) throws -> String {
        let plan = completingSwap(
            keepingWordsBeforeEndMark(plan, selection: selection, instruction: instruction),
            instruction: instruction)
        let edited = try applyPlan(plan, to: selection, instruction: instruction)
        let result = reconcile(edited, plan: plan, selection: selection, instruction: instruction)
        // No edit empties the selection: that's a misread instruction, like
        // "delete the first sentence" answered with the whole passage.
        guard !result.isEmpty else { throw Failure.interpretationFailed }
        return result
    }

    // Apple's model sometimes answers "end with a period" on "...jammed again"
    // with find "again", replace ".", which deletes the word. A lone mark that
    // replaces the passage's last words goes after them instead.
    private static func keepingWordsBeforeEndMark(
        _ plan: VoiceEditPlan, selection: String, instruction: String
    ) -> VoiceEditPlan {
        guard case .targeted = plan.scope, namesEndMark(instruction) else { return plan }
        let passage = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        var repaired = plan
        repaired.edits = plan.edits.map { span in
            let isLoneMark = !span.replace.isEmpty && span.replace.allSatisfy(terminators.contains)
            let hasWords = span.find.contains { $0.isLetter || $0.isNumber }
            guard isLoneMark, hasWords, passage.hasSuffix(span.find) else { return span }
            return VoiceEditPlan.Span(find: span.find, replace: span.find + span.replace)
        }
        return repaired
    }

    // Asked to swap two words, both models sometimes give one direction only:
    // John → Sarah, which leaves "Sarah and cc Sarah". When the instruction
    // names the pair, the other direction goes with it.
    private static func completingSwap(_ plan: VoiceEditPlan, instruction: String) -> VoiceEditPlan {
        guard case .targeted = plan.scope, plan.edits.count == 1, let span = plan.edits.first,
            !span.find.isEmpty, !span.replace.isEmpty,
            namesSwap(of: span.find, and: span.replace, in: instruction)
        else { return plan }
        var completed = plan
        completed.edits.append(VoiceEditPlan.Span(find: span.replace, replace: span.find))
        return completed
    }

    // "Swap John and Sarah", "switch Sarah with John". English only, like
    // namesEndMark.
    private static func namesSwap(of a: String, and b: String, in instruction: String) -> Bool {
        let (x, y) = (NSRegularExpression.escapedPattern(for: a), NSRegularExpression.escapedPattern(for: b))
        let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
        return instruction.range(of: #"\b(swap|switch|exchange)\b"#, options: options) != nil
            && instruction.range(
                of: #"\b(\#(x)\s+(and|with)\s+\#(y)|\#(y)\s+(and|with)\s+\#(x))\b"#, options: options) != nil
    }

    private static func applyPlan(
        _ plan: VoiceEditPlan, to selection: String, instruction: String
    ) throws -> String {
        switch plan.scope {
        case .holistic:
            let rewrite = plan.rewrite.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rewrite.isEmpty else { throw Failure.interpretationFailed }
            return rewrite

        case .targeted:
            // A 'targeted' edit whose find string covers most of the selection
            // is usually a mislabelled rewrite or a runaway find, so reject it.
            // The exception is a find that *is* the whole selection - the user
            // selected exactly the phrase to swap - which is allowed, matching
            // the case-insensitivity the apply step uses below.
            let trimmedSelection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            for span in plan.edits where span.find.count > selection.count * 6 / 10 {
                let coversWholeSelection =
                    span.find.trimmingCharacters(in: .whitespacesAndNewlines)
                    .compare(trimmedSelection, options: .caseInsensitive) == .orderedSame
                if coversWholeSelection { continue }
                log.info(
                    "Voice edit rejected: targeted find covers \(span.find.count, privacy: .public) of \(selection.count, privacy: .public) chars."
                )
                throw Failure.interpretationFailed
            }

            // Every span is matched against the passage as selected, and all
            // are replaced in one pass, so a swap (John → Sarah, Sarah → John)
            // can't turn both names into one.
            var edits: [(range: NSRange, replacement: String)] = []
            for span in plan.edits where !span.find.isEmpty {
                if deletesMarksForText(span, instruction: instruction) {
                    log.info("Voice edit rejected: it deletes punctuation for a text instruction.")
                    throw Failure.interpretationFailed
                }
                for range in occurrences(of: span.find, in: selection, instruction: instruction)
                where !edits.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) {
                    edits.append((range, span.replace))
                }
            }
            // No span matched — the model hallucinated the find text or ASR
            // garbled it. Keep the selection rather than write nothing useful.
            guard !edits.isEmpty else { throw Failure.interpretationFailed }
            return applying(edits.sorted { $0.range.location < $1.range.location }, to: selection)
        }
    }

    // Where `find` occurs: whole words first, so a short find ("we") can't
    // rewrite the inside of a longer word ("week"), then bare substrings, for
    // a partial-word find or a script written without spaces. A whole-word
    // match has no letter or digit directly beside it. Every occurrence,
    // unless there are several and the instruction picks one ("the first
    // comma") without saying every.
    private static func occurrences(of find: String, in text: String, instruction: String) -> [NSRange] {
        func isWordCharacter(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber } ?? false }
        let attempts: [(wholeWord: Bool, options: NSRegularExpression.Options)] = [
            (true, []), (true, .caseInsensitive), (false, []), (false, .caseInsensitive),
        ]
        for attempt in attempts {
            var pattern = NSRegularExpression.escapedPattern(for: find)
            if attempt.wholeWord, isWordCharacter(find.first) { pattern = #"(?<![\p{L}\p{N}])"# + pattern }
            if attempt.wholeWord, isWordCharacter(find.last) { pattern += #"(?![\p{L}\p{N}])"# }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: attempt.options) else { continue }
            let ranges = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
            guard !ranges.isEmpty else { continue }
            if ranges.count > 1, let pick = ordinal(in: instruction, find: find, count: ranges.count) {
                return [ranges[pick]]
            }
            return ranges
        }
        return []
    }

    // The occurrence an instruction names: "first" is index 0, "last" the
    // final one. nil when it names none, says every, counts past the end, or
    // the word is part of the text to change ("change last to final").
    private static func ordinal(in instruction: String, find: String, count: Int) -> Int? {
        let every = #"\b(every|all|each|everywhere|throughout|both)\b"#
        guard instruction.range(of: every, options: [.regularExpression, .caseInsensitive]) == nil,
            let match = instruction.range(
                of: #"\b(first|second|third|fourth|fifth|last|final)\b"#,
                options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let order = ["first", "second", "third", "fourth", "fifth"]
        let word = instruction[match].lowercased()
        guard !find.localizedCaseInsensitiveContains(word) else { return nil }
        let index = order.firstIndex(of: word) ?? count - 1
        return index < count ? index : nil
    }

    // Apple's model answers "delete the last sentence" by deleting every "."
    // in it. A span that only deletes marks, for an instruction about text
    // that names no mark, is a misread, not an edit.
    private static func deletesMarksForText(_ span: VoiceEditPlan.Span, instruction: String) -> Bool {
        let marks = CharacterSet(charactersIn: ".,;:!?…")
        guard span.replace.isEmpty, span.find.unicodeScalars.allSatisfy(marks.contains) else { return false }
        let namesText = #"\b(sentences?|words?|lines?|paragraphs?|phrases?|clauses?)\b"#
        let namesMark =
            #"\b(punctuation|periods?|full stops?|dots?|commas?|colons?|semicolons?|exclamation|question marks?|ellipsis|marks?)\b"#
        return instruction.range(of: namesText, options: [.regularExpression, .caseInsensitive]) != nil
            && instruction.range(of: namesMark, options: [.regularExpression, .caseInsensitive]) == nil
    }

    // `edits` in order and not overlapping. Each joint is tidied after: a
    // deleted word can leave "looks  good", "definitely, , totally" or "is ."
    // behind, and a comma swapped for a dash comes back as "team- the".
    private static func applying(_ edits: [(range: NSRange, replacement: String)], to selection: String) -> String {
        let source = selection as NSString
        let result = NSMutableString()
        var joints: [(location: Int, replacement: String, find: String)] = []
        var cursor = 0
        for edit in edits {
            result.append(source.substring(with: NSRange(location: cursor, length: edit.range.location - cursor)))
            joints.append((result.length, edit.replacement, source.substring(with: edit.range)))
            result.append(edit.replacement)
            cursor = NSMaxRange(edit.range)
        }
        result.append(source.substring(from: cursor))
        // Back to front, so each tidy leaves the joints before it in place.
        for joint in joints.reversed() {
            if joint.replacement.isEmpty {
                tidyDeletion(in: result, at: joint.location)
            } else if ["-", "–", "—"].contains(joint.replacement), [",", ";", ":"].contains(joint.find) {
                spaceDash(in: result, at: joint.location, emDash: joint.replacement == "—")
            }
        }
        return result as String
    }

    private static func tidyDeletion(in text: NSMutableString, at location: Int) {
        func char(_ i: Int) -> Character? {
            guard i >= 0, i < text.length, let scalar = Unicode.Scalar(text.character(at: i)) else { return nil }
            return Character(scalar)
        }
        let marks: Set<Character> = [",", ".", ";", ":", "!", "?"]
        if char(location - 1) == " ", char(location) == " " {
            text.deleteCharacters(in: NSRange(location: location, length: 1))
        }
        if char(location - 1) == " ", let next = char(location), marks.contains(next) || next.isNewline {
            text.deleteCharacters(in: NSRange(location: location - 1, length: 1))
            if let before = char(location - 2), before == next, [",", ";", ":"].contains(before) {
                text.deleteCharacters(in: NSRange(location: location - 1, length: 1))
            }
        }
    }

    // An em dash closes up ("team—the"); a hyphen or en dash standing in for
    // one gets a space on each side ("team - the").
    private static func spaceDash(in text: NSMutableString, at location: Int, emDash: Bool) {
        func isSpace(_ i: Int) -> Bool {
            i >= 0 && i < text.length && text.substring(with: NSRange(location: i, length: 1)) == " "
        }
        if emDash {
            if isSpace(location + 1) { text.deleteCharacters(in: NSRange(location: location + 1, length: 1)) }
            if isSpace(location - 1) { text.deleteCharacters(in: NSRange(location: location - 1, length: 1)) }
        } else {
            if location + 1 < text.length, !isSpace(location + 1) { text.insert(" ", at: location + 1) }
            if location > 0, !isSpace(location - 1) { text.insert(" ", at: location) }
        }
    }

    // MARK: - Deterministic post-processing

    private static let terminators: Set<Character> = [".", "?", "!", "…"]

    private static func reconcile(
        _ edited: String, plan: VoiceEditPlan, selection: String, instruction: String
    )
        -> String
    {
        let result = sanitize(edited, selectionWasWrapped: isWrapped(selection))
        // A targeted edit is interior and must not change the passage's ending
        // punctuation, so strip a terminator the edit introduced (ASR
        // completing the spoken phrase). Holistic rewrites are left alone —
        // there, model-chosen punctuation is intentional. So is a mark the
        // instruction names ("end with a period").
        guard case .targeted = plan.scope, !namesEndMark(instruction) else { return result }
        let selectionTerminated =
            lastNonWhitespace(of: selection).map(terminators.contains) ?? false
        guard !selectionTerminated else { return result }
        var trimmed = result
        while let last = trimmed.last, terminators.contains(last) {
            trimmed.removeLast()
        }
        return trimmed
    }

    // Strips quote / code-fence wrapping the model occasionally adds around its
    // answer, but only when the selection itself wasn't wrapped so a
    // legitimately quoted selection survives.
    private static func sanitize(_ text: String, selectionWasWrapped: Bool) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectionWasWrapped else { return result }
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("`", "`"),
        ]
        for (open, close) in pairs where result.count >= 2 {
            if result.first == open, result.last == close {
                result = String(result.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return result
    }

    private static func isWrapped(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last else {
            return false
        }
        let openers: Set<Character> = ["\"", "'", "“", "‘", "`"]
        let closers: Set<Character> = ["\"", "'", "”", "’", "`"]
        return openers.contains(first) && closers.contains(last)
    }

    private static func lastNonWhitespace(of text: String) -> Character? {
        text.reversed().first { !$0.isWhitespace }
    }

    // English only, like the voice commands that name the same marks.
    private static func namesEndMark(_ instruction: String) -> Bool {
        instruction.range(
            of: #"\b(period|full stop|question mark|exclamation|ellipsis)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Response parsing

    // Parses the fenced text protocol both backends are asked to emit. Returns
    // nil when nothing usable is found, so the caller leaves the selection
    // untouched rather than guessing.
    private static func parsePlan(_ raw: String) -> VoiceEditPlan? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let isHolistic =
            text.range(of: #"SCOPE:\s*holistic"#, options: [.regularExpression, .caseInsensitive])
            != nil
        if isHolistic {
            guard let rewrite = extractBlock(in: text, after: "@@REWRITE@@", upTo: "@@END@@") else {
                return nil
            }
            return VoiceEditPlan(scope: .holistic, edits: [], rewrite: rewrite)
        }

        var spans: [VoiceEditPlan.Span] = []
        var cursor = text.startIndex
        while let findMarker = text.range(of: "@@FIND@@", range: cursor..<text.endIndex) {
            guard
                let replaceMarker = text.range(
                    of: "@@REPLACE@@", range: findMarker.upperBound..<text.endIndex)
            else { break }
            // Gemma sometimes leaves a block's @@END@@ out, so a block also
            // ends at the next @@FIND@@ or at the end of the reply.
            let nextFind =
                text.range(of: "@@FIND@@", range: replaceMarker.upperBound..<text.endIndex)?.lowerBound
                ?? text.endIndex
            let blockEnd =
                text.range(of: "@@END@@", range: replaceMarker.upperBound..<nextFind) ?? nextFind..<nextFind
            let find = String(text[findMarker.upperBound..<replaceMarker.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let replace = String(text[replaceMarker.upperBound..<blockEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !find.isEmpty {
                spans.append(VoiceEditPlan.Span(find: find, replace: replace))
            }
            cursor = blockEnd.upperBound
        }
        return spans.isEmpty ? nil : VoiceEditPlan(scope: .targeted, edits: spans, rewrite: "")
    }

    private static func extractBlock(
        in text: String, after open: String, upTo close: String
    )
        -> String?
    {
        guard let openRange = text.range(of: open) else { return nil }
        let closeLower =
            text.range(of: close, range: openRange.upperBound..<text.endIndex)?.lowerBound
            ?? text.endIndex
        let body = String(text[openRange.upperBound..<closeLower])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    // MARK: - Prompts

    private static let systemPrompt = """
        You are a precise text editor. The user selected a passage of text and \
        spoke an instruction describing how to change it. Apply the instruction \
        exactly and report the change.

        Choose one of two modes:
        - "targeted": the instruction changes specific words or phrases. List \
        each exact substring to find in the passage and what to replace it \
        with. Keep every find string short, but long enough to match only the \
        text you mean: if the same text appears more than once, include a \
        neighbouring word, unless the instruction means every occurrence. Leave \
        the rest of the passage alone.
        - "holistic": the instruction asks to rephrase, restructure, summarise, \
        change the tone of, or translate the whole passage. Return the full \
        edited passage.

        Prefer "targeted" whenever the instruction names particular words. Use \
        "holistic" only for whole-passage transformations. Never add or remove \
        sentence-ending punctuation the instruction didn't ask for.

        Write words the user dictates exactly as spoken, without turning \
        phrases like "next year" into dates. Use all capitals only when the \
        instruction asks for capitals or uppercase: "capitalize friday" gives \
        "Friday".
        """

    private static let formatSpec = """
        Respond in EXACTLY one of these two formats and nothing else — no \
        explanation, no quotes around your answer.

        Targeted edit — one or more blocks:
        SCOPE: targeted
        @@FIND@@
        exact text copied from the passage
        @@REPLACE@@
        replacement text
        @@END@@

        Holistic edit:
        SCOPE: holistic
        @@REWRITE@@
        the full edited passage
        @@END@@

        Examples for the passage "Our team meets on Tuesday. Bring the slides.":

        Instruction "Change Tuesday to Thursday":
        SCOPE: targeted
        @@FIND@@
        Tuesday
        @@REPLACE@@
        Thursday
        @@END@@

        Instruction "Delete the last sentence":
        SCOPE: targeted
        @@FIND@@
        Bring the slides.
        @@REPLACE@@
        @@END@@

        Instruction "Capitalize the first letter of each word":
        SCOPE: holistic
        @@REWRITE@@
        Our Team Meets On Tuesday. Bring The Slides.
        @@END@@

        Instruction "Make it sound friendlier":
        SCOPE: holistic
        @@REWRITE@@
        Our team gets together on Tuesday. Don't forget to bring the slides!
        @@END@@
        """

    // The user turn, the same for both backends. The instruction comes last,
    // so warmUp(selection:) can have the model read everything before it.
    private static func userTurnPrefix(selection: String) -> String {
        """
        \(formatSpec)

        Selected passage:
        \"\"\"
        \(selection)
        \"\"\"

        Spoken instruction:
        \"\"\"

        """
    }

    private static func userTurn(instruction: String, selection: String) -> String {
        userTurnPrefix(selection: selection) + "\(instruction)\n\"\"\""
    }

    // Gemma 4's chat template: the role goes in the system turn, format and
    // request in the user turn. The BOS token is added by the tokenizer and
    // <turn|> closes each turn. No <|think|> in the system turn, so the model
    // answers without a reasoning block.
    private static let gemmaTurnsBeforeUser = "<|turn>system\n\(systemPrompt)<turn|>\n<|turn>user\n"

    private static func gemmaPromptPrefix(selection: String) -> String {
        gemmaTurnsBeforeUser + userTurnPrefix(selection: selection)
    }

    private static func gemmaPrompt(instruction: String, selection: String) -> String {
        gemmaTurnsBeforeUser + userTurn(instruction: instruction, selection: selection) + "<turn|>\n<|turn>model\n"
    }
}

// Backend-agnostic edit plan, decoded from the fenced text protocol.
struct VoiceEditPlan {
    enum Scope { case targeted, holistic }
    struct Span {
        let find: String
        let replace: String
    }
    var scope: Scope
    var edits: [Span]
    var rewrite: String
}
