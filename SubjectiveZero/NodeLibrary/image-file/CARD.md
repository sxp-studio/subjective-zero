# Image File — `image-file`

Loads a still image from a local path as a **texture source**, scaled to the viewport. A camera-free,
permission-free way to feed a fixed image into an effect chain.

- **Reuse:** `copy-as-is`. No permissions — the app is not sandboxed, so an absolute `path` from the
  `filePicker` input is read directly (no security-scoped bookmark).
- **Implementation:** `MTKTextureLoader` loads the file **once** and caches it; it only reloads when
  `path` changes (never per-frame). A full-screen render pass samples the loaded texture through a
  `uvScale` computed CPU-side from the image vs. output aspect ratios. Loaded with `.origin: .topLeft`
  + `.SRGB: false` to match the top-left uv convention and the `bgra8Unorm` output.
- **Knobs:** `path` (filePicker) and `fit` — `fit` (letterbox, whole image visible), `fill` (cover,
  crop overflow), `stretch` (ignore aspect). Both read live.
- **Gotchas:** an empty or unreadable `path` clears the output to black (no crash). `fit` letterbox
  bars are transparent-black via the sampler's `clamp_to_zero` addressing. Formats are whatever
  `MTKTextureLoader` supports (png/jpg/heic/tiff/…). For a moving image use `video-file`.
