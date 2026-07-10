# Brightness — `brightness`

Multiplies the input texture's RGB by a gain. The simplest tone node — a good `copy-as-is` starting
point for any single-pixel color op (contrast, gamma, saturation all follow the same compute template).

- **Reuse:** `copy-as-is`. Pure GPU, no device, no permissions.
- **Implementation:** compute kernel, one thread per pixel. `inTex.read(gid)` → `rgb * amount` →
  `outTex.write`. Alpha is passed through untouched. Pipeline built once in `setup()`.
- **Knobs:** `amount` (0–2, default 1) — read live via `ctx.inputFloat("amount") ?? 1.0`; tune with
  `ui_set_input_default`. Values >1 will clip on an 8-bit target; that's expected.
- **Gotchas:** the input texture must be connected — if `ctx.inputTexture("input")` is nil the kernel
  is skipped and the output stays as the pool left it. Wire a source (e.g. `camera.macos`) upstream.
