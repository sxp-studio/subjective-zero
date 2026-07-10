# Vignette — `vignette`

Blends the image toward `color` as pixels get farther from the center, giving the classic edge
darkening (or a colored tint). Same single-pixel compute template, plus per-pixel uv from `gid`.

- **Reuse:** `copy-as-is`. Pure GPU, no device, no permissions.
- **Implementation:** compute kernel, one thread per pixel. `uv = (float2(gid)+0.5)/size`, then
  `d = distance(uv, 0.5)`, `v = smoothstep(radius, radius - softness, d)`, and
  `mix(c.rgb, color.rgb, (1 - v) * amount)`. Alpha is passed through untouched.
- **Knobs:** `amount` (0–1, default 1) — overall strength. `radius` (0–1.5, default 0.75) — where the
  falloff starts. `softness` (0.01–1, default 0.45) — width of the fade. `color` (colorWell, default
  black) — the edge tint; only `.rgb` is used. Scalars read live via `ctx.inputFloat`; `color` via
  `ctx.inputFloats("color")` packed into a `SIMD4<Float>`.
- **Gotchas:** the input texture must be connected — if `ctx.inputTexture("input")` is nil the kernel
  is skipped. Because uv is normalized to the frame, the vignette is elliptical on non-square outputs.
