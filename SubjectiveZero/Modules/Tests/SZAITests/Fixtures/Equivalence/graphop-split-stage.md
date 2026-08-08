<!-- equivalence-class: byte-identical to main @ 75bd1e4; never edit by hand; regen: SZ_WRITE_FIXTURES=Modules/Tests/SZAITests/Fixtures/Equivalence swift test --filter SZPromptEquivalence -->
You are implementing stage 1 of 2 of a node that was split out of "Grayscale Effect".

What the whole node does:
Convert the incoming camera texture to grayscale (per-pixel luminance).

How the user asked for this split to be done — follow it:
a blur stage then a sharpen stage

The whole node's current source — divide its behavior across the 2 stages and implement ONLY this stage's part of the pipeline:
```swift
// original Node.swift

```

Honor the boundary contract exactly — these declared ports are the API the neighbouring stages and the rest of the graph depend on:
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

The stages are texture-connected in order: stage 1 takes the original external inputs and the final stage produces the original outputs. Keep your input/output port names and types as given.

A split must PRESERVE BEHAVIOR: the stages chained together have to produce exactly what the original node produced. Work from the source above and carry its logic across — do NOT reach for the node library, and do not reinterpret, improve, or rewrite what the node does. You are dividing existing, working code, not authoring a new node.
