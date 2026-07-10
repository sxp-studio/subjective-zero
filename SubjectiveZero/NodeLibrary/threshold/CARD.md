# Threshold — `threshold`

Binarizes the image by Rec.601 luma into a white/black mask, with a `softness` band that feathers the
cutoff instead of a hard step. Handy as a matte or key source.

- **Reuse:** `copy-as-is`. Pure GPU, no device, no permissions.
- **Implementation:** compute kernel, one thread per pixel. `l = dot(c.rgb, float3(0.299,0.587,0.114))`
  then `smoothstep(threshold - softness, threshold + softness, l)` written to all three channels. Alpha
  is passed through untouched.
- **Knobs:** `threshold` (0–1, default 0.5) — the luma cutoff. `softness` (0–0.5, default 0.05) — width
  of the feathered edge; 0 approaches a hard binary. Both read live via `ctx.inputFloat`.
- **Gotchas:** the input texture must be connected — if `ctx.inputTexture("input")` is nil the kernel
  is skipped. Output is monochrome RGB; original color is discarded by design.
