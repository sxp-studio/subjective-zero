# Saturation — `saturation`

Mixes each pixel between its Rec.601 luma and its full color by `amount`. Subsumes the classic
grayscale demo: set `amount = 0` for a pure desaturate.

- **Reuse:** `copy-as-is`. Pure GPU, no device, no permissions.
- **Implementation:** compute kernel, one thread per pixel. `l = dot(c.rgb, float3(0.299,0.587,0.114))`
  then `mix(float3(l), c.rgb, amount)`. Alpha is passed through untouched.
- **Knobs:** `amount` (0–2, default 1) — 0 = grayscale, 1 = unchanged, >1 oversaturates. Read live via
  `ctx.inputFloat("amount") ?? 1.0`.
- **Gotchas:** the input texture must be connected — if `ctx.inputTexture("input")` is nil the kernel
  is skipped. Oversaturation (>1) can clip on an 8-bit target; that's expected.
