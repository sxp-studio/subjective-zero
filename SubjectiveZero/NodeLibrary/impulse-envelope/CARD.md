# Impulse — `impulse-envelope`

Shapes a trigger pulse into a one-shot **attack/decay envelope**: wire a hit detector (`audio-onset`'s
`kick`/`snare`, a MIDI pad via `midi.macos`, an OSC button) into `trigger` and the `value` output punches
to 1 and falls away — the classic "pop on the beat" curve. Feed `value` into any float input (a scale,
a brightness, a blur radius) instead of wiring raw levels to it.

- **Reuse:** `copy-as-is`. Pure math — no device, no GPU.
- **Permission:** none.
- **Implementation:** `trigger` >= 0.5 starts a linear attack from the current value (retrigger mid-decay
  climbs, no snap/click); at 1 it flips to an exponential decay with ~5% left after `decay` seconds.
  dt comes from `ctx.time`, so the curve is the same at 60 and 120 Hz; a backward time step (Reset Time)
  clears it.
- **Inputs (live knobs):** `trigger` (pulse in; the slider makes an unwired node hand-pokeable),
  `attack` (0–0.5 s, default 0.01 — rise time), `decay` (0.05–3 s, default 0.35 — fall time),
  `amount` (0–2, default 1 — output scale, `value = amount × envelope`).
- **Output contract:** `value` is a `float`, 0..`amount`, emitted every frame.
- **Gotchas:** a trigger held high pins the envelope at 1 (attack keeps restarting) — pulse sources
  should emit 1.0 for a single frame, which is exactly what `audio-onset` does.
