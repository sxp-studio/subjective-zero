# Checkerboard — `checkerboard`

A two-color checkerboard pattern **texture source** (no input). The classic UV / alignment test
pattern and a `copy-as-is` starting point for any tiled procedural generator.

- **Reuse:** `copy-as-is`. Pure GPU, no device, no permissions. Cross-platform (`any`).
- **Implementation:** render-pass template — full-screen triangle, fragment shader computes cell
  parity `c = fmod(floor(uv.x*scale) + floor(uv.y*scale), 2)` and returns `mix(colorA, colorB, c)`.
  Uniforms via `setFragmentBytes`: `scale` (float), `colorA`/`colorB` (float4).
- **Knobs:** `scale` (1–64, default 8) — cells per axis; `colorA`/`colorB` (colorWell). All read live.
- **Gotchas:** UV origin is top-left with y flipped in the vertex stage (matches gradient). Reading a
  colorRGBA input yields 4 floats via `ctx.inputFloats` — guard the count before indexing (`simd4`
  helper). `scale` is snapped to whole cells by the slider step, but any float value works.
