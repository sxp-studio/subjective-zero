# Microphone — `microphone.macos`

Live microphone capture as a stream of PCM samples (`samples`, a `floatArray` of 2048 mono floats per
frame). The **source** node of the composable audio pipeline: `microphone.macos` → `audio-fft` →
`audio-bands` → your render/visualizer node. Capture only — no DSP, so it stays tiny and copy-as-is.

- **Reuse:** `copy-as-is` — copy this folder's `Node.swift` + `node-contract.json` into the new node's
  folder. Don't re-derive the AVAudioEngine boilerplate.
- **Permission:** declares `microphone`. The runtime pre-grants it on load; the node guards on
  `AVCaptureDevice.authorizationStatus(for: .audio)`. When the mic is **not** authorized (CI / no device /
  denied) it emits a deterministic **synthetic** sine mix (80/220/880/3500/8000 Hz) instead, so the whole
  pipeline still renders a non-zero spectrum without a real microphone — safe headless, no prompt.
- **Implementation:** self-contained AVFoundation — `AVAudioEngine` + `inputNode.installTap` (512-frame
  callbacks, Float32 mono) into a lock-guarded ring buffer; `update()` snapshots the latest 2048 samples
  and emits them with `ctx.setOutputFloats("samples", …)`. The runtime never touches the mic; only this
  node does.
- **Inputs (live knobs):** `gain` (0–4, default 1) — multiplies the emitted samples (real + synthetic) to
  boost a quiet mic. `device` — a dynamic dropdown of audio inputs (like `camera.macos`'s `camera`): the
  list refreshes when reopened, and picking one live-switches the engine via CoreAudio
  (`kAudioOutputUnitProperty_CurrentDevice`); an unplugged/absent selection falls back to the system
  default (an `AVAudioEngineConfigurationChange` observer reinstalls the tap on device drops). Read live.
- **Hot-reload safe:** `teardown()` removes the tap and stops the engine **before** the module unloads.
- **Output contract:** `samples` is exactly **2048** floats (a power-of-two FFT window); the sample rate is
  assumed ~48 kHz (device native + synthetic). A downstream FFT node reads it with
  `ctx.inputFloatArray("samples")`.
- **Gotchas:** mono only (channel 0); fixed 2048-sample window (not yet a latency/FFT-size enum like the
  prior art). The `device` UID→CoreAudio-id match assumes `AVCaptureDevice.uniqueID` == the device UID
  (true on macOS); a mismatch degrades gracefully to the default input.
