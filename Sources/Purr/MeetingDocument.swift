import AVFoundation
import FluidAudio
import Foundation
import os.log

// Merges a Parakeet ASRResult with a list of TimedSpeakerSegment into a
// readable Markdown transcript with `**Speaker N:** ...` blocks. Tokens are
// grouped into words and each word's midpoint chooses a speaker; consecutive
// same-speaker words concatenate verbatim (Parakeet's BPE tokens already
// carry leading spaces, so inserting our own breaks subwords: "H" + "ello" ->
// "H ello"). Stable speaker IDs ("speaker_0001") become display labels
// ("Speaker 1") in the order they first speak.
enum MeetingDocument {
    private static let log = Logger(subsystem: "com.arunbrahma.purr", category: "meetingdoc")

    struct Output {
        let markdown: String
        let recordedAt: Date
    }

    // Mic-only: every utterance is "You" - no diarization runs on this track,
    // since it can't reliably separate speakers that share one microphone.
    static func format(
        localOnly asr: ASRResult,
        engine: String,
        duration: TimeInterval,
        recordedAt: Date
    ) -> Output {
        let utterances = localUtterances(asr: asr)

        var body = ""
        body += "# Meeting - \(formatTimestamp(recordedAt))\n\n"
        body += "_Duration: \(formatDuration(duration))_  "
        body += "_Speakers: \(utterances.isEmpty ? 0 : 1)_  "
        body += "_Engine: \(engine)_\n\n"
        body += "---\n\n"

        if utterances.isEmpty {
            // No usable token timings (rare) - fall back to the raw transcript
            // so the user doesn't lose the audio they just recorded.
            let cleaned = TranscriptCleaner.clean(asr.text)
            body += cleaned.isEmpty ? "_No speech detected._" : cleaned
            body += "\n"
            return Output(markdown: body, recordedAt: recordedAt)
        }

        for utt in utterances {
            let cleaned = TranscriptCleaner.clean(utt.text)
            guard !cleaned.isEmpty else { continue }
            body += "**\(utt.speaker):** \(cleaned)\n\n"
        }

        return Output(markdown: body, recordedAt: recordedAt)
    }

    // Dual-track variant for meeting mode with system-audio capture. The
    // remote track (system audio) is diarized into Speaker N; the local track
    // (echo-cancelled microphone) is the single local user, labelled You.
    // `cancellation` gives, over a span of seconds, how many dB echo
    // cancelling took out of the mic, how loud what's left is, and how loud
    // the system audio was, echo tail included, in dBFS.
    typealias Cancellation = (removed: Double, level: Double, reference: Double)

    static func format(
        localASR: ASRResult,
        remoteASR: ASRResult,
        remoteSegments: [TimedSpeakerSegment],
        cancellation: ((Double, Double) -> Cancellation)? = nil,
        engine: String,
        duration: TimeInterval,
        recordedAt: Date
    ) -> Output {
        let labelMap = buildLabelMap(segments: remoteSegments)
        var utterances = remoteUtterances(
            asr: remoteASR, segments: remoteSegments, labelMap: labelMap)
        utterances += localUtterances(
            asr: localASR, droppingEchoOf: remoteASR, cancellation: cancellation)
        utterances.sort(by: { $0.startTime < $1.startTime })

        let speakerCount = Set(utterances.map(\.speaker)).count

        var body = ""
        body += "# Meeting - \(formatTimestamp(recordedAt))\n\n"
        body += "_Duration: \(formatDuration(duration))_  "
        body += "_Speakers: \(speakerCount)_  "
        body += "_Engine: \(engine) + FluidAudio Diarizer_\n\n"
        body += "---\n\n"

        if utterances.isEmpty {
            // Neither track produced speech - fall back to the raw text so a
            // recording is never silently lost.
            let cleaned = TranscriptCleaner.clean(
                (localASR.text + " " + remoteASR.text).trimmingCharacters(in: .whitespaces))
            body += cleaned.isEmpty ? "_No speech detected._" : cleaned
            body += "\n"
            return Output(markdown: body, recordedAt: recordedAt)
        }

        for utt in utterances {
            let cleaned = TranscriptCleaner.clean(utt.text)
            guard !cleaned.isEmpty else { continue }
            body += "**\(utt.speaker):** \(cleaned)\n\n"
        }
        return Output(markdown: body, recordedAt: recordedAt)
    }

