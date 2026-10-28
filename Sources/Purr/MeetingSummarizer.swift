import Foundation
import os.log

#if canImport(FoundationModels)
import FoundationModels
#endif

// Generates Minutes of Meeting from a transcript Markdown file. Output is a
// sidecar "<transcript>.summary.md" so the transcript stays untouched and a
// re-run only rewrites the summary.
//
// Two backends, picked at call time:
//
//   * Apple Foundation Models (macOS 26+, Apple Intelligence enabled and a
//     supported language). Built-in, no download or model-load cost.
//     Preferred when available.
//   * Gemma 4 E2B Instruct (Q4_0 GGUF) via llama.cpp. ~3.35 GB on disk,
//     fetched on first use, for macOS < 26, when Apple Intelligence is
//     unavailable, or when the user picks it. Lazy-loads a single
//     LlamaSession reused across summaries, with a bounded KV cache so long
//     meetings stay within memory.
//
// The shared instance is used app-wide so download-then-summarize and
// Settings' delete button operate on the same loaded model.
@MainActor
final class MeetingSummarizer {
    static let shared = MeetingSummarizer()

    enum SummarizerError: LocalizedError {
        case modelLoadFailed(Error)
        case backendUnavailable
        case emptyResponse
        case unsupportedLocale
        case contentFlagged(String)
        case generationFailed(Error)

        var errorDescription: String? {
            switch self {
            case .modelLoadFailed(let underlying):
                return "Could not load summarization model: \(underlying.localizedDescription)"
            case .backendUnavailable: return "No summarization backend available."
            case .emptyResponse: return "Summarization model returned no text."
            case .unsupportedLocale:
                return
                    "Apple Foundation Model doesn't support this device's language. Switch to Gemma in Settings → Features."
            case .contentFlagged(let reason):
                return "On-device safety guardrails blocked the summary: \(reason)."
            case .generationFailed(let underlying):
                return
                    "Summarization failed: \(underlying.localizedDescription). The transcript was saved without a summary."
            }
        }
    }

    enum Backend: Equatable {
        case appleFoundation
        case llamaCpp(installed: Bool)
        case none
    }

    private let log = Logger(subsystem: "com.arunbrahma.hello", category: "summarizer")

    // Hard ceiling on transcript characters fed to the model; longer meetings
    // get a head/tail truncation. 24K chars ≈ 6K tokens of English, leaving
    // room for the system prompt and a 1000-token response in Gemma's
    // 8192-token window. Apple FM's 4096 tokens take it in pieces.
    private static let maxTranscriptChars = 24_000

    // ~2,500 tokens of English per Apple FM piece, leaving the rest of its
    // window for the instructions, the MeetingMinutes schema and the response.
    private static let applePieceChars = 8_000

    // A shorter transcript body is treated as too short to summarize: there is
    // nothing to minute, and a model handed one fabricates a plausible meeting
    // out of noise. ~20 words is roughly 10 seconds of speech.
    private static let minWordsToSummarize = 20

    // Generous (5 min) so a hot run on a long meeting still finishes; beyond
    // that the model has almost always wandered into a repetition loop.
    private static let generationTimeout: Duration = .seconds(300)

    private init() {}

    // MUST run before deleting the on-disk weights — otherwise the ~3.3 GB
    // session stays resident and the next generation reuses a session pointing
    // at deleted files.
    func unload() async {
        log.info("Llama unload: releasing the shared runtime session.")
        await LlamaRuntime.shared.unload()
    }

    // MARK: - Backend availability

    // The chosen path for *this device right now*. Honours the user's
    // preference when both backends are usable, otherwise falls back along a
    // strict priority: Apple FM, then Gemma if downloaded, then .none (the
    // caller refuses to summarize).
    //
    // NEVER returns .llamaCpp(installed: false) - the caller would then trigger
    // a silent multi-GB download from a meeting-stop code path.
    static func currentBackend() -> Backend {
        let installed = LLMModelManager.isInstalled()
        let appleAvailable: Bool = {
            if #available(macOS 26.0, *) { return appleFoundationAvailable }
            return false
        }()
        let preference = SettingsStore.shared.summaryBackend

        if preference == .llamaCpp, installed {
            return .llamaCpp(installed: true)
        }
        if appleAvailable {
            return .appleFoundation
        }
        if installed {
            return .llamaCpp(installed: true)
        }
        return .none
    }

