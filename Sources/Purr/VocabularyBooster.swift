@preconcurrency import CoreML
import FluidAudio
import Foundation
import os.log

// Names and terms in dictation. After Parakeet transcribes, a small second
// model, Parakeet CTC 110M, scores the audio against the user's Words, and a
// word Parakeet misspelled is swapped for the listed one where the audio
// backs it. FluidAudio's rescorer finds and scores the candidates; Purr picks
// which to take (see `rewrite`). English only, like Parakeet v2.
@MainActor
final class VocabularyBooster {
    private struct Models {
        let spotter: CtcKeywordSpotter
        let directory: URL
        // Lowercase words of macOS's word list, for the everyday-word guard.
        let everyday: Set<String>
    }

    private struct Vocabulary {
        let words: [String]
        let context: CustomVocabularyContext
        let rescorer: VocabularyRescorer
        let minSimilarity: Float
        let cbw: Float
    }

    private var models: Models?
    private var loadTask: Task<Models, Error>?
    private var vocabulary: Vocabulary?
    let download = DownloadReporter()
    private let log = Logger(subsystem: "com.arunbrahma.purr", category: "vocabulary")

    // FluidAudio swaps in a term when its CTC score plus a boost, cbw times a
    // length factor, beats the original's. At its cbw of 4.5, a list of words
    // never said put a wrong word into 5-7% of LibriSpeech dictations; at 1.5
    // with the guards in `accepts`, 0.1-0.4%, still fixing about two thirds
    // of misspelled names.
    private static let cbw: Float = 1.5
    // How far a listed word must beat an everyday one on the audio alone.
    // Every wrong swap of an everyday word in that test won by less than 0.8.
    private static let everydayMargin: Float = 1
    // The same for words that join into one listed term, "type script" for
    // TypeScript. Said on purpose in a test of tech terms in five voices,
    // "our sales force" and "the drop box" won by up to 1.7.
    private static let joinMargin: Float = 2
    private static let marginSeconds = 0.5
    // FluidAudio skips shorter terms when spotting, and they match too much.
    private static let minWordLength = 3

    static var modelDirectory: URL {
        ModelManager.modelsDirectory.appendingPathComponent(Repo.parakeetCtc110m.folderName, isDirectory: true)
    }

    static func isInstalled() -> Bool {
        ModelManager.filesComplete(
            ModelNames.CTC.requiredModels.union([ModelNames.CTC.vocabularyPath, "tokenizer.json"]),
            in: modelDirectory)
    }

