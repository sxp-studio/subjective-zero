# Noise — `noise`

Animated procedural noise **texture source** (no input) — white, value, fractal (fBm), or voronoi,
selectable via the `type` enum. Grayscale output for masks, displacement, dissolves, and organic
motion. `reference-only`: the shader math (hash / value noise / fBm / voronoi) is worth studying and
adapting rather than copying verbatim.

- **Reuse:** `reference-only`. Pure GPU, no device, no permissions. Cross-platform (`any`).
- **Implementation:** render-pass template — full-screen triangle. Fragment samples `uv*scale +
  time*speed`. `hash21` (scalar) + `hash22` (vector) underpin: white = `hash21(floor(p))`; value =
  bilinear-interpolated hash; fractal = `fbm` summing `octaves` octaves (amp halving, freq doubling,
  normalized); voronoi = cellular F1 distance over the 3×3 neighborhood. `type` crosses the string
  channel → Int32 `mode` uniform.
- **Knobs:** `type` (white/value/fractal/voronoi), `scale` (0.5–32, finer as it grows), `speed`
  (0–5, 0 = still), `octaves` (1–8, fractal only). `ctx.time` drives the animation.
- **Gotchas:** the octave loop is bounded by a literal `< 8` with a runtime `break` so the GPU
  unrolls it — `octaves` is clamped to 1…8 host-side. Output is clamped to [0,1] and written as
  `float4(float3(n), 1)` (opaque gray). Only `fractal` reads `octaves`; only animated modes read
  `speed`.
