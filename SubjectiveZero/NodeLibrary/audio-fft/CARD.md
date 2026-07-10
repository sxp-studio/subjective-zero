# Audio FFT — `audio-fft`

Turns a PCM sample window (`samples`, a `floatArray`) into a **power spectrum** (`magnitudes`, a
`floatArray` of 1024 bins). The pure-DSP analysis stage of the audio pipeline: `microphone.macos` →
**`audio-fft`** → `audio-bands` → your render/visualizer node.

- **Reuse:** `copy-as-is`. No audio device, no GPU — just Accelerate/vDSP.
- **Permission:** none.
- **Implementation:** caches a 2048-point real FFT setup (`vDSP_create_fftsetup`) + a Hann window
  (`vDSP_hann_window`) ONCE in `setup()`. Each frame: Hann-window the newest 2048 samples
  (`vDSP_vmul`), pack into split-complex, `vDSP_fft_zrip` (forward), `vDSP_zvmags` (power = re²+im²),
  normalize ×1/N (`vDSP_vsmul`), and emit the 1024 magnitudes with `ctx.setOutputFloats("magnitudes", …)`.
  Destroys the FFT setup in `teardown()`.
- **Inputs (live knobs):** `window` (enum: Hann / Hamming / Blackman / Rectangular — the analysis window,
  rebuilt on change; `rect` = no windowing) and `smoothing` (0–0.95, default 0 — temporal EMA of the
  spectrum across frames, steadier bars). Both read live every frame.
- **Contracts:** input `samples` must be ≥ 2048 floats (it uses the newest 2048); output `magnitudes` is
  1024 raw-power bins (NOT yet 0..1 — normalization to named bands is `audio-bands`' job). Bin *k* maps to
  ≈ `k × 48000 / 2048` Hz (≈23 Hz/bin).
- **Gotchas:** fixed 2048-point FFT (must match the source window); emits a silent (zero) spectrum until a
  full window has arrived.
