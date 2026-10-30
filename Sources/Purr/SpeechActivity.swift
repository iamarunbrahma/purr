import Foundation

// Speech-band energy activity for Smart Typing's utterance boundaries. The
// streaming model decodes nothing at all for some short phrases ("scratch
// that" said quickly), and with no decoded words no pause ended the
// utterance - the phrase merged into the next sentence, where the backtrack
// command never saw it. This hears speech by energy instead: 20 ms frames of
// the signal high-passed at 300 Hz (a laptop mic's desk thumps and rumble sit
// below that), counted as speech when they clear the quietest level of the
// last 3 s by 15 dB for at least 160 ms - longer than a key click.
//
// Positions are sample indices counted from the first sample processed.
struct SpeechActivity {
    private static let frameLength = 320
    private static let marginDb: Float = 15
    // Keeps a near-digital-silence floor from scoring hiss as speech.
    private static let minLevelDb: Float = -60
    private static let digitalSilenceDb: Float = -100
    private static let floorFrames = 150
    private static let minRunFrames = 8

    // The batch model drops a sentence's final period when only ~0.3 s of
    // silence follows it, so an utterance keeps ~0.9 s when the pause allows.
    private static let trailingSilence = 14_400
    // The newest audio can hold an onset too short to count as speech yet.
    private static let onsetGuard = 3_200
    // Room left before the next speech so its first sound isn't clipped.
    private static let leadIn = 2_400
    // A decoded token can be stamped a little before its word gets loud.
    private static let tokenSlack = 4_800

    // Qualifying speech, oldest first.
    private(set) var runs: [(start: Int, end: Int)] = []
    var lastSpeechEnd: Int { runs.last?.end ?? 0 }

    private var filter = HighPass()
    private var energy: Float = 0
    private var frameFill = 0
    private var frames = 0
    // Three-frame smoothing, so one loud frame isn't a run on its own.
    private var recentPowers: [Float] = []
    private var levels: [Float] = []
    private var run = 0
    private var runStart = 0
    private var quietFrames = 0

    mutating func process(_ samples: [Float]) {
        for sample in samples {
            let y = filter.next(sample)
            energy += y * y
            frameFill += 1
            if frameFill == Self.frameLength { closeFrame() }
        }
    }

    private mutating func closeFrame() {
        recentPowers.append(energy / Float(Self.frameLength))
        if recentPowers.count > 3 { recentPowers.removeFirst() }
        energy = 0
        frameFill = 0
        frames += 1

        let level = 10 * log10f(recentPowers.reduce(0, +) / Float(recentPowers.count) + 1e-12)
        // Digital silence (a device still starting up) isn't the room's floor.
        if level > Self.digitalSilenceDb {
            levels.append(level)
            if levels.count > Self.floorFrames { levels.removeFirst() }
        }
        let floor = levels.min() ?? level
        guard level > max(floor + Self.marginDb, Self.minLevelDb) else {
            // A single quiet frame inside a word doesn't end the run.
            quietFrames += 1
            if quietFrames > 1 { run = 0 }
            return
        }
        if run == 0 { runStart = (frames - 1) * Self.frameLength }
        run += 1
        quietFrames = 0
        guard run >= Self.minRunFrames else { return }
        // Re-added if a cut dropped it while it was still going.
        if runs.last?.start == runStart {
            runs[runs.count - 1].end = frames * Self.frameLength
        } else {
            runs.append((runStart, frames * Self.frameLength))
        }
    }

    // Where the speech holding a decoded token at `sample` ends.
    func speechEnd(around sample: Int) -> Int {
        let own = runs.last { $0.start <= sample + Self.tokenSlack }
        return max(own?.end ?? sample, sample)
    }

    // Where to end an utterance whose speech stopped at `speechEnd`, with
    // audio available up to `limit`.
    func cutPoint(after speechEnd: Int, limit: Int) -> Int {
        var cut = min(speechEnd + Self.trailingSilence, limit - Self.onsetGuard)
        if let next = runs.first(where: { $0.start > speechEnd }) {
            cut = min(cut, next.start - Self.leadIn)
        }
        return max(cut, speechEnd)
    }

    // Forgets speech that ended before `sample` (already handed out).
    mutating func dropRuns(endingBefore sample: Int) {
        runs.removeAll { $0.end <= sample }
    }
}

// Second-order Butterworth high-pass at 300 Hz for 16 kHz audio (RBJ
// cookbook biquad).
private struct HighPass {
    private static let coefficients: (b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) = {
        let w0 = 2 * Double.pi * 300 / 16_000
        let alpha = sin(w0) / 2.0.squareRoot()  // Q = 1/sqrt(2)
        let a0 = 1 + alpha
        let b = (1 + cos(w0)) / 2 / a0
        return (Float(b), Float(-2 * b), Float(b), Float(-2 * cos(w0) / a0), Float((1 - alpha) / a0))
    }()
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    mutating func next(_ x: Float) -> Float {
        let c = Self.coefficients
        let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        return y
    }
}