    // ------------------------------------------------------------------
    // Dual-track utterance merge
    // ------------------------------------------------------------------

    // A speaker turn with a start time, used to interleave the local and
    // remote tracks chronologically. `endTime` drives the silence-gap split.
    private struct TimedUtterance {
        var speaker: String
        var text: String
        var startTime: Double
        var endTime: Double
    }

    // A pause longer than this between two tokens ends the current utterance
    // and starts a new one, so a long monologue still interleaves naturally
    // with the other track.
    private static let utteranceGapSeconds: Double = 1.0
    private static let remoteFallbackSpeaker = "Remote"

    private static func remoteUtterances(
        asr: ASRResult,
        segments: [TimedSpeakerSegment],
        labelMap: [String: String]
    ) -> [TimedUtterance] {
        guard let timings = asr.tokenTimings, !timings.isEmpty else {
            return rawUtterance(asr: asr, speaker: remoteFallbackSpeaker)
        }
        guard !segments.isEmpty else {
            var result: [TimedUtterance] = []
            for word in words(from: timings) {
                appendWord(word, speaker: remoteFallbackSpeaker, into: &result)
            }
            return result.isEmpty
                ? rawUtterance(asr: asr, speaker: remoteFallbackSpeaker) : result
        }
        let sorted = segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds })

        var result: [TimedUtterance] = []
        for word in words(from: timings) {
            let speakerId = speakerAt(time: (word.start + word.end) / 2.0, segments: sorted)
            let label = labelMap[speakerId] ?? speakerId
            appendWord(word, speaker: label, into: &result)
        }
        return result.isEmpty ? rawUtterance(asr: asr, speaker: remoteFallbackSpeaker) : result
    }

    private static func localUtterances(
        asr: ASRResult, droppingEchoOf remote: ASRResult? = nil,
        cancellation: ((Double, Double) -> Cancellation)? = nil
    ) -> [TimedUtterance] {
        guard let timings = asr.tokenTimings, !timings.isEmpty else { return [] }
        var local = words(from: timings)
        if let remoteTimings = remote?.tokenTimings, !remoteTimings.isEmpty {
            let heard = local.count
            local = withoutEcho(
                local, remote: words(from: remoteTimings), cancellation: cancellation)
            if local.count < heard {
                log.info("Dropped \(heard - local.count, privacy: .public) of \(heard, privacy: .public) local words as speaker echo")
            }
        }
        var result: [TimedUtterance] = []
        for word in local {
            appendWord(word, speaker: "You", into: &result)
        }
        return result
    }

    // Through laptop speakers, SpeexDSP's linear canceller leaves enough of
    // the remote side in the mic that Parakeet transcribes it a second time,
    // nearly word for word, as "You". Echo repeats the remote track word after
    // word, so `echoRunWords` local words in a row that the remote track also
    // has within `echoWindowSeconds` are echo - fewer is both sides saying
    // "the" - as is a short utterance that matches all through ("Yes."). Words
    // beside that echo while the remote is talking go with it when at most
    // `echoMishearingWords` of them don't match: the echo misheard ("good
    // bugs" for "two bugs"). The user's own speech has no remote twin, so it
    // stays - over remote speech too, unless it's a word or two inside echo.
    //
    // Echo the canceller mostly removed can come out garbled past matching
    // ("a new box in each account" for "two bugs in the checkout flow"), so a
    // word that lost `echoCancelledDecibels` or more to cancelling is echo
    // too - unless what's left is near the user's own level. Over loud
    // speakers the user's words can lose that much as well, when cancelling
    // takes the echo out from under them, but the voice itself is left whole;
    // echo residue is left far quieter. The user's level is the median of
    // the words said while nothing was playing (system audio under
    // `nothingPlayingDecibels`), which echo can't be among; with none, every
    // word that lost that much goes.
    private static let echoWindowSeconds = 0.5
    private static let echoRunWords = 3
    private static let echoMishearingWords = 2
    private static let echoCancelledDecibels = 10.0
    private static let echoBelowOwnVoiceDecibels = 6.0
    private static let nothingPlayingDecibels = -50.0

    private static func withoutEcho(
        _ local: [Word], remote: [Word], cancellation: ((Double, Double) -> Cancellation)?
    ) -> [Word] {
        func key(_ word: Word) -> String {
            word.text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        // Remote words overlapping [start - slack, end + slack]; both tracks
        // share one timeline and their words run in time order.
        func remoteWords(from start: Double, to end: Double, slack: Double) -> ArraySlice<Word> {
            var lo = 0
            var hi = remote.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if remote[mid].end < start - slack { lo = mid + 1 } else { hi = mid }
            }
            var upper = lo
            while upper < remote.count, remote[upper].start <= end + slack { upper += 1 }
            return remote[lo..<upper]
        }

        let matched = local.map { word in
            let k = key(word)
            return !k.isEmpty
                && remoteWords(from: word.start, to: word.end, slack: echoWindowSeconds)
                    .contains { key($0) == k }
        }
        // Both ends of the track count as pauses.
        func pauseBefore(_ i: Int) -> Bool {
            i == 0 || i == local.count || local[i].start - local[i - 1].end > utteranceGapSeconds
        }
        // Maximal runs of words, unbroken by a pause, that satisfy `included`.
        func runs(where included: (Int) -> Bool) -> [Range<Int>] {
            var result: [Range<Int>] = []
            var start = 0
            while start < local.count {
                guard included(start) else {
                    start += 1
                    continue
                }
                var end = start + 1
                while end < local.count, included(end), !pauseBefore(end) { end += 1 }
                result.append(start..<end)
                start = end
            }
            return result
        }

        var echo = [Bool](repeating: false, count: local.count)
        for run in runs(where: { matched[$0] })
        where run.count >= echoRunWords || (pauseBefore(run.lowerBound) && pauseBefore(run.upperBound)) {
            for i in run { echo[i] = true }
        }
        if let cancellation {
            let spans = local.map { cancellation($0.start, $0.end) }
            let own = local.indices
                .filter { !echo[$0] && spans[$0].reference < nothingPlayingDecibels }
                .map { spans[$0].level }.sorted()
            let ownLevel = own.isEmpty ? Double.infinity : own[own.count / 2]
            for i in local.indices
            where !echo[i] && spans[i].removed >= echoCancelledDecibels
                && spans[i].level < ownLevel - echoBelowOwnVoiceDecibels {
                echo[i] = true
            }
        }
        // Runs are maximal, so a neighbour with no pause in between is echo.
        let anchors = echo
        for run in runs(where: { !anchors[$0] })
        where run.filter({ !matched[$0] }).count <= echoMishearingWords {
            let besideEcho = !pauseBefore(run.lowerBound) || !pauseBefore(run.upperBound)
            let remoteTalking = run.allSatisfy {
                !remoteWords(from: local[$0].start, to: local[$0].end, slack: 0.25).isEmpty
            }
            if besideEcho, remoteTalking {
                for i in run { echo[i] = true }
            }
        }
        return zip(local, echo).filter { !$0.1 }.map(\.0)
    }

    private static func rawUtterance(asr: ASRResult, speaker: String) -> [TimedUtterance] {
        let cleaned = TranscriptCleaner.clean(asr.text)
        guard !cleaned.isEmpty else { return [] }
        return [
            TimedUtterance(
                speaker: speaker,
                text: cleaned,
                startTime: 0,
                endTime: asr.duration
            )
        ]
    }

    // A whole word and its spoken span. Speakers are chosen per word, never
    // per BPE token: a diarizer boundary inside "Thanks" ("▁Th" + "ank" + "s")
    // would otherwise cut it across two turns ("Thank" / "s, Priya").
    private struct Word {
        var text: String
        var start: Double
        var end: Double
    }

    // A token with a leading space starts a word, and so does the token after
    // a bare-space token: Parakeet emits the space on its own before digits
    // and some acronyms ("the" + " " + "15th"), and dropping it glued them
    // together ("the15th").
    private static func words(from timings: [TokenTiming]) -> [Word] {
        var words: [Word] = []
        var pendingSpace = false
        for timing in timings {
            let token = timing.token
            let mark = token.trimmingCharacters(in: .whitespaces)
            if mark.isEmpty {
                pendingSpace = true
                continue
            }
            // TDT often timestamps sentence-final punctuation well after the
            // word it closes, sometimes into the next speaker's segment -
            // trusting that timestamp would strand it alone or at the head of
            // the next turn. Glue it onto the word instead, keeping the word's
            // end on the spoken sound so the late mark can't skew later gaps.
            // FluidAudio's chunk seams can also repeat a mark ("Wednesday.."),
            // so a repeat is dropped.
            if isPunctuationOnly(token), let last = words.indices.last {
                if !words[last].text.hasSuffix(mark) {
                    words[last].text += (pendingSpace ? " " : "") + token
                }
                pendingSpace = false
                continue
            }
            let leadingSpace = token.first?.isWhitespace == true
            if leadingSpace || pendingSpace || words.isEmpty {
                let text = pendingSpace && !leadingSpace ? " " + token : token
                words.append(Word(text: text, start: timing.startTime, end: timing.endTime))
            } else {
                words[words.count - 1].text += token
                words[words.count - 1].end = timing.endTime
            }
            pendingSpace = false
        }
        return words
    }

    private static func appendWord(
        _ word: Word, speaker: String, into result: inout [TimedUtterance]
    ) {
        if var last = result.last, last.speaker == speaker,
            word.start - last.endTime <= utteranceGapSeconds
        {
            last.text += word.text
            last.endTime = word.end
            result[result.count - 1] = last
        } else {
            result.append(
                TimedUtterance(
                    speaker: speaker, text: word.text, startTime: word.start, endTime: word.end))
        }
    }

    private static func isPunctuationOnly(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let marks = CharacterSet.punctuationCharacters.union(CharacterSet(charactersIn: "?!"))
        return trimmed.unicodeScalars.allSatisfy { marks.contains($0) }
    }

    static func write(_ output: Output) throws -> URL {
        let name = "Meeting \(filenameTimestamp(output.recordedAt)).md"
        let data = output.markdown.data(using: .utf8)!
        do {
            return try write(data, named: name, into: meetingsDirectory())
        } catch {
            // The configured folder may have been deleted or become unwritable;
            // fall back to the default Application Support folder rather than
            // lose the transcript (no TCC consent needed there, so this succeeds).
            let fallback = SettingsStore.defaultMeetingsDirectory
            // Only warn when a *configured* folder failed - an empty preference
            // already targets the default, so that failure is just a plain error.
            if !SettingsStore.shared.meetingsFolderPath.isEmpty {
                log.warning(
                    "Meeting save to chosen folder failed (\(error.localizedDescription, privacy: .public)); saved to default folder \(fallback.path, privacy: .public) instead"
                )
            }
            return try write(data, named: name, into: fallback)
        }
    }

    // Written next to `transcriptURL` (not re-resolved via meetingsDirectory)
    // so a fallback-folder transcript gets its audio in the same place. Mono
    // for mic-only; stereo (left = local, right = remote) for dual-track, to
    // keep the sides separable instead of baking a lossy mono mixdown.
    static func writeAudio(
        localSamples: [Float], remoteSamples: [Float]?, alongside transcriptURL: URL
    ) throws -> URL {
        let stereo = remoteSamples.map { !$0.isEmpty } ?? false
        let channelCount: AVAudioChannelCount = stereo ? 2 : 1
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: channelCount,
                interleaved: false),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(
                    stereo ? max(localSamples.count, remoteSamples!.count) : localSamples.count))
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = buffer.frameCapacity

        // Zero first: the two tracks are index-aligned but not always equal
        // length, so the shorter one's tail should be silence, not garbage.
        let left = buffer.floatChannelData![0]
        left.update(repeating: 0, count: Int(buffer.frameLength))
        localSamples.withUnsafeBufferPointer { left.update(from: $0.baseAddress!, count: $0.count) }
        if stereo, let remoteSamples {
            let right = buffer.floatChannelData![1]
            right.update(repeating: 0, count: Int(buffer.frameLength))
            remoteSamples.withUnsafeBufferPointer { right.update(from: $0.baseAddress!, count: $0.count) }
        }

        let audioURL = transcriptURL.deletingPathExtension().appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: Int(channelCount),
            AVEncoderBitRatePerChannelKey: 48_000,
        ]
        let file = try AVAudioFile(
            forWriting: audioURL, settings: settings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        try file.write(from: buffer)
        return audioURL
    }

    // For a meeting whose transcript couldn't be made: the audio alone, named
    // as its transcript would have been. Like write(_:), it falls back to the
    // default folder if `folder` (meetingsDirectory(), read by the caller)
    // fails.
    static func writeAudio(
        localSamples: [Float], remoteSamples: [Float]?, recordedAt: Date, folder: URL
    ) throws -> URL {
        let name = "Meeting \(filenameTimestamp(recordedAt)).md"
        func save(into dir: URL) throws -> URL {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return try writeAudio(
                localSamples: localSamples, remoteSamples: remoteSamples,
                alongside: dir.appendingPathComponent(name))
        }
        let fallback = SettingsStore.defaultMeetingsDirectory
        do {
            return try save(into: folder)
        } catch where folder != fallback {
            log.warning(
                "Meeting audio save to chosen folder failed (\(error.localizedDescription, privacy: .public)); saving to default folder \(fallback.path, privacy: .public) instead"
            )
            return try save(into: fallback)
        }
    }

    private static func write(_ data: Data, named name: String, into dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    // The user-chosen folder if set (from onboarding), else the default.
    static func meetingsDirectory() -> URL {
        let path = SettingsStore.shared.meetingsFolderPath
        if path.isEmpty {
            return SettingsStore.defaultMeetingsDirectory
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // ------------------------------------------------------------------
    // Label assignment
    // ------------------------------------------------------------------

    private static func buildLabelMap(segments: [TimedSpeakerSegment]) -> [String: String] {
        var map: [String: String] = [:]
        var counter = 1
        for seg in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
            if map[seg.speakerId] == nil {
                map[seg.speakerId] = "Speaker \(counter)"
                counter += 1
            }
        }
        return map
    }

    // ------------------------------------------------------------------
    // Token / segment merge
    // ------------------------------------------------------------------

    private static func speakerAt(time: Double, segments: [TimedSpeakerSegment]) -> String {
        // First containing segment wins; if none does (diarizer boundaries run
        // slightly tighter than ASR), fall back to the nearest segment edge.
        // Measuring to segment midpoints instead penalised long turns, handing
        // a word just past the end of one to a neighbour a second away.
        for seg in segments {
            if Double(seg.startTimeSeconds) <= time, time <= Double(seg.endTimeSeconds) {
                return seg.speakerId
            }
        }
        var bestId = segments.first?.speakerId ?? "speaker_unknown"
        var bestDistance = Double.infinity
        for seg in segments {
            let start = Double(seg.startTimeSeconds)
            let end = Double(seg.endTimeSeconds)
            let d = time < start ? start - time : time - end
            if d < bestDistance {
                bestDistance = d
                bestId = seg.speakerId
            }
        }
        return bestId
    }

    // ------------------------------------------------------------------
    // Formatting helpers
    // ------------------------------------------------------------------

    private static func formatTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: date)
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
