# Gradient — `gradient`

A two-color gradient **texture source** (no input). Consolidates linear / radial / angular into one
node via the `type` enum — the go-to `copy-as-is` starting point for backgrounds, masks, and ramps.

- **Reuse:** `copy-as-is`. Pure GPU, no device, no permissions. Cross-platform (`any`).
- **Implementation:** render-pass template — full-screen triangle, fragment shader computes a `t` per
  pixel and returns `mix(colorA, colorB, clamp(t,0,1))`. Uniforms passed via `setFragmentBytes`:
  `mode` (int), `colorA`/`colorB` (float4), and a packed `params` float4 = (angle, centerX, centerY, scale).
- **Knobs:** `type` (linear/radial/angular), `colorA`/`colorB` (colorWell), `angle` (linear only,
  0–2π), `center` (float2, radial/angular pivot), `scale` (spread). All read live.
- **Gotchas:** UV origin is top-left with y flipped in the vertex stage (matches the animated-gradient
  sample). `angle` is ignored for radial; `center` is ignored for linear. Reading a colorRGBA input
  yields 4 floats via `ctx.inputFloats` — guard the count before indexing (see `simd4` helper).
