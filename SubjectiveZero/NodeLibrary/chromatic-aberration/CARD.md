# Chromatic Aberration — `chromatic-aberration`

Fakes lens color fringing by sampling the red and blue channels along a radial offset from a center
point while green stays put. The offset grows with distance from `center`, so edges fringe most.

- **Reuse:** `copy-as-is`. Pure GPU, no device, no permissions. Cross-platform (`any`).
- **Implementation:** SAMPLED render template — full-screen triangle, linear `constexpr sampler`.
  `dir = uv - center`, `off = dir * amount`; red samples `uv + off`, blue `uv - off`, green + alpha at
  `uv`. Uniforms via `setFragmentBytes`: `amount` (float), `center` (float2). Pipeline built in `setup()`.
- **Knobs:** `amount` (0–0.05, default 0.01) — split strength; `center` (float2, default [0.5,0.5]) —
  the convergence point (fringe-free). Both read live.
- **Gotchas:** the input must be connected — nil input skips the frame. `center` is a colorWell-free
  float2 read via `ctx.inputFloats("center")`; guard the count before indexing. `clamp_to_edge` keeps the
  outward red sample from wrapping at the border.
