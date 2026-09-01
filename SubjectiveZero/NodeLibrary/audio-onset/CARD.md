# Onset Detector — `audio-onset`

Turns an FFT power spectrum (`magnitudes` from `audio-fft`) into musical **events**: one-frame 1.0
pulses on `kick`, `snare`, `hats` and wideband `onset` whenever that band's energy jumps, plus a
continuous 0..1 `flux` drive. The events stage of the audio pipeline: `system-audio.macos` (or
`microphone.macos`) → `audio-fft` → **`audio-onset`** → `impulse-envelope` → your visual parameter.
Levels wobble; onsets hit — wire the pulses, not the bands, when something should pop on the beat.

- **Reuse:** `copy-as-is`. Pure math — no device, no GPU, no Accelerate.
- **Permission:** none.
- **Implementation:** half-wave-rectified spectral flux per band (frame-to-frame magnitude increase),
  compared against an adaptive threshold (running mean + deviation, ~1 s time constant, dt from
  `ctx.time` so it's refresh-rate independent) that also demands a proportional margin over the mean
  (the deviation collapses on steady passages, and without that floor any wobble would fire at the
  refractory rate), with a per-band refractory gate against double-fires.
- **Inputs (live knobs):** `sensitivity` (0.25–4, default 1 — higher fires more easily), `refractory`
  (0.03–0.5 s, default 0.1 — minimum gap between pulses on one band; raise it if a band double-fires),
  `sampleRate` (default 48000 — wire it from `microphone.macos`'s `sampleRate` output so the bands sit
  on the right frequencies on 44.1/96 kHz devices; `system-audio.macos` always delivers 48 kHz).
- **Contracts:** expects `audio-fft`'s power spectrum (half of a full window). Bands: kick 47–117 Hz,
  snare 187–492 Hz, hats 5–12 kHz. Pulses are plain `float`s: 1.0 for exactly one frame.
- **Gotchas:** keep `audio-fft`'s `smoothing` at 0 — smoothing blurs the flux this node feeds on. A
  steady tone (or the capture nodes' synthetic fallback) produces near-zero flux, so no pulses: that's
  correct, onsets are changes. Detection quality is solid for percussive music, not beat-tracker grade.
