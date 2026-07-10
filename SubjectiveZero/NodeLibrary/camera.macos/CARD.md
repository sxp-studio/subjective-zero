# MacBook Camera — `camera.macos`

Live Mac camera feed as an `MTLTexture` output (`texture`). The canonical **source** node and the
core-loop dependency for the grayscale-camera demo.

- **Reuse:** `copy-as-is` — copy this folder's `Node.swift` + `node-contract.json` into the new node's
  folder and adapt as needed (defaults, format, metadata). Don't re-derive the AVFoundation boilerplate.
- **Permission:** declares `camera`. The runtime pre-grants it on load; the node guards on
  `AVCaptureDevice.authorizationStatus` and outputs **black** until authorized, so it's safe headless
  (no prompt / no crash without a usage description).
- **Implementation:** self-contained AVFoundation — `AVCaptureSession` → `CVPixelBuffer` →
  `CVMetalTextureCache` (built from the context's device) → blit into the output texture. The runtime
  never touches the camera; only this node does.
- **Hot-reload safe:** `teardown()` stops the session, clears the sample delegate, and drains the
  capture queue **before** the module unloads.
- **GPU-lifetime pinning (the load-bearing subtlety):** each sampled frame's `CVMetalTexture` +
  pixel buffer are pinned via `ctx.holdUntilFrameCompletes(…)` — the runtime releases them after the
  frame's GPU work executes; releasing at encode time would let the pool recycle the IOSurface under
  the GPU (torn/flickering feed). Any adaptation sampling pooled buffers must pin the same way.
- **Live inputs (v3/v4 ABI):** honors `mirror` (horizontal flip), `aspectFit` (true = fill/crop, the
  default look; false = fit/letterbox), and `camera` (dynamic device enum, live-switched) — all read every
  frame. There is no `resolution` input.
