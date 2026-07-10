# Video File — `video-file`

Plays a local video file as a **live texture source**, scaled to the viewport. The moving-image
counterpart to `image-file`; a permission-free alternative to `camera.macos` for driving effect chains.

- **Reuse:** `reference-only`. It owns a stateful AV pipeline — adapt it, don't copy blindly. No
  permissions (not sandboxed → absolute `path` read directly).
- **Implementation:** adapts the `camera.macos` CV→Metal path. An `AVPlayer` drives an
  `AVPlayerItemVideoOutput`; each `update()` polls `copyPixelBuffer(forItemTime:)` (host-time mapped via
  `CACurrentMediaTime()`), wraps the newest `CVPixelBuffer` through a `CVMetalTextureCache`, and samples
  it into the output with the `fit` uv transform. The player is rebuilt only when `path` changes.
- **Knobs:** `path` (filePicker), `loop` (bool, re-seeks to zero on end via an
  `AVPlayerItemDidPlayToEndTime` observer), `rate` (0 pauses, 1 = normal, up to 4×), `fit`
  (fit/fill/stretch — default `fill`, the natural full-frame video look). All read live.
- **Gotchas:** outputs black until the first frame decodes and while `path` is empty/invalid.
  `holdUntilFrameCompletes` pins the pixel buffer + Metal binding for the frame's GPU lifetime (torn
  frames otherwise — same hazard as the camera node). `teardown()` pauses the player and removes the
  end observer before the dylib unloads. The last decoded frame is held between decodes, so a slow
  render loop won't strobe.
