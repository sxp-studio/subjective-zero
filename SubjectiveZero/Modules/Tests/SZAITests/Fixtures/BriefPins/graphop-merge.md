<!-- brief pin; never edit by hand; re-record deliberately: SZ_RECORD_BRIEF_PINS=1 swift test --filter SZBriefPinTests -->
You are implementing a single node that merges 2 previously separate nodes into one. Combine their behavior into one coherent node — chain the constituents' logic in pipeline order so the merged node produces the same result the chain did.

How the user asked for this merge to be done — follow it:
merge favouring performance

Honor the boundary contract exactly — these declared ports are the API the rest of the graph depends on:
Inputs:
- `input` — texture — read with `ctx.inputTexture("input")` (may be nil before a frame arrives)
- `strength` — float (slider, default 0.5) — read LIVE each frame with `ctx.inputFloat("strength")`
- `mirror` — bool (toggle, default false) — read LIVE each frame with `ctx.inputBool("mirror")`
- `mode` — enum (dropdown, default "luma") — read LIVE each frame with `ctx.inputString("mode")` (an enum delivers the selected option's value; nil until one is set)
- `label` — string (field, default "mono") — read LIVE each frame with `ctx.inputString("label")` (an enum delivers the selected option's value; nil until one is set)
- `tint` — colorRGB (colorWell) — read LIVE each frame with `ctx.inputFloats("tint")`
- `samples` — floatArray — a connected variable-length `[Float]` (e.g. audio samples or an FFT spectrum); read LIVE each frame with `ctx.inputFloatArray("samples")` (nil until the upstream emits)
- `trigger` — event — declared for the UI; NOT delivered to the node at runtime yet, so declare it but don't depend on its value

Outputs:
- `output` — texture, display — fill with `ctx.outputTexture("output")`
- `level` — float — emit LIVE each frame with `ctx.setOutputFloat("level", value)`
- `active` — bool — emit LIVE each frame with `ctx.setOutputFloats("active", values)`
- `histogram` — floatArray — emit a variable-length `[Float]` each frame with `ctx.setOutputFloats("histogram", values)`; the connected downstream reads it with `ctx.inputFloatArray`
- `note` — string — declared for the UI; not emitted to a downstream node at runtime

Declared permissions (host-granted before your `setup()` runs — keep them in the contract): camera, microphone.

The nodes being merged (in pipeline order), with their current source:
- MacBook Camera: Live Mac camera feed delivered as a texture output — the canonical macOS camera source node.
```swift
// camera source

```

- Grayscale Effect: Convert the incoming camera texture to grayscale (per-pixel luminance).
_(no source yet — this node was not implemented)_

A merge must PRESERVE BEHAVIOR: the merged node has to produce exactly what the chain produced. Work from the sources above and carry their logic across — do NOT reach for the node library, and do not reinterpret, improve, or rewrite what the nodes do. You are fusing existing, working code, not authoring a new node.
