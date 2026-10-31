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
// decodes it. Apple Foundation Models (macOS 26+) is the default; Gemma 4 E2B
// via llama.cpp runs when picked in Settings › Voice Edit and on macOS 14-25,
// sharing the summariser's weights. Once downloaded, Gemma also retries any
// edit Apple's model can't make.
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

    // Gemma once it's picked and downloaded. Until it's downloaded, Apple's
    // model keeps Voice Edit working, as MeetingSummarizer does for summaries.
    private static var prefersGemma: Bool {
        SettingsStore.shared.voiceEditBackend == .llamaCpp && LLMModelManager.isInstalled()
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
        let plan = keepingWordsBeforeEndMark(plan, selection: selection, instruction: instruction)
        let edited = try applyPlan(plan, to: selection)
        return reconcile(edited, plan: plan, selection: selection, instruction: instruction)
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

    private static func applyPlan(_ plan: VoiceEditPlan, to selection: String) throws -> String {
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

            // Whole words first, so a short find ("we") can't rewrite the
            // inside of a longer word ("week"). Bare substrings only when no
            // whole word matches: a partial-word find, or a script written
            // without spaces.
            let attempts: [(wholeWord: Bool, options: NSRegularExpression.Options)] = [
                (true, []), (true, .caseInsensitive), (false, []), (false, .caseInsensitive),
            ]
            var result = selection
            var anyApplied = false
            for span in plan.edits {
                guard !span.find.isEmpty else { continue }
                for attempt in attempts {
                    if let replaced = replacing(
                        span.find, with: span.replace, in: result,
                        wholeWord: attempt.wholeWord, options: attempt.options)
                    {
                        result = replaced
                        anyApplied = true
                        break
                    }
                }
            }
            // No span matched — the model hallucinated the find text or ASR
            // garbled it. Keep the selection rather than write nothing useful.
            guard anyApplied else { throw Failure.interpretationFailed }
            return result
        }
    }

    // Every occurrence of `find` replaced, or nil when there is none. A
    // whole-word match has no letter or digit directly beside it.
    private static func replacing(
        _ find: String, with replacement: String, in text: String,
        wholeWord: Bool, options: NSRegularExpression.Options
    ) -> String? {
        func isWordCharacter(_ c: Character?) -> Bool { c.map { $0.isLetter || $0.isNumber } ?? false }
        var pattern = NSRegularExpression.escapedPattern(for: find)
        if wholeWord, isWordCharacter(find.first) { pattern = #"(?<![\p{L}\p{N}])"# + pattern }
        if wholeWord, isWordCharacter(find.last) { pattern += #"(?![\p{L}\p{N}])"# }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard regex.firstMatch(in: text, range: range) != nil else { return nil }
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
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
        with. Keep every find string as short as possible and leave the rest of \
        the passage alone.
        - "holistic": the instruction asks to rephrase, restructure, summarise, \
        change the tone of, or translate the whole passage. Return the full \
        edited passage.

        Prefer "targeted" whenever the instruction names particular words. Use \
        "holistic" only for whole-passage transformations. Never add or remove \
        sentence-ending punctuation the instruction didn't ask for.
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
