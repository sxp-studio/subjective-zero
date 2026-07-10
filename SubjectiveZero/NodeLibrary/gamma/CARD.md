# Gamma — `gamma`

Applies a `1/gamma` power curve to each channel — the standard nonlinear midtone control. Same
single-pixel compute template as brightness/contrast.

- **Reuse:** `copy-as-is`. Pure GPU, no device, no permissions.
- **Implementation:** compute kernel, one thread per pixel. `pow(max(c.rgb, 0.0), float3(1.0 / max(gamma, 1e-3)))`.
  The `max` guards clamp negative input and a zero exponent. Alpha is passed through untouched.
- **Knobs:** `gamma` (0.1–3, default 1) — >1 lifts midtones (brighter), <1 crushes them. Read live via
  `ctx.inputFloat("gamma") ?? 1.0`.
- **Gotchas:** the input texture must be connected — if `ctx.inputTexture("input")` is nil the kernel
  is skipped. Curve is applied in the texture's own numeric space (no linear/sRGB conversion).
