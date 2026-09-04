# Browser Camera — `camera.web`

The browser's camera as a texture output (`texture`), for web projects. The source node a
camera-effect chain starts from; `camera.macos` is its Mac counterpart.

- **Reuse:** `copy-as-is`. Pure browser API, no imports.
- **Permission:** declares `camera`. The app asks this Mac once; the page's own request is then
  granted without a second prompt. Until the stream delivers a frame the node draws nothing; a
  refused or missing camera is reported on the node.
- **Implementation:** `getUserMedia` into a `<video>`, a `VideoTexture`, one `ctx.shaderPass` that
  crops or letterboxes and mirrors. `teardown()` stops the tracks so a hot reload releases the camera.
- **Live inputs:** `mirror` (horizontal flip, default on) and `aspectFit` (true = fill/crop, the default
  look; false = fit/letterbox), read every frame. No device picker yet: the browser's default camera.
- **Exported page:** works from an https or localhost origin. Chrome refuses the camera on a
  `file://` page; Safari asks.
