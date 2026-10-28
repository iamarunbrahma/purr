import CEcho
import Foundation

// Acoustic echo cancellation for meeting mode.
//
// When the user listens to a call through speakers, the microphone re-records
// the remote participants. That echo pollutes the local "You" transcript and
// can make the diarizer invent phantom speakers. SystemAudioCapture provides a
// clean digital copy of what played out the speakers - an ideal far-end
// reference - so the echo can be subtracted back out of the mic signal.
//
// Wraps the vendored SpeexDSP echo canceller (see Sources/CEcho). Processing is
// offline over the whole recording, matching the record-then-process meeting
// flow.
enum EchoCanceller {
    // 10 ms at 16 kHz - SpeexDSP's adaptive filter wants a 10-20 ms frame.
    private static let frameSize = 160
    // 300 ms of echo tail. Long enough to absorb the speaker-to-mic acoustic
    // delay plus room reverberation without explicit delay pre-alignment.
    private static let filterLength = 4800
    private static let sampleRate = 16_000

    // Returns `mic` with `reference` (the system audio that leaked into it)
    // cancelled out. Both inputs are 16 kHz mono Float32 and the result matches
    // `mic` in length. If the canceller can't be created the mic signal passes
    // through unchanged - a missing pass beats no transcript.
    static func process(mic: [Float], reference: [Float]) -> [Float] {
        guard !mic.isEmpty else { return mic }
        guard
            let echo = cecho_create(
                Int32(frameSize), Int32(filterLength), Int32(sampleRate))
        else {
            return mic
        }
        defer { cecho_destroy(echo) }

        // Pad the mic up to a whole number of frames; pad or trim the
        // reference to the same length so every mic frame has a reference.
        let frameCount = (mic.count + frameSize - 1) / frameSize
        let padded = frameCount * frameSize
        var micBuffer = mic
        micBuffer.append(contentsOf: repeatElement(0, count: padded - micBuffer.count))
        var referenceBuffer = reference
        if referenceBuffer.count < padded {
            referenceBuffer.append(
                contentsOf: repeatElement(0, count: padded - referenceBuffer.count))
        } else if referenceBuffer.count > padded {
            referenceBuffer.removeLast(referenceBuffer.count - padded)
        }

        var output = [Float](repeating: 0, count: padded)
        micBuffer.withUnsafeBufferPointer { micPtr in
            referenceBuffer.withUnsafeBufferPointer { refPtr in
                output.withUnsafeMutableBufferPointer { outPtr in
                    for frame in 0..<frameCount {
                        let start = frame * frameSize
                        cecho_process(
                            echo,
                            micPtr.baseAddress! + start,
                            refPtr.baseAddress! + start,
                            outPtr.baseAddress! + start)
                    }
                }
            }
        }

        output.removeLast(padded - mic.count)
        return output
    }

    // Over `start`..`end` seconds, padded 40 ms for word-timing jitter: how
    // many dB cancelling took out of `mic`, how loud `cleaned` is, and how
    // loud `reference` was from one echo tail before - anything played that
    // recently can still be echoing. Levels are in dBFS.
    static func cancellation(
        mic: [Float], cleaned: [Float], reference: [Float], from start: Double, to end: Double
    ) -> (removed: Double, level: Double, reference: Double) {
        let pad = 0.04
        let lower = max(0, Int((start - pad) * Double(sampleRate)))
        let upper = min(mic.count, cleaned.count, Int((end + pad) * Double(sampleRate)))
        var micEnergy = 1e-9
        var cleanedEnergy = 1e-9
        for i in lower..<max(lower, upper) {
            micEnergy += Double(mic[i] * mic[i])
            cleanedEnergy += Double(cleaned[i] * cleaned[i])
        }
        let tailStart = max(0, lower - filterLength)
        let tailEnd = max(tailStart, min(reference.count, upper))
        var referenceEnergy = 1e-9
        for i in tailStart..<tailEnd {
            referenceEnergy += Double(reference[i] * reference[i])
        }
        return (
            10 * log10(micEnergy / cleanedEnergy),
            10 * log10(cleanedEnergy / Double(max(1, upper - lower))),
            10 * log10(referenceEnergy / Double(max(1, tailEnd - tailStart)))
        )
    }
}
