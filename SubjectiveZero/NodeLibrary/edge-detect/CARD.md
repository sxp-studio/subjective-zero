# Edge Detect — `edge-detect`

A 3×3 Sobel operator on luminance. Pixels where the gradient magnitude crosses `threshold` are painted
`edgeColor`; everything else takes `bgColor` — an outline / toon / blueprint look.

- **Reuse:** `reference-only`. The 9-tap neighborhood + Sobel kernel is the reusable part; clone it for
  other convolution filters (emboss, sharpen, Laplacian).
- **Implementation:** SAMPLED render template. Nine neighbor samples (offsets `thickness * texelSize`)
  are reduced to luminance (`dot(rgb, (0.299,0.587,0.114))`), the horizontal/vertical Sobel gradients
  give `mag = length(gx,gy)`, and `smoothstep(threshold, threshold*2, mag)` yields the edge mask blended
  `mix(bgColor, edgeColor, e)`. Uniforms: `texelSize`, `threshold`, `thickness`, `edgeColor`, `bgColor`.
- **Knobs:** `threshold` (0–1, default 0.2) — lower = more edges; `thickness` (0.5–3, default 1) — tap
  spread; `edgeColor` / `bgColor` (colorWell). All read live.
- **Gotchas:** the input must be connected — nil input skips the frame. colorRGBA inputs arrive as 4
  floats via `ctx.inputFloats`; guard the count (see `simd4`). `thickness` scales sample offsets, not a
  true line width, so very high values start to alias.
