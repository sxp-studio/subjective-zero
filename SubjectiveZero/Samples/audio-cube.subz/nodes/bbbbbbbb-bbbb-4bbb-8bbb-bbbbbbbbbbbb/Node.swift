// audio-fft — the "Audio FFT" library node (NODE_LIBRARY.md). Pure DSP, NO audio device and NO GPU work:
// it reads a PCM sample window from its `samples` input (a `floatArray`, e.g. from microphone.macos) and
// emits a power spectrum on `magnitudes` (a `floatArray` of fftSize/2 bins). `reuse: copy-as-is`.
//
// A single-purpose middle stage of the audio pipeline (microphone.macos → audio-fft → audio-bands →
// your render/visualizer node). Cache the vDSP FFT setup ONCE in setup(); transform each frame in update();
// destroy the setup in teardown(). Two live knobs: `window` (the analysis window function, rebuilt on
// change) and `smoothing` (temporal EMA of the spectrum). Adapted from the original subjective designer's
// SBAudioPipeline.performAnalysis, simplified to one fixed FFT size.
import Accelerate

private let kFFTSize = 2048             // power-of-two window matching microphone.macos's `samples`

final class Node: SZNode {
    private var log2n = vDSP_Length(11)
    private var fftSetup: FFTSetup?
    private var windowBuf = [Float]()
    private var windowKind = ""            // last-applied `window` value (rebuild on change)
    private var prevMagnitudes = [Float]() // previous frame's spectrum, for temporal smoothing
    private var half: Int { kFFTSize / 2 }

    func setup(_ ctx: SZSetupContext) {
        log2n = vDSP_Length(log2(Float(kFFTSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        rebuildWindow("hann")
    }

    func update(_ ctx: SZFrameContext) {
        // Live knobs: rebuild the window only when the choice changes; clamp smoothing to a sane range.
        let requested = ctx.inputString("window") ?? "hann"
        if requested != windowKind { rebuildWindow(requested) }
        let smoothing = min(max(ctx.inputFloat("smoothing") ?? 0, 0), 0.95)

        guard let setup = fftSetup,
              let input = ctx.inputFloatArray("samples"), input.count >= kFFTSize else {
            ctx.setOutputFloats("magnitudes", [Float](repeating: 0, count: half))   // no signal yet → silent spectrum
            return
        }
        // Newest fftSize samples, windowed to cut spectral leakage.
        let samples = Array(input.suffix(kFFTSize))
        var windowed = [Float](repeating: 0, count: kFFTSize)
        vDSP_vmul(samples, 1, windowBuf, 1, &windowed, 1, vDSP_Length(kFFTSize))

        // Pack the real signal into split-complex (realp[i]=x[2i], imagp[i]=x[2i+1]) for the real FFT.
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        for i in 0..<half {
            realp[i] = windowed[2 * i]
            imagp[i] = windowed[2 * i + 1]
        }

        var magnitudes = [Float](repeating: 0, count: half)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))   // power = re² + im²
            }
        }
        var scale = 1.0 / Float(kFFTSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))   // normalize by N

        // Temporal smoothing: exponential moving average of the spectrum across frames (steadier bars).
        if smoothing > 0, prevMagnitudes.count == magnitudes.count {
            for i in 0..<magnitudes.count {
                magnitudes[i] = smoothing * prevMagnitudes[i] + (1 - smoothing) * magnitudes[i]
            }
        }
        prevMagnitudes = magnitudes
        ctx.setOutputFloats("magnitudes", magnitudes)
    }

    func teardown() {
        if let setup = fftSetup { vDSP_destroy_fftsetup(setup); fftSetup = nil }
    }

    /// (Re)build the cached analysis window. `hann` is the default; `rect` disables windowing.
    private func rebuildWindow(_ kind: String) {
        windowBuf = [Float](repeating: 0, count: kFFTSize)
        switch kind {
        case "hamming":  vDSP_hamm_window(&windowBuf, vDSP_Length(kFFTSize), 0)
        case "blackman": vDSP_blkman_window(&windowBuf, vDSP_Length(kFFTSize), 0)
        case "rect":     for i in 0..<kFFTSize { windowBuf[i] = 1 }
        default:         vDSP_hann_window(&windowBuf, vDSP_Length(kFFTSize), Int32(vDSP_HANN_NORM))
        }
        windowKind = kind
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
