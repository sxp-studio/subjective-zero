// audio-bands — the "Frequency Bands" library node (NODE_LIBRARY.md). Pure math, NO device and NO GPU:
// it reduces a power spectrum (`magnitudes`, a `floatArray` from audio-fft) into 10 named, normalized
// (0..1) frequency buckets on octave centers 32 Hz … 16 kHz — the canonical "10 frequency buckets" the
// audio pipeline targets. `reuse: copy-as-is`.
//
// Each band averages the spectrum power in its octave-wide range, takes sqrt (→ magnitude), normalizes by
// a frequency-adaptive divisor (high bands carry less energy) scaled by a live `sensitivity`, clamps to
// 0..1, and applies asymmetric attack/decay smoothing (fast rise, slow fall) so the values read like a
// musical level meter. `sensitivity`/`attack`/`release` are live knobs (defaults reproduce the built-in
// tuning). Emits each band as a `float` over the connected value channel (read downstream with
// `ctx.inputFloat`). Adapted from SBAudioPipeline band math + SBFrequencyBandNode smoothing.
import Foundation

private let kSampleRate: Float = 48_000
private let kBandNames = ["hz32", "hz64", "hz128", "hz256", "hz512", "hz1k", "hz2k", "hz4k", "hz8k", "hz16k"]
private let kBandCenters: [Float] = [32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384]
private let kAttack: Float = 0.15      // default; smaller = faster rise
private let kRelease: Float = 0.92     // default; larger = slower fall

final class Node: SZNode {
    private var smoothed = [Float](repeating: 0, count: kBandNames.count)

    func update(_ ctx: SZFrameContext) {
        // Live knobs (defaults reproduce the built-in tuning).
        let sensitivity = max(0.01, ctx.inputFloat("sensitivity") ?? 1)
        let attack = min(max(ctx.inputFloat("attack") ?? kAttack, 0), 1)
        let release = min(max(ctx.inputFloat("release") ?? kRelease, 0), 1)

        guard let mags = ctx.inputFloatArray("magnitudes"), mags.count > 1 else {
            // No spectrum yet → let every band decay toward 0 and emit it (keeps the meter alive).
            for b in kBandNames.indices {
                smoothed[b] *= release
                ctx.setOutputFloat(kBandNames[b], smoothed[b])
            }
            return
        }
        let binHz = kSampleRate / Float(mags.count * 2)   // fftSize = bins × 2; ≈23 Hz/bin @ 2048
        let nyquistBin = mags.count - 1

        for b in kBandNames.indices {
            let center = kBandCenters[b]
            let lo = center / 1.414213, hi = center * 1.414213   // half-octave each side
            let binLo = max(1, Int(lo / binHz))
            let binHi = min(nyquistBin, Int(hi / binHz))
            var energy: Float = 0
            var n = 0
            if binHi >= binLo {
                for k in binLo...binHi { energy += mags[k]; n += 1 }
                energy /= Float(max(1, n))
            }
            let mag = sqrt(energy)
            // Frequency-adaptive normalization: higher bands have less power, so divide by less.
            let divisor: Float = center < 100 ? 0.1 : center < 500 ? 0.05 : center < 2000 ? 0.02
                : center < 8000 ? 0.01 : 0.005
            let current = min(1, mag / divisor * sensitivity)

            let prev = smoothed[b]
            smoothed[b] = current > prev
                ? prev + (current - prev) * (1 - attack)     // fast attack
                : prev * release + current * (1 - release)    // slow release
            ctx.setOutputFloat(kBandNames[b], smoothed[b])
        }
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
