# Contrast — `contrast`

Pushes each channel away from (or toward) a `pivot` grey. The classic second tone node after
brightness — same single-pixel compute template.

- **Reuse:** `copy-as-is`. Pure GPU, no device, no permissions.
- **Implementation:** compute kernel, one thread per pixel. `rgb = (c.rgb - pivot) * amount + pivot`.
  Alpha is passed through untouched. Pipeline built once in `setup()`.
- **Knobs:** `amount` (0–2, default 1) — 0 collapses to flat grey at `pivot`, >1 boosts. `pivot`
  (0–1, default 0.5) — the value that stays fixed. Both read live via `ctx.inputFloat`.
- **Gotchas:** the input texture must be connected — if `ctx.inputTexture("input")` is nil the kernel
  is skipped. High `amount` clips on an 8-bit target; that's expected.