    static func delete() throws {
        let url = modelDirectory
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // The Words worth listening for: trimmed, long enough, each once.
    static func terms(_ entries: [VocabularyWordEntry]) -> [String] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            let word = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard word.count >= minWordLength, seen.insert(word.lowercased()).inserted else { return nil }
            return word
        }
    }

    // Starts loading once there's a word to listen for. The first load
    // compiles the encoder for the Neural Engine, which takes about half a
    // minute, so it runs ahead of the first dictation that needs it.
    func warmup() {
        guard models == nil, !Self.terms(SettingsStore.shared.vocabularyWords).isEmpty, Self.isInstalled()
        else { return }
        startLoading()
    }

    // The row stays up through the first load, which FluidAudio's progress
    // reports as compiling once the last byte is in.
    func downloadAndLoad() async throws {
        download.begin()
        defer { download.end() }
        if !Self.isInstalled() {
            try await ModelHub.download(
                .parakeetCtc110m, to: ModelManager.modelsDirectory, progressHandler: download.handler)
        }
        // Set here too, so a dictation right after this returns can use it.
        let task = startLoading()
        let loaded = try await task.value
        if loadTask == task { models = loaded }
    }

    // MUST run before the folder is deleted, so no graph stays mapped.
    func unload() {
        loadTask?.cancel()
        loadTask = nil
        models = nil
        vocabulary = nil
        log.info("Vocabulary model unloaded.")
    }

    @discardableResult
    private func startLoading() -> Task<Models, Error> {
        if let loadTask { return loadTask }
        let directory = Self.modelDirectory
        let started = Date()
        let task = Task.detached(priority: .utility) { try await Self.loadModels(from: directory) }
        loadTask = task
        Task { [weak self] in
            do {
                let loaded = try await task.value
                guard let self, self.loadTask == task else { return }
                self.models = loaded
                self.log.info(
                    "Vocabulary model loaded in \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public) s."
                )
            } catch {
                guard let self, self.loadTask == task else { return }
                self.loadTask = nil
                self.log.error("Vocabulary model failed to load: \(error.localizedDescription, privacy: .public)")
            }
        }
        return task
    }

    private nonisolated static func loadModels(from directory: URL) async throws -> Models {
        // Not CtcModels.load: it puts both models on the Neural Engine, where
        // the mel spectrogram model returns near-silence and every listed word
        // would win. The mel model runs on the CPU instead.
        func model(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let config = MLModelConfiguration()
            config.computeUnits = units
            return try MLModel(contentsOf: directory.appendingPathComponent(name), configuration: config)
        }
        let mel = try model(ModelNames.CTC.melSpectrogramPath, .cpuOnly)
        let encoder = try model(ModelNames.CTC.audioEncoderPath, .cpuAndNeuralEngine)
        let vocabData = try Data(contentsOf: directory.appendingPathComponent(ModelNames.CTC.vocabularyPath))
        let vocab = (try JSONSerialization.jsonObject(with: vocabData) as? [String: String] ?? [:])
            .reduce(into: [Int: String]()) { result, pair in
                if let id = Int(pair.key) { result[id] = pair.value }
            }
        try Task.checkCancellation()
        let ctc = CtcModels(
            melSpectrogram: mel, encoder: encoder, configuration: MLModelConfiguration(), vocabulary: vocab,
            variant: .ctc110m)
        return Models(
            spotter: CtcKeywordSpotter(models: ctc, blankId: vocab.count), directory: directory,
            everyday: loadEverydayWords())
    }

    // The lowercase entries of /usr/share/dict/words (Webster's Second). An
    // empty set leaves the everyday-word guard off.
    private nonisolated static func loadEverydayWords() -> Set<String> {
        guard let list = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        var words = Set<String>(minimumCapacity: 240_000)
        for line in list.split(separator: "\n") {
            let word = String(line)
            if word == word.lowercased() { words.insert(word) }
        }
        return words
    }

    // The transcript with the user's Words swapped in where the audio backs
    // them, or unchanged: with no Words, no model, the model still loading,
    // or anything failing, dictation goes on without it.
    func apply(to result: ASRResult, samples: [Float]) async -> String {
        let words = Self.terms(SettingsStore.shared.vocabularyWords)
        guard !words.isEmpty, let timings = result.tokenTimings, !timings.isEmpty else { return result.text }
        guard let models else {
            if Self.isInstalled() {
                startLoading()
                log.notice("Vocabulary model still loading - this dictation goes without it.")
            }
            return result.text
        }
        let started = Date()
        do {
            let vocabulary = try await self.vocabulary(for: words, models: models)
            guard
                vocabulary.rescorer.hasCTCRescoringCandidates(
                    transcript: result.text, tokenTimings: timings, minSimilarity: vocabulary.minSimilarity)
            else { return result.text }
            // A stuck Core ML call can't hold the dictation: past this, the
            // transcript goes out as Parakeet wrote it.
            let budget: Duration = .seconds(10) + .seconds(Double(samples.count) / 16_000 / 4)
            let spotter = models.spotter
            let context = vocabulary.context
            let spot = try await withTimeout(budget) {
                try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: context)
            }
            guard !spot.logProbs.isEmpty else { return result.text }
            let evidence = vocabulary.rescorer.ctcTokenEvaluateCandidates(
                transcript: result.text, tokenTimings: timings, logProbs: spot.logProbs,
                frameDuration: spot.frameDuration, cbw: vocabulary.cbw, marginSeconds: Self.marginSeconds,
                minSimilarity: vocabulary.minSimilarity)
            let text = Self.rewrite(evidence, cbw: vocabulary.cbw, everyday: models.everyday)
            log.info(
                "Vocabulary pass in \(String(format: "%.2f", Date().timeIntervalSince(started)), privacy: .public) s: \(evidence.candidates.count, privacy: .public) candidates, \(text == result.text ? "no change" : "words swapped", privacy: .public)."
            )
            return text
        } catch {
            log.error("Vocabulary pass failed, keeping the transcript: \(error.localizedDescription, privacy: .public)")
            return result.text
        }
    }

    // Rebuilt only when the Words change.
    private func vocabulary(for words: [String], models: Models) async throws -> Vocabulary {
        if let vocabulary, vocabulary.words == words { return vocabulary }
        let tokenizer = try await CtcTokenizer.load(from: models.directory)
        let context = CustomVocabularyContext(
            terms: words.compactMap { word in
                let ids = tokenizer.encode(word)
                return ids.isEmpty ? nil : CustomVocabularyTerm(text: word, ctcTokenIds: ids)
            })
        // Rescue off: it adds a term wherever the audio scores it, with no
        // similar word in the transcript, and swapped in names never said.
        let rescorer = try await VocabularyRescorer.create(
            spotter: models.spotter, vocabulary: context,
            config: VocabularyRescorer.Config(spotterRescueEnabled: false), ctcModelDirectory: models.directory)
        let size = ContextBiasingConstants.rescorerConfig(forVocabSize: context.terms.count)
        let built = Vocabulary(
            words: words, context: context, rescorer: rescorer,
            minSimilarity: max(size.minSimilarity, context.minSimilarity), cbw: size.cbw)
        vocabulary = built
        return built
    }

    // ------------------------------------------------------------------
    // Choosing replacements
    // ------------------------------------------------------------------

    private static let endings: Set<String> = [
        "", "s", "es", "ism", "ist", "ists", "ian", "ians", "ite", "ites", "ed", "ing", "er", "ers",
    ]

    // The base text with each accepted candidate swapped in. Overlapping
    // candidates go to the widest margin; one without an exact place in the
    // text is left out rather than guessed.
    static func rewrite(
        _ evidence: VocabularyRescorer.CandidateEvidenceOutput, cbw evaluatedCbw: Float, everyday: Set<String>
    ) -> String {
        func margin(_ c: VocabularyRescorer.CandidateEvidence) -> Float {
            (c.rawVocabularyCTCScore ?? 0) + (c.effectiveBoost ?? 0) - (c.rawOriginalCTCScore ?? 0)
        }
        // A candidate for a term inside words that join into it gives way,
        // whether they pass or not: "type script" becomes TypeScript or stays,
        // never "type TypeScript".
        let joins = evidence.candidates.filter { joinsWords($0, everyday: everyday) }
        let passing = evidence.candidates
            .filter { c in
                accepts(c, cbw: evaluatedCbw, everyday: everyday)
                    && !joins.contains { j in
                        j.canonicalTerm == c.canonicalTerm && j.wordRange.count > c.wordRange.count
                            && j.wordRange.lowerBound <= c.wordRange.lowerBound
                            && c.wordRange.upperBound <= j.wordRange.upperBound
                    }
            }
            .sorted { margin($0) > margin($1) }
        let words = wordRanges(evidence.baseWords, in: evidence.baseText)
        var taken = Set<Int>()
        var chosen: [(range: Range<Int>, term: String)] = []
        for candidate in passing {
            let span = Set(candidate.wordRange)
            guard !span.isEmpty, span.isDisjoint(with: taken) else { continue }
            taken.formUnion(span)
            if let range = candidate.baseTextUTF8Range ?? place(of: candidate, in: evidence.baseText, words: words) {
                chosen.append((range, candidate.canonicalTerm))
            }
        }
        var text = evidence.baseText
        // Back to front, so the byte offsets before each one still hold.
        for (range, term) in chosen.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let utf8 = text.utf8
            guard range.upperBound <= utf8.count,
                let lower = String.Index(utf8.index(utf8.startIndex, offsetBy: range.lowerBound), within: text),
                let upper = String.Index(utf8.index(utf8.startIndex, offsetBy: range.upperBound), within: text)
            else { continue }
            text.replaceSubrange(lower..<upper, with: keepingPossessive(of: text[lower..<upper], term))
        }
        return text
    }

    // Where each word sits in the text, when they follow each other with only
    // whitespace between.
    private static func wordRanges(_ words: [String], in text: String) -> [Range<String.Index>]? {
        var ranges: [Range<String.Index>] = []
        var cursor = text.startIndex
        for word in words {
            while cursor < text.endIndex, text[cursor].isWhitespace { cursor = text.index(after: cursor) }
            guard let range = text.range(of: word, options: [.literal, .anchored], range: cursor..<text.endIndex)
            else { return nil }
            ranges.append(range)
            cursor = range.upperBound
        }
        return ranges
    }

    // FluidAudio places a candidate only when quotes or ". , ;" are all that
    // surround it, so a name ending a question ("Siobhan?") would be skipped.
    // This trims "? ! :" and brackets too, and keeps FluidAudio's check that
    // the text there is the phrase it scored.
    private static func place(
        of c: VocabularyRescorer.CandidateEvidence, in text: String, words: [Range<String.Index>]?
    ) -> Range<Int>? {
        guard let words, !c.wordRange.isEmpty, c.wordRange.lowerBound >= 0, c.wordRange.upperBound <= words.count
        else { return nil }
        let openers: Set<Character> = ["\"", "'", "“", "‘", "(", "["]
        let closers: Set<Character> = [".", ",", ";", ":", "!", "?", "…", "\"", "'", "”", "’", ")", "]"]
        var lower = words[c.wordRange.lowerBound].lowerBound
        var upper = words[c.wordRange.upperBound - 1].upperBound
        while lower < upper, openers.contains(text[lower]) { lower = text.index(after: lower) }
        while lower < upper, closers.contains(text[text.index(before: upper)]) { upper = text.index(before: upper) }
        guard lower < upper, letters(text[lower..<upper]) == letters(c.basePhrase) else { return nil }
        return text.utf8.distance(from: text.startIndex, to: lower)..<text.utf8.distance(from: text.startIndex, to: upper)
    }

    // FluidAudio's test, with a smaller boost and four guards:
    //   - words that join into the term, spelling it or all everyday words,
    //     must win clearly on the audio alone: "type script" said as one
    //     word becomes TypeScript, "our sales force" stays,
    //   - the same word with another ending stays (Luther's, Mormons),
    //   - any other span of several words can't swallow an everyday word,
    //   - a phrase of everyday words gets no boost and must win clearly on
    //     the audio alone: Barry and berry sound the same, so berry stays.
    static func accepts(
        _ c: VocabularyRescorer.CandidateEvidence, cbw evaluatedCbw: Float, everyday: Set<String>
    ) -> Bool {
        guard let v = c.rawVocabularyCTCScore, let o = c.rawOriginalCTCScore, let b = c.effectiveBoost,
            v.isFinite, o.isFinite, b.isFinite
        else { return false }
        let words = c.basePhrase.split(whereSeparator: \.isWhitespace)
        let termWords = c.canonicalTerm.split(whereSeparator: \.isWhitespace).count
        if words.count > termWords, spells(words, c.canonicalTerm) || isEveryday(words, everyday) {
            return v > o + joinMargin
        }
        if isRelated(words, to: c.canonicalTerm) { return false }
        if words.count > termWords, words.contains(where: { isEveryday([$0], everyday) }) { return false }
        if isEveryday(words, everyday) { return v > o + everydayMargin }
        return v + b * cbw / evaluatedCbw > o
    }

    // Several words that spell the term, or everyday words that score better
    // as it: "type script", "super base".
    private static func joinsWords(_ c: VocabularyRescorer.CandidateEvidence, everyday: Set<String>) -> Bool {
        let words = c.basePhrase.split(whereSeparator: \.isWhitespace)
        guard words.count > 1 else { return false }
        if spells(words, c.canonicalTerm) { return true }
        guard let v = c.rawVocabularyCTCScore, let o = c.rawOriginalCTCScore else { return false }
        return isEveryday(words, everyday) && v > o
    }

    private static func spells(_ words: [Substring], _ term: String) -> Bool {
        letters(words.joined()) == letters(term)
    }

    private static func letters<S: StringProtocol>(_ s: S) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // "Laocadia's" keeps its 's when it becomes "Leocadia", but a term that
    // ends in s had it already: "Postga's" becomes "Postgres".
    private static func keepingPossessive(of original: Substring, _ term: String) -> String {
        guard let apostrophe = original.dropLast().last, apostrophe == "'" || apostrophe == "’",
            original.last == "s" || original.last == "S", !term.lowercased().hasSuffix("s")
        else { return term }
        return term + String(apostrophe) + "s"
    }

    private static func bare(_ word: Substring) -> String {
        var w = word.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"()[]"))
        if w.hasSuffix("'s") || w.hasSuffix("s'") { w.removeLast(2) }
        return w
    }

    private static func isEveryday(_ words: [Substring], _ everyday: Set<String>) -> Bool {
        guard !everyday.isEmpty else { return false }
        return words.allSatisfy { word in
            let w = bare(word)
            return everyday.contains(w) || (w.hasSuffix("s") && everyday.contains(String(w.dropLast())))
        }
    }

    private static func isRelated(_ words: [Substring], to term: String) -> Bool {
        let a = words.map(bare).joined()
        let b = term.lowercased().replacingOccurrences(of: " ", with: "")
        var stems: Set<String> = [a]
        if a.hasSuffix("s") { stems.insert(String(a.dropLast())) }
        if a.hasSuffix("es") { stems.insert(String(a.dropLast(2))) }
        return stems.contains { s in
            (s.count >= 4 && b.hasPrefix(s) && endings.contains(String(b.dropFirst(s.count))))
                || (b.count >= 4 && s.hasPrefix(b) && endings.contains(String(s.dropFirst(b.count))))
        }
    }
}
