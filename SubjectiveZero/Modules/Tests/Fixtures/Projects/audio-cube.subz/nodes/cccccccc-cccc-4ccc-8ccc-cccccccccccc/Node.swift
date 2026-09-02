// audio-onset — the "Onset Detector" library node (NODE_LIBRARY.md). Pure math, no device and no GPU:
// it watches an FFT power spectrum (`magnitudes` from audio-fft) for musical hits via spectral flux —
// the frame-to-frame increase in magnitude per band — and emits one-frame 1.0 pulses on `kick` /
// `snare` / `hats` / `onset` (wire them into impulse-envelope), plus a continuous 0..1 `flux` drive.
// `reuse: copy-as-is`.
//
// The threshold is adaptive: each band keeps a running mean and absolute deviation of its flux (time-
// constant EMAs, dt from ctx.time, so behavior matches across 30/60/120 Hz displays) and triggers when
// flux clears mean + k·deviation. `sensitivity` scales k; `refractory` (seconds) blocks double-fires.
// Band edges are Hz constants mapped to bins via `sampleRate` (wire it from microphone.macos's
// `sampleRate` output; system-audio is fixed at 48 kHz, the default).
import Foundation

private let kBandNames = ["kick", "snare", "hats", "onset"]
// band edges in Hz, mapped to bins per frame from `sampleRate` (a 44.1/96 kHz device shifts every bin).
private let kBandHz: [(lo: Float, hi: Float)] = [(47, 117), (187, 492), (5000, 12000), (47, 12000)]
private let kAverageTau: Float = 1.0      // seconds; how fast the adaptive threshold tracks the music
private let kThreshold: Float = 1.5       // deviations above the running mean, before sensitivity
private let kMargin: Float = 0.5          // AND this fraction above the mean — dev collapses on steady
                                          // passages, and without a proportional floor any wobble then
                                          // fires at the refractory rate

final class Node: SZNode {
    private var prevMag = [Float]()
    private var mag = [Float]()
    private var avg = [Float](repeating: 0, count: kBandNames.count)
    private var dev = [Float](repeating: 0, count: kBandNames.count)
    private var lastOnset = [Double](repeating: -1, count: kBandNames.count)
    private var lastTime = 0.0
    private var lastBinHz: Float = 0
    private var warmup = 0.0               // suppress triggers until the averages have seen some signal

    func update(_ ctx: SZFrameContext) {
        if ctx.time < lastTime { reset() }
        let dt = Float(min(max(ctx.time - lastTime, 0.001), 0.1))
        lastTime = ctx.time

        let sensitivity = max(0.05, ctx.inputFloat("sensitivity") ?? 1)
        let refractory = Double(ctx.inputFloat("refractory") ?? 0.1)
        let sampleRate = max(8_000, ctx.inputFloat("sampleRate") ?? 48_000)

        guard let power = ctx.inputFloatArray("magnitudes"), power.count > 1 else {
            for name in kBandNames { ctx.setOutputFloat(name, 0) }
            ctx.setOutputFloat("flux", 0)
            return
        }

        // power -> magnitude (flux on magnitude reads transients without bass dominating everything).
        if mag.count != power.count {
            mag = [Float](repeating: 0, count: power.count)
            prevMag = [Float](repeating: 0, count: power.count)
            reset()
        }
        for i in power.indices { mag[i] = sqrt(max(0, power[i])) }

        // Hz -> bin mapping (magnitudes hold the first half of a 2*count window); a rate change moves
        // every band, so the running statistics start over.
        let binHz = sampleRate / Float(power.count * 2)
        if binHz != lastBinHz { lastBinHz = binHz; reset() }

        let alpha = 1 - exp(-dt / kAverageTau)
        warmup += Double(dt)
        let top = power.count - 1

        for b in kBandNames.indices {
            let lo = min(max(1, Int(kBandHz[b].lo / binHz)), top)
            let hi = min(max(lo, Int(kBandHz[b].hi / binHz)), top)
            // half-wave rectified spectral flux, normalized per bin so band width doesn't matter.
            var flux: Float = 0
            for i in lo...hi { flux += max(0, mag[i] - prevMag[i]) }
            flux /= Float(hi - lo + 1)

            let threshold = max(avg[b] + (kThreshold / sensitivity) * dev[b],
                                avg[b] * (1 + kMargin / sensitivity)) + 1e-4
            let fired = warmup > 0.25 && flux > threshold
                && ctx.time - lastOnset[b] >= refractory
            if fired { lastOnset[b] = ctx.time }
            ctx.setOutputFloat(kBandNames[b], fired ? 1 : 0)

            // update the running statistics AFTER the compare, so the hit itself doesn't hide itself.
            avg[b] += alpha * (flux - avg[b])
            dev[b] += alpha * (abs(flux - avg[b]) - dev[b])

            if b == kBandNames.count - 1 {   // wideband drive: how far above "usual" this frame sits
                ctx.setOutputFloat("flux", min(1, flux / max(4 * avg[b], 1e-4)))
            }
        }
        swap(&mag, &prevMag)
    }

    private func reset() {
        for b in kBandNames.indices { avg[b] = 0; dev[b] = 0; lastOnset[b] = -1 }
        for i in prevMag.indices { prevMag[i] = 0 }
        warmup = 0
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