    // True when at least one backend is ready to summarize without further user action.
    static var canSummarizeNow: Bool {
        switch currentBackend() {
        case .appleFoundation: return true
        case .llamaCpp(let installed): return installed
        case .none: return false
        }
    }

    // True when every Apple FM gate is satisfied: macOS 26+, availability
    // `.available` (eligible hardware, Apple Intelligence on, model downloaded),
    // and a locale Apple FM understands.
    @available(macOS 26.0, *)
    static var appleFoundationAvailable: Bool {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return false }
        return model.supportsLocale()
        #else
        return false
        #endif
    }

    // MARK: - Summarize

    @discardableResult
    func summarize(transcriptURL: URL) async throws -> URL {
        let raw = try String(contentsOf: transcriptURL, encoding: .utf8)

        // Handed a near-empty transcript the model invents a meeting, so write
        // an honest stub instead of running a backend.
        let wordCount = Self.transcriptWordCount(in: raw)
        if wordCount < Self.minWordsToSummarize {
            log.info(
                "Summary stub: transcript body has \(wordCount, privacy: .public) words (< \(Self.minWordsToSummarize, privacy: .public))."
            )
            let outputURL = Self.sidecarURL(for: transcriptURL)
            try Self.shortTranscriptDocument(transcriptURL: transcriptURL)
                .data(using: .utf8)!.write(to: outputURL, options: .atomic)
            log.info("Summary stub written -> \(outputURL.path, privacy: .public)")
            return outputURL
        }

        let transcript = Self.truncate(transcript: raw, maxChars: Self.maxTranscriptChars)
        let roster = Self.speakerRoster(in: raw)
        if transcript.count != raw.count {
            log.info(
                "Transcript truncated from \(raw.count, privacy: .public) to \(transcript.count, privacy: .public) chars before summarization."
            )
        }

        let backend = Self.currentBackend()
        let summary: String
        let backendLabel: String

        switch backend {
        case .appleFoundation:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                do {
                    summary = try await runAppleFoundation(
                        transcript: transcript, roster: roster)
                    backendLabel = "Apple Foundation Model"
                    break
                } catch {
                    // Two soft failures are recovered from rather than surfaced
                    // raw, both falling back to Gemma when it is installed:
                    //   * locale — Apple FM rejects the device language at
                    //     generation time even when availability said
                    //     .available.
                    //   * content block — the safety guardrail false-positives
                    //     on benign material. Under guided generation it
                    //     arrives as .guardrailViolation OR .refusal.
                    //
                    // Classify via the TYPED error, never String(describing:):
                    // on a bridged NSError that yields a generic "operation
                    // couldn't be completed (…GenerationError error N.)" with
                    // neither case name nor reason, so a string match silently
                    // misses every guardrail trip. localizedDescription is only
                    // a defensive fallback.
                    let isLocale: Bool
                    let isContentBlock: Bool
                    if let generationError = error as? LanguageModelSession.GenerationError {
                        switch generationError {
                        case .unsupportedLanguageOrLocale:
                            isLocale = true
                            isContentBlock = false
                        case .guardrailViolation, .refusal:
                            isLocale = false
                            isContentBlock = true
                        default:
                            isLocale = false
                            isContentBlock = false
                        }
                    } else {
                        let message = error.localizedDescription.lowercased()
                        isLocale =
                            message.contains("unsupported language")
                            || message.contains("unsupported locale")
                            || message.contains("language or locale")
                        isContentBlock =
                            !isLocale && (message.contains("guardrail") || message.contains("unsafe"))
                    }
                    if isLocale || isContentBlock, LLMModelManager.isInstalled() {
                        let kind = isLocale ? "locale" : "guardrail"
                        log.info(
                            "Apple FM \(kind, privacy: .public) rejection; retrying with Gemma fallback."
                        )
                        summary = try await runLlamaCpp(rawTranscript: raw)
                        backendLabel = "Gemma 4 E2B Instruct (Q4_0, \(kind) fallback)"
                        break
                    }
                    if isLocale { throw SummarizerError.unsupportedLocale }
                    if isContentBlock {
                        throw SummarizerError.contentFlagged(error.localizedDescription)
                    }
                    throw SummarizerError.generationFailed(error)
                }
            }
            #endif
            // Fell through compile-out or available-check.
            throw SummarizerError.backendUnavailable

        case .llamaCpp(let installed):
            // currentBackend() already filters out the uninstalled case; if one
            // ever leaks through, refuse rather than triggering a 3.3 GB
            // download from a meeting-stop code path.
            guard installed else { throw SummarizerError.backendUnavailable }
            summary = try await runLlamaCpp(rawTranscript: raw)
            backendLabel = "Gemma 4 E2B Instruct (Q4_0, llama.cpp)"

        case .none:
            throw SummarizerError.backendUnavailable
        }

        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SummarizerError.emptyResponse }

        let document = sidecarDocument(
            summary: trimmed,
            transcriptURL: transcriptURL,
            backendLabel: backendLabel
        )
        let outputURL = Self.sidecarURL(for: transcriptURL)
        try document.data(using: .utf8)!.write(to: outputURL, options: .atomic)
        log.info("Summary written -> \(outputURL.path, privacy: .public)")
        return outputURL
    }

    // MARK: - Backend implementations

    // Apple FM's whole 4096-token window - instructions, schema, transcript
    // and response - holds about ten minutes of meeting. Past that, as Apple's
    // TN3193 recommends, the transcript is summarized in pieces, each in a
    // fresh session, and the pieces' minutes are combined.
    @available(macOS 26.0, *)
    private func runAppleFoundation(transcript: String, roster: [String]) async throws -> String {
        #if canImport(FoundationModels)
        let pieces = Self.pieces(of: transcript, maxChars: Self.applePieceChars)
        var parts: [MeetingMinutes] = []
        for piece in pieces {
            parts += try await appleMinutes(
                transcript: piece, roster: roster, isExcerpt: pieces.count > 1, depth: 0)
        }
        guard let first = parts.first else { throw SummarizerError.emptyResponse }
        guard parts.count > 1 else { return Self.renderMarkdown(Self.merged(parts, tldr: first.tldr)) }
        log.info("Apple FM summarized the transcript in \(parts.count, privacy: .public) pieces.")
        return Self.renderMarkdown(await combine(parts))
        #else
        throw SummarizerError.backendUnavailable
        #endif
    }

    #if canImport(FoundationModels)
    // A piece that still overflows - denser scripts run closer to a token per
    // character - is split in half until it fits.
    @available(macOS 26.0, *)
    private func appleMinutes(
        transcript: String, roster: [String], isExcerpt: Bool, depth: Int
    ) async throws -> [MeetingMinutes] {
        let session = LanguageModelSession(instructions: { Instructions(appleInstructions) })
        let prompt = appleUserPrompt(transcript: transcript, roster: roster, isExcerpt: isExcerpt)
        do {
            // Guided generation: the model fills a `MeetingMinutes` value via
            // constrained decoding, so the output shape is the Swift type's
            // schema rather than a prompt template. It structurally cannot echo
            // a placeholder block back as content - the failure mode of every
            // prompt-only attempt. Greedy sampling keeps the summary
            // deterministic.
            let response = try await session.respond(
                to: prompt,
                generating: MeetingMinutes.self,
                options: GenerationOptions(sampling: .greedy)
            )
            return [response.content]
        } catch let error as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error, depth < 3 else { throw error }
            let halves = Self.pieces(of: transcript, maxChars: transcript.count / 2 + 1)
            guard halves.count > 1 else { throw error }
            log.info(
                "Apple FM context exceeded on a \(transcript.count, privacy: .public)-char piece; splitting it in \(halves.count, privacy: .public)."
            )
            var parts: [MeetingMinutes] = []
            for half in halves {
                parts += try await appleMinutes(
                    transcript: half, roster: roster, isExcerpt: true, depth: depth + 1)
            }
            return parts
        }
    }

    // The TL;DRs are condensed into one by a final short pass, or joined if
    // that fails.
    @available(macOS 26.0, *)
    private func combine(_ parts: [MeetingMinutes]) async -> MeetingMinutes {
        let tldrs = parts.map { $0.tldr.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var tldr = tldrs.joined(separator: " ")
        do {
            let numbered = tldrs.enumerated().map { "Part \($0.offset + 1): \($0.element)" }
            let response = try await LanguageModelSession().respond(
                to: """
                    These summarize consecutive parts of one meeting, in order. Write \
                    a two or three sentence overview of the whole meeting using only \
                    facts stated in them. Reply with the overview only.

                    \(numbered.joined(separator: "\n\n"))
                    """,
                options: GenerationOptions(sampling: .greedy)
            )
            let condensed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !condensed.isEmpty { tldr = condensed }
        } catch {
            log.error(
                "Apple FM TL;DR merge failed (\(error.localizedDescription, privacy: .public)); joining the pieces' TL;DRs."
            )
        }
        return Self.merged(parts, tldr: tldr)
    }

    // Lists concatenate in meeting order, dropping repeats - across pieces,
    // and within one, where a list the model looped on holds the same item
    // until its cap. An action item repeated with another owner is a repeat.
    @available(macOS 26.0, *)
    private static func merged(_ parts: [MeetingMinutes], tldr: String) -> MeetingMinutes {
        func key(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        func unique(_ lists: [[String]]) -> [String] {
            var seen = Set<String>()
            return lists.joined().filter { seen.insert(key($0)).inserted }
        }
        var seenTasks = Set<String>()
        return MeetingMinutes(
            tldr: tldr,
            keyDecisions: unique(parts.map(\.keyDecisions)),
            actionItems: parts.flatMap(\.actionItems).filter { seenTasks.insert(key($0.task)).inserted },
            topicsDiscussed: unique(parts.map(\.topicsDiscussed)),
            openQuestions: unique(parts.map(\.openQuestions))
        )
    }
    #endif

    // Splits at utterance (paragraph) boundaries into pieces of at most
    // `maxChars`. An utterance longer than that is cut at a space, and each
    // continuation keeps the speaker label.
    private static func pieces(of transcript: String, maxChars: Int) -> [String] {
        var units: [String] = []
        for paragraph in transcript.components(separatedBy: "\n\n") where !paragraph.isEmpty {
            let label =
                paragraph.hasPrefix("**")
                ? paragraph.range(of: ":** ").map { String(paragraph[..<$0.upperBound]) } ?? ""
                : ""
            var lead = ""
            var rest = paragraph[...]
            while lead.count + rest.count > maxChars {
                let window = rest.prefix(max(maxChars - lead.count, 1))
                guard let cut = window.lastIndex(of: " "), cut > rest.startIndex else { break }
                units.append(lead + rest[..<cut])
                rest = rest[cut...].drop(while: { $0 == " " })
                lead = label
            }
            units.append(lead + rest)
        }
        func pack(closingAt target: Int) -> [String] {
            var pieces: [String] = []
            var current = ""
            var currentCount = 0
            for unit in units {
                let unitCount = unit.count
                if currentCount > 0, currentCount >= target || currentCount + 2 + unitCount > maxChars {
                    pieces.append(current)
                    current = ""
                    currentCount = 0
                }
                current += currentCount == 0 ? unit : "\n\n" + unit
                currentCount += currentCount == 0 ? unitCount : 2 + unitCount
            }
            if currentCount > 0 { pieces.append(current) }
            return pieces
        }
        // Full pieces can leave a tail of a line or two, and summarizing that
        // alone spends a model call on no context - so repack to even shares.
        let full = pack(closingAt: maxChars)
        guard full.count > 1 else { return full }
        let even = pack(closingAt: full.reduce(0) { $0 + $1.count } / full.count)
        return even.count == full.count ? even : full
    }

    // The output *shape* comes from the `MeetingMinutes` schema, so these
    // instructions govern only behaviour - what to extract, what never to
    // invent - not format.
    private var appleInstructions: String {
        """
        You generate meeting minutes from a transcript that has speaker labels.

        Use ONLY facts explicitly stated in the transcript. Never invent \
        decisions, action items, attendees, topics, numbers, or dates. When \
        the transcript contains nothing for a field, leave it empty rather \
        than guessing. Attribute each action item only to a speaker label \
        that appears in the transcript.
        """
    }

    // The speaker-roster constraint, a one-line directive, and the transcript.
    // Guided generation supplies the shape, so no format template here.
    private func appleUserPrompt(transcript: String, roster: [String], isExcerpt: Bool) -> String {
        let constraint = Self.rosterConstraint(roster)
        let header = constraint.isEmpty ? "" : "\(constraint)\n\n"
        let directive =
            isExcerpt
            ? "Summarize this excerpt from a longer meeting transcript."
            : "Summarize the following meeting transcript."
        return """
            \(header)\(directive)

            Transcript:
            \"\"\"
            \(transcript)
            \"\"\"
            """
    }

    #if canImport(FoundationModels)
    // Empty collections become `_None._` here, in Swift - the model never sees
    // a template, so it cannot fabricate placeholder content to fill one.
    @available(macOS 26.0, *)
    private static func renderMarkdown(_ minutes: MeetingMinutes) -> String {
        let tldr = minutes.tldr.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
            ## TL;DR

            \(tldr.isEmpty ? "_None._" : tldr)

            ## Key Decisions

            \(bulletList(minutes.keyDecisions))

            ## Action Items

            \(actionItemList(minutes.actionItems))

            ## Topics Discussed

            \(bulletList(minutes.topicsDiscussed))

            ## Open Questions

            \(bulletList(minutes.openQuestions))
            """
    }

    private static func bulletList(_ items: [String]) -> String {
        let cleaned =
            items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return "_None._" }
        return cleaned.map { "- \($0)" }.joined(separator: "\n")
    }

    @available(macOS 26.0, *)
    private static func actionItemList(_ items: [MeetingActionItem]) -> String {
        let rendered = items.compactMap { item -> String? in
            let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { return nil }
            let owner = item.owner.trimmingCharacters(in: .whitespacesAndNewlines)
            let due = item.due.trimmingCharacters(in: .whitespacesAndNewlines)
            var meta: [String] = []
            if !owner.isEmpty { meta.append("Owner: \(owner)") }
            if !due.isEmpty { meta.append("Due: \(due)") }
            return meta.isEmpty
                ? "- [ ] \(task)"
                : "- [ ] \(task) (\(meta.joined(separator: ", ")))"
        }
        guard !rendered.isEmpty else { return "_None._" }
        return rendered.joined(separator: "\n")
    }
    #endif

    // Distinct speaker labels in order of first appearance. Drives the "do not
    // invent speakers" constraint, so it must include You: a roster without
    // the local user leaves the model no owner for their own action items,
    // and under greedy decoding it loops through the Speaker N labels until
    // the context window overflows. Without diarized labels, one label can
    // stand for several people ("Remote", or everyone in the room as "You"),
    // so there's no roster at all.
    static func speakerRoster(in transcript: String) -> [String] {
        var roster: [String] = []
        transcript.enumerateLines { line, _ in
            guard line.hasPrefix("**"), let close = line.range(of: ":**") else {
                return
            }
            let label = String(
                line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
            if !roster.contains(label) {
                roster.append(label)
            }
        }
        return roster.contains { $0.hasPrefix("Speaker ") } ? roster : []
    }

    // Pins the model to the real speaker set. Empty when the transcript carries
    // no speaker labels (the no-diarization fallback).
    private static func rosterConstraint(_ roster: [String]) -> String {
        guard !roster.isEmpty else { return "" }
        let noun = roster.count == 1 ? "speaker" : "speakers"
        return
            "This transcript has exactly \(roster.count) \(noun): "
            + "\(roster.joined(separator: ", ")). Attribute statements only to these "
            + "labels and never mention any other speaker."
    }

    // Word count of the transcript body - everything after the Markdown
    // header's `---` rule - with or without `**Speaker N:**` labels.
    static func transcriptWordCount(in transcript: String) -> Int {
        let body: Substring
        if let separator = transcript.range(of: "\n---\n") {
            body = transcript[separator.upperBound...]
        } else {
            body = transcript[...]
        }
        return body.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).count
    }

    // The 24K-character cap assumes English at ~4 characters a token, and
    // denser scripts overrun the context window. A prompt that doesn't fit is
    // re-cut from the raw transcript in proportion to the overshoot.
    private func runLlamaCpp(rawTranscript raw: String) async throws -> String {
        var maxChars = Self.maxTranscriptChars
        var attempt = 1
        while true {
            let transcript = Self.truncate(transcript: raw, maxChars: maxChars)
            do {
                return Self.uncheckActionItems(try await generateWithWatchdog(transcript: transcript))
            } catch LlamaSession.LlamaError.promptTooLong(let tokens, let budget) {
                guard attempt < 3 else {
                    throw SummarizerError.generationFailed(
                        LlamaSession.LlamaError.promptTooLong(tokens: tokens, budget: budget))
                }
                attempt += 1
                // 5% under the proportional cut absorbs the prompt's fixed overhead.
                maxChars = transcript.count * budget / tokens * 95 / 100
                log.info(
                    "Gemma prompt is \(tokens, privacy: .public) tokens, \(budget, privacy: .public) fit; retrying with the transcript cut to \(maxChars, privacy: .public) chars."
                )
            }
        }
    }

    // Gemma 4 E2B tends to tick its action-item boxes ("- [x]"), but nothing
    // said in a meeting completes one, so they're reset to the "- [ ]" the
    // prompt asks for.
    private static func uncheckActionItems(_ markdown: String) -> String {
        markdown.replacingOccurrences(
            of: #"(?m)^(\s*[-*+]\s+)\[[xX]\]"#, with: "$1[ ]", options: .regularExpression)
    }

    private func generateWithWatchdog(transcript: String) async throws -> String {
        let prompt = chatPrompt(transcript: transcript)

        // Cancelling `work` makes LlamaSession.generate throw .cancelled at the
        // next sampling step. A corrupt/missing GGUF surfaces as
        // modelLoadFailed, kept distinct from a generation failure.
        let work = Task<String, Error> {
            do {
                return try await LlamaRuntime.shared.generate(
                    prompt: prompt, parameters: .init())
            } catch let error as LlamaSession.LlamaError {
                if case .modelLoadFailed = error {
                    throw SummarizerError.modelLoadFailed(error)
                }
                throw error
            }
        }
        let watchdog = Task<Void, Error> {
            try await Task.sleep(for: Self.generationTimeout)
            work.cancel()
        }

        do {
            let response = try await work.value
            watchdog.cancel()
            return response
        } catch {
            watchdog.cancel()
            if error is CancellationError || (error as? LlamaSession.LlamaError)?.isCancelled == true {
                log.error("Llama generation timed out after \(Self.generationTimeout) - aborting.")
                throw SummarizerError.generationFailed(
                    NSError(
                        domain: "MeetingSummarizer",
                        code: -1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Generation took longer than \(Int(Self.generationTimeout.components.seconds)) s and was aborted."
                        ]
                    ))
            }
            if error is SummarizerError { throw error }
            // Unwrapped, so runLlamaCpp can shorten the transcript and retry.
            if case LlamaSession.LlamaError.promptTooLong = error { throw error }
            throw SummarizerError.generationFailed(error)
        }
    }

    // MARK: - Output paths

    static func sidecarURL(for transcriptURL: URL) -> URL {
        let base = transcriptURL.deletingPathExtension().path
        return URL(fileURLWithPath: base + ".summary.md")
    }

    // MARK: - Transcript truncation

    // Keeps the most informative regions - the opening (attendees, agenda) and
    // the closing (decisions, action items) - and replaces the middle with an
    // explicit elision marker so the model knows what was dropped.
    private static func truncate(transcript: String, maxChars: Int) -> String {
        if transcript.count <= maxChars { return transcript }
        let head = maxChars * 6 / 10
        let tail = maxChars - head - 60  // leave room for the marker
        let start = transcript.prefix(head)
        let end = transcript.suffix(max(tail, 200))
        return "\(start)\n\n_…middle of transcript truncated for length…_\n\n\(end)"
    }

    // ------------------------------------------------------------------
    // Gemma prompts (llama.cpp path), wrapped in Gemma 4's chat template.
    // The Apple FM path uses guided generation instead - see above.
    // ------------------------------------------------------------------

    // Anti-hallucination guardrails: small models happily invent attendees and
    // action items unless pinned to the source text.
    private var systemPrompt: String {
        """
        You are a meeting minutes generator. Given a transcript with speaker
        labels, produce structured Minutes of Meeting in Markdown.

        Rules:
        - Use ONLY facts present in the transcript. Do not invent attendees,
          decisions, or action items.
        - If a section has no content, write "_None._".
        - Attribute action items to the speaker who committed to them, by
          their speaker label (e.g. "Speaker 1").
        - Be concise. Bullet points over paragraphs.
        - Output Markdown only. No preamble, no closing remarks.
        """
    }

    private func userPrompt(transcript: String) -> String {
        """
        Transcript:
        \(transcript)

        Produce these sections in this exact order, in Markdown:

        ## TL;DR
        Two or three sentences.

        ## Key Decisions
        Bulleted list. Each bullet states the decision and any
        deadlines, owners, or budgets.

        ## Action Items
        Checkbox bullets in the form: - [ ] task (Owner: Speaker N, Due: <when if stated>)

        ## Topics Discussed
        Bulleted list of topics with one-line recaps.

        ## Open Questions
        Bulleted list of unresolved questions or follow-ups.
        """
    }

    // Gemma 4's chat template. The BOS token is added by
    // llama_tokenize(add_bos: true), so it isn't repeated here. <turn|>
    // closes each turn; the bare <|turn>model trailer cues generation, and
    // with no <|think|> in the system turn there's no reasoning block.
    private func chatPrompt(transcript: String) -> String {
        """
        <|turn>system
        \(systemPrompt)<turn|>
        <|turn>user
        \(userPrompt(transcript: transcript))<turn|>
        <|turn>model

        """
    }

    private func sidecarDocument(summary: String, transcriptURL: URL, backendLabel: String) -> String {
        let date = Self.formatTimestamp(Date())
        return """
            # Meeting Summary - \(date)
            _Generated locally by \(backendLabel)._
            _Source transcript: \(transcriptURL.lastPathComponent)_

            ---

            \(summary)
            """
    }

    // An honest stub rather than a fabricated set of minutes - see
    // `minWordsToSummarize`.
    private static func shortTranscriptDocument(transcriptURL: URL) -> String {
        """
        # Meeting Summary - \(formatTimestamp(Date()))
        _Source transcript: \(transcriptURL.lastPathComponent)_

        ---

        _This recording is too short to generate minutes of meeting._
        """
    }

    private static func formatTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

}

extension LlamaSession.LlamaError {
    fileprivate var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

#if canImport(FoundationModels)

// Structured meeting minutes the Apple Foundation Model fills via constrained
// decoding. The model never sees a Markdown template, so it cannot echo
// placeholder text back as content; empty arrays render as `_None._` in
// `MeetingSummarizer.renderMarkdown`.
//
// Every list is capped. Under greedy decoding the model can get stuck
// repeating one item ("Send a quick poll this week.") until the 4096-token
// window overflows; the cap closes the list there instead, and `merged` drops
// the repeats.
@available(macOS 26.0, *)
@Generable
struct MeetingMinutes {
    @Guide(description: "A two or three sentence plain overview of what actually happened. Do not embellish.")
    let tldr: String

    @Guide(
        description: "Decisions explicitly made during the meeting. Empty when the transcript records none.",
        .maximumCount(10))
    let keyDecisions: [String]

    @Guide(description: "Action items someone explicitly committed to. Empty when there are none.", .maximumCount(10))
    let actionItems: [MeetingActionItem]

    @Guide(description: "Distinct topics actually discussed. Empty when none.", .maximumCount(10))
    let topicsDiscussed: [String]

    @Guide(description: "Questions raised but left unresolved. Empty when none.", .maximumCount(10))
    let openQuestions: [String]
}

@available(macOS 26.0, *)
@Generable
struct MeetingActionItem {
    @Guide(description: "What needs to be done.")
    let task: String

    @Guide(description: "Speaker label of the owner, exactly as written in the transcript.")
    let owner: String

    @Guide(description: "When it is due. Empty string when the transcript states no due date.")
    let due: String
}

#endif
