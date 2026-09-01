# System Audio — `system-audio.macos`

Captures **what the Mac is playing** (via ScreenCaptureKit) and emits the same fixed 2048-sample mono
PCM window as `microphone.macos`, so the whole audio pipeline is interchangeable:
**`system-audio.macos`** → `audio-fft` → `audio-onset` / `audio-bands`. This is the clean way to drive
visuals from music — a browser or music app keeps playing through the speakers, and the node gets the
mix with no room reverb or speaker-to-mic smear. The `source` dropdown narrows capture to one running
app (values are bundle ids, stable across relaunches).

- **Reuse:** `copy-as-is`.
- **Permission:** `screenRecording`. macOS applies a first grant only after the app relaunches; until
  then (and in CI / headless runs) the node reports what to do and emits the deterministic synthetic
  sine mix (80/220/880/3500/8000 Hz, same as the mic node).
- **Implementation:** an audio-only `SCStream` (2x2 video leg dialed to nothing) delivering Float32
  buffers on a private queue, downmixed to mono into a lock-guarded ring; `update()` snapshots the
  latest window each frame. Start/stop are async behind a generation counter; `teardown()` joins the
  stop with a bounded wait before the dylib unloads; SCK retains the sink, not the node.
- **Inputs (live knobs):** `gain` (0–4, default 1), `source` (dynamic dropdown: the whole mix, or one
  regular running app; a picked app that is not running falls back to the whole mix with a notice).
- **Hot-reload safe:** pause tears the stream down and resume rebuilds it (SCStream has no pause;
  restart-after-stop is unreliable).
- **Output contract:** `samples` is a `floatArray` of 2048 mono samples at 48 kHz (the stream
  configuration resamples, so 48 kHz genuinely holds regardless of the output device).
- **Gotchas:** `excludesCurrentProcessAudio` is on — SubjectiveZero's own output (a playing video-file
  node) is never captured. Capture follows the first display's mix; per-app capture needs the app to
  be running when the stream starts.
