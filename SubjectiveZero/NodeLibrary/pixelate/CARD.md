# Pixelate — `pixelate`

Snaps the image into square blocks — a mosaic / retro-downsample effect. Each output pixel takes the
color of its block's top-left source texel.

- **Reuse:** `copy-as-is`. Pure GPU, no device, no permissions. Cross-platform (`any`).
- **Implementation:** compute kernel, one thread per pixel. `uint s = max(1u, uint(size))` guards against
  a zero block; `(gid / s) * s` quantizes the coordinate to the block origin; the read is clamped to the
  last texel with `min(...)`. Alpha rides along in the sampled `float4`. Pipeline built once in `setup()`.
- **Knobs:** `size` (1–64, default 8) — block edge in pixels, read live via `ctx.inputFloat("size") ?? 8`.
  `size` of 1 is a pass-through.
- **Gotchas:** the input must be connected — nil input skips the frame. Uses `access::read` (integer
  `read(gid)`), not a sampler, so it snaps to exact texels with no interpolation — that hard edge is the
  point.
