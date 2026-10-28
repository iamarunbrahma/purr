import AVFoundation
import FluidAudio
import Foundation
import os.log

// Merges a Parakeet ASRResult with a list of TimedSpeakerSegment into a
// readable Markdown transcript with `**Speaker N:** ...` blocks. Each
// token's midpoint chooses a speaker; consecutive same-speaker tokens
// concatenate verbatim (Parakeet's BPE tokens already carry leading spaces,
// so inserting our own breaks subwords: "H" + "ello" -> "H ello"). Stable
// speaker IDs ("speaker_0001") become display labels ("Speaker 1") in the
// order they first speak.
enum MeetingDocument {
    private static let log = Logger(subsystem: "com.arunbrahma.hello", category: "meetingdoc")

    struct Output {
        let markdown: String
        let recordedAt: Date
    }

    // Mic-only: every utterance is "You" - no diarization runs on this track,
    // since it can't reliably separate speakers that share one microphone.
    static func format(
        localOnly asr: ASRResult,
        duration: TimeInterval,
        recordedAt: Date
    ) -> Output {
        let utterances = localUtterances(asr: asr)

        var body = ""
        body += "# Meeting - \(formatTimestamp(recordedAt))\n\n"
        body += "_Duration: \(formatDuration(duration))_  "
        body += "_Speakers: \(utterances.isEmpty ? 0 : 1)_  "
        body += "_Engine: Parakeet TDT v2_\n\n"
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
    static func format(
        localASR: ASRResult,
        remoteASR: ASRResult,
        remoteSegments: [TimedSpeakerSegment],
        duration: TimeInterval,
        recordedAt: Date
    ) -> Output {
        let labelMap = buildLabelMap(segments: remoteSegments)
        var utterances = remoteUtterances(
            asr: remoteASR, segments: remoteSegments, labelMap: labelMap)
        utterances += localUtterances(asr: localASR)
        utterances.sort(by: { $0.startTime < $1.startTime })

        let speakerCount = Set(utterances.map(\.speaker)).count

        var body = ""
        body += "# Meeting - \(formatTimestamp(recordedAt))\n\n"
        body += "_Duration: \(formatDuration(duration))_  "
        body += "_Speakers: \(speakerCount)_  "
        body += "_Engine: Parakeet TDT v2 + FluidAudio Diarizer_\n\n"
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
            for timing in timings {
                let token = timing.token
                if token.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                appendToken(
                    token, speaker: remoteFallbackSpeaker, start: timing.startTime,
                    end: timing.endTime, into: &result)
            }
            return result.isEmpty
                ? rawUtterance(asr: asr, speaker: remoteFallbackSpeaker) : result
        }
        let sorted = segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds })

        var result: [TimedUtterance] = []
        for timing in timings {
            let token = timing.token
            if token.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let midpoint = (timing.startTime + timing.endTime) / 2.0
            let speakerId = speakerAt(time: midpoint, segments: sorted)
            let label = labelMap[speakerId] ?? speakerId
            appendToken(
                token, speaker: label, start: timing.startTime, end: timing.endTime,
                into: &result)
        }
        return result.isEmpty ? rawUtterance(asr: asr, speaker: remoteFallbackSpeaker) : result
    }

    private static func localUtterances(asr: ASRResult) -> [TimedUtterance] {
        guard let timings = asr.tokenTimings, !timings.isEmpty else { return [] }
        var result: [TimedUtterance] = []
        for timing in timings {
            let token = timing.token
            if token.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            appendToken(
                token, speaker: "You", start: timing.startTime, end: timing.endTime,
                into: &result)
        }
        return result
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

    private static func appendToken(
        _ token: String,
        speaker: String,
        start: Double,
        end: Double,
        into result: inout [TimedUtterance]
    ) {
        // TDT often timestamps sentence-final punctuation well after the word
        // it closes, sometimes into the next speaker's segment - trusting that
        // timestamp would strand it alone or at the head of the next turn.
        // Glue it onto the current utterance instead, keeping the utterance's
        // end time on the spoken word so the late mark can't skew later gaps.
        if isPunctuationOnly(token), !result.isEmpty {
            result[result.count - 1].text += token
            return
        }
        if var last = result.last, last.speaker == speaker,
            start - last.endTime <= utteranceGapSeconds
        {
            last.text += token
            last.endTime = end
            result[result.count - 1] = last
        } else {
            result.append(
                TimedUtterance(speaker: speaker, text: token, startTime: start, endTime: end))
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
        // slightly tighter than ASR), fall back to the closest by midpoint.
        for seg in segments {
            if Double(seg.startTimeSeconds) <= time, time <= Double(seg.endTimeSeconds) {
                return seg.speakerId
            }
        }
        var bestId = segments.first?.speakerId ?? "speaker_unknown"
        var bestDistance = Double.infinity
        for seg in segments {
            let mid = (Double(seg.startTimeSeconds) + Double(seg.endTimeSeconds)) / 2.0
            let d = abs(mid - time)
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
