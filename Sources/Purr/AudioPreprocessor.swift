import Accelerate

// Deterministic per-utterance audio cleanup before the ASR engine sees it.
//
// Two passes, both standard in NeMo's training-time pipeline and therefore
// *expected* by the conformer at inference:
//
//   1. DC-offset removal. Cheap hardware (and AVAudioEngine on some Bluetooth
//      aggregate devices) introduces a constant bias that shows up as a DC bin
//      anomaly in the mel-spectrogram frontend and degrades the encoder's
//      framing on short clips.
//   2. Peak normalisation toward -3 dBFS. Quiet input is the most reliable
//      cause of "full-utterance hallucination" on Parakeet TDT - the conformer
//      was trained on broadcast-loud speech and the joint network's logit
//      margins collapse as SNR drops.
//
// No pre-emphasis filter here - FluidAudio's CoreML preprocessor already
// applies its own, and doing it twice shifts the spectrum away from the
// training distribution.
enum AudioPreprocessor {
    // Below this peak the buffer is passed through unchanged - amplifying noise
    // to "speech level" produces fake formants the model transcribes as words.
    static let silenceThresholdDbFS: Float = -60

    // -3 dBFS leaves headroom for any downstream filter inside FluidAudio's
    // preprocessor without clipping.
    static let targetPeakDbFS: Float = -3

    struct Result {
        let samples: [Float]
        // Pre-normalisation peak; the coordinator flags "mic too quiet" from it.
        let originalPeakDbFS: Float
    }

    static func normalize(_ samples: [Float]) -> Result {
        guard !samples.isEmpty else {
            return Result(samples: samples, originalPeakDbFS: -.infinity)
        }

        var out = samples

        // Pass 1: DC offset removal.
        var mean: Float = 0
        vDSP_meanv(out, 1, &mean, vDSP_Length(out.count))
        if mean != 0 {
            var negMean = -mean
            vDSP_vsadd(out, 1, &negMean, &out, 1, vDSP_Length(out.count))
        }

        // Pass 2: peak normalisation. dBFS = 20 * log10 of the linear ratio
        // against full scale (1.0 for Float32 PCM).
        var peak: Float = 0
        vDSP_maxmgv(out, 1, &peak, vDSP_Length(out.count))
        let originalPeakDbFS = peak > 0 ? 20 * log10f(peak) : -.infinity

        if originalPeakDbFS > silenceThresholdDbFS {
            let targetLinear = powf(10, targetPeakDbFS / 20)
            var gain = targetLinear / peak
            // Only boost; attenuating an already-healthy signal can push
            // borderline-quiet syllables below the model's noise floor.
            if gain > 1 {
                vDSP_vsmul(out, 1, &gain, &out, 1, vDSP_Length(out.count))
            }
        }

        return Result(samples: out, originalPeakDbFS: originalPeakDbFS)
    }
}
