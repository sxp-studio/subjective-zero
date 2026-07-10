# Grain — `grain`

Adds animated hash noise to the input, faking film / sensor grain. The noise field advances with
`ctx.time`, so it visibly churns every frame rather than sitting as a static dither.

- **Reuse:** `copy-as-is`. Pure GPU, no device, no permissions. Cross-platform (`any`). Animated —
  reads `ctx.time`.
- **Implementation:** compute kernel, one thread per pixel. A classic `fract(sin(dot(...)) * 43758.5453)`
  hash seeds per-pixel noise; the seed mixes `uv * size * dimensions * 0.01` with `time * speed`, so the
  pattern both scales (`size`) and drifts (`speed`). Output is `c.rgb + (n - 0.5) * amount`, alpha kept.
  `ctx.time` is passed as a `time` uniform (Float). Pipeline built once in `setup()`.
- **Knobs:** `amount` (0–0.5, default 0.08) — intensity; `size` (0.5–4, default 1) — grain scale;
  `speed` (0–5, default 1) — churn rate (0 freezes the field). All read live.
- **Gotchas:** the input must be connected — nil input skips the frame. Animation depends on `ctx.time`
  advancing; if the graph is paused the field holds still. `amount` is added (not clamped) — high values
  clip on an 8-bit target, which is the expected grainy look.
