# Blend — `blend`

Composites **two texture inputs** (`base` + `blend`) with a selectable Photoshop-style mode, mixed
back over the base by `opacity`. The workhorse two-input compositor — `copy-as-is` for any layer mix.

- **Reuse:** `copy-as-is`. Pure GPU, no device, no permissions. Cross-platform (`any`).
- **Implementation:** compute kernel, one thread per pixel. Reads `baseTex`/`blendTex`, computes the
  per-mode blend (add / multiply / screen / overlay / soft light / hard light / difference — hard
  light is overlay with base/blend swapped), then `outRGB = mix(base.rgb, blended, opacity)` and
  writes `float4(outRGB, base.a)`. Base alpha is preserved. Pipeline built once in `setup()`.
- **Inputs:** `base` (texture) and `blend` (texture) — **both must be connected**; if either is nil
  the kernel is skipped and the output stays as the pool left it. `mode` (enum, string channel →
  Int32) and `opacity` (0–1, default 1) read live.
- **Gotchas:** both inputs are sampled by integer `gid`, so they should share the output's
  dimensions (wire same-size sources). Blend results can exceed 1 (add/screen) and clip on an 8-bit
  target — expected. Bounds guarded against `outTex.get_width()/height()`.
