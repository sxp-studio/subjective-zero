# Frequency Bands — `audio-bands`

Reduces an FFT power spectrum (`magnitudes`, a `floatArray` from `audio-fft`) into **10 named, normalized
0..1 frequency buckets** — `hz32 · hz64 · hz128 · hz256 · hz512 · hz1k · hz2k · hz4k · hz8k · hz16k` (octave
centers 32 Hz … 16 kHz). The analysis-output stage: `microphone.macos` → `audio-fft` → **`audio-bands`** →
your render/visualizer node. This is the node that satisfies a "10 frequency buckets as 0.0–1.0" request.

- **Reuse:** `copy-as-is`. Pure math — no device, no GPU, no Accelerate.
- **Permission:** none.
- **Implementation:** each band averages spectrum power over its octave-wide bin range, takes `sqrt`
  (power→magnitude), normalizes by a frequency-adaptive divisor (high bands carry less energy), clamps to
  0..1, and applies asymmetric attack/decay smoothing (fast rise, slow fall) like a level meter. Emits each
  band as a `float` output with `ctx.setOutputFloat("hz…", value)` over the connected value channel — read
  downstream with `ctx.inputFloat("hz…")`.
- **Inputs (live knobs):** `sensitivity` (0.1–4, default 1 — scales the level; turn it down if a steady
  source like a fan pegs a low band), `attack` (0–1, default 0.15 — smaller = faster rise), `release`
  (0–1, default 0.92 — larger = slower fall). All read live; defaults reproduce the built-in tuning.
- **Contracts:** input `magnitudes` is the raw 1024-bin power spectrum; sample rate is assumed 48 kHz for
  bin→Hz mapping (`fftSize = bins × 2`). Each output is a `float` in 0..1.
- **Gotchas:** the divisors are a reasonable default tuning, not calibrated SPL — use `sensitivity` to
  retune; with no spectrum the bands simply decay toward 0.
