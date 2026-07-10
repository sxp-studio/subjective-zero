# Node runtime ABI — what `Node.swift` may use

Your `Node.swift` is compiled together with a host-owned support file that already defines the ABI. Do
**NOT** import or redeclare `SZNode`, `SZSetupContext`, `SZFrameContext`, `SZRuntimeContextRaw`, or any
`@_cdecl` / `@main` symbols — they are host-injected and will collide.

## The shape your file must define

```swift
@preconcurrency import Metal

final class Node: SZNode {
    func setup(_ ctx: SZSetupContext) { /* build pipeline(s) ONCE here */ }
    func update(_ ctx: SZFrameContext) { /* per-frame GPU work; read inputs, write outputs */ }
    // func teardown() { }   // optional; default no-op
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
```

## The injected types

```swift
protocol SZNode {
    func setup(_ ctx: SZSetupContext)   // default no-op; build pipelines here
    func update(_ ctx: SZFrameContext)  // per-frame GPU work
    func teardown()                     // default no-op
}
struct SZSetupContext { let device: any MTLDevice }
struct SZFrameContext {
    let device: any MTLDevice
    let commandBuffer: any MTLCommandBuffer
    let width: Int; let height: Int; let frameIndex: UInt64; let time: Double
    func inputTexture(_ port: String) -> (any MTLTexture)?   // declared texture input (may be nil before a frame)
    func outputTexture(_ port: String) -> (any MTLTexture)?  // declared texture output you must fill
    func inputFloat(_ port: String) -> Float?                // float/bool input (bool: > 0.5)
    func inputFloats(_ port: String) -> [Float]?             // float2/3/4, colorRGB/RGBA, float3x3/4x4
    func inputString(_ port: String) -> String?              // enum (chosen value) / string input
    func inputFloatArray(_ port: String) -> [Float]?         // connected `floatArray` input — any length (audio samples / spectrum)
    func setOutputFloat(_ port: String, _ value: Float)      // emit a single-float NON-texture output
    func setOutputFloats(_ port: String, _ values: [Float])  // emit a float/vector NON-texture output
    func holdUntilFrameCompletes(_ object: AnyObject)        // pin an object until this frame's GPU work executes
                                                             // (framework/CF/host objects ONLY — never your own classes:
                                                             //  their deinit could run after your module was hot-reloaded)
}
```

## Rules

- **Textures are BGRA8.** The host allocates every node texture as `bgra8Unorm` — you cannot choose the
  output pixel format. Build any pipeline ONCE in `setup()`; do per-frame work in `update()`, encoding onto
  `ctx.commandBuffer` (the host commits it).
- **Read every declared scalar/string input LIVE inside `update(ctx)` every frame** — never hardcode it,
  or the user's editor control becomes a dead knob.
- A node is **self-contained**: capabilities (camera, microphone, etc.) live in the node's own code (e.g.
  AVFoundation — `AVCaptureSession` for camera, `AVAudioEngine` for mic), not the runtime. A `camera` or
  `microphone` permission is declared in the contract and pre-granted before `setup()` runs.
- **Emit a NON-texture output with `ctx.setOutputFloats("port", values)`** (or `setOutputFloat` for one
  value), every frame, for any `float`/vector/color/matrix/`bool` output you declared. When that output is
  connected by a `.data` edge, the runtime delivers it to the downstream node's input — read it there with
  `inputFloats` / `inputFloat`, exactly like any other scalar input. A texture output still uses
  `outputTexture`; use a `texture` output for anything that must be **displayed**. (A connected
  `enum`/`string` *output* isn't carried yet — emit those as a `texture` if they must flow downstream.)
- **A `floatArray` output/input carries a variable-length `[Float]`** (audio PCM samples, an FFT spectrum,
  any numeric series too big for `float4x4`) over that same connected value channel. Emit it with
  `ctx.setOutputFloats("port", array)`; read it downstream with `ctx.inputFloatArray("port")`, which grows
  to any length (`inputFloats` stays capped at 16, for scalars/vectors). Like `texture`, it is
  **connection-only** — no editor default, so always wire it.

## A worked example — the spectrum

One node exercising most of the ABI. Not a template to copy: a map of what is available. Its contract
declares a texture input, four editor-controlled inputs of different types, a displayed texture output
AND a non-texture `float` output.

```json
{
  "title": "Contrast", "sfSymbol": "circle.righthalf.filled",
  "summary": "Scales contrast about a pivot; also reports the frame's average luma.",
  "inputs": [
    { "name": "input",  "type": "texture" },
    { "name": "amount", "type": "float", "default": { "type": "float", "value": 1.0 },
      "ui": { "kind": "slider", "min": 0.0, "max": 4.0, "step": 0.05 } },
    { "name": "bypass", "type": "bool",  "default": { "type": "bool", "value": false },
      "ui": { "kind": "toggle" } },
    { "name": "mode",   "type": "enum",  "default": { "type": "enum", "value": "rgb" },
      "ui": { "kind": "dropdown" }, "options": [["RGB", "rgb"], ["Luma", "luma"]] },
    { "name": "pivot",  "type": "colorRGB", "default": { "type": "colorRGB", "value": [0.5, 0.5, 0.5] },
      "ui": { "kind": "colorWell" } }
  ],
  "outputs": [
    { "name": "output", "type": "texture", "display": true },
    { "name": "luma",   "type": "float" }
  ]
}
```

A **source** node simply declares `"inputs": []` — nothing else changes. `display: true` marks the ONE
texture output that feeds the viewport; a node with a single texture output should set it.

```swift
@preconcurrency import Metal

final class Node: SZNode {
    private var pipeline: (any MTLComputePipelineState)?

    func setup(_ ctx: SZSetupContext) {
        // Build pipelines ONCE. (Omitted: library/function creation from an inline shader source.)
    }

    func update(_ ctx: SZFrameContext) {
        // Read EVERY declared input live, every frame — a hardcoded value is a dead knob in the editor.
        let amount = ctx.inputFloat("amount") ?? 1.0          // float; bool reads the same way (> 0.5)
        let bypass = (ctx.inputFloat("bypass") ?? 0) > 0.5    // bool
        let mode   = ctx.inputString("mode") ?? "rgb"         // enum -> the chosen value
        let pivot  = ctx.inputFloats("pivot") ?? [0.5, 0.5, 0.5]   // colorRGB / vectors / matrices

        guard let out = ctx.outputTexture("output") else { return }   // the texture you must fill
        let src = ctx.inputTexture("input")   // nil until an upstream frame lands — skip, don't crash
        guard let src, !bypass else { return }

        _ = (amount, mode, pivot, src, out)   // ... encode the pass onto ctx.commandBuffer ...

        // A NON-texture output is emitted every frame; a `.data` edge carries it to a downstream input.
        ctx.setOutputFloat("luma", 0.5)
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
```

## Threading

`update()` runs once per frame on a **render thread** — never block in it (no device I/O, session/engine
reconfiguration, file access, or `.sync` hops; do slow work on your own queue and hand results over with a
lock-guarded latest-value buffer). Anything a pool can recycle while the GPU still reads it (e.g. the
`CVMetalTexture` + `CVPixelBuffer` behind a camera frame) must be pinned with
`ctx.holdUntilFrameCompletes(…)`. `camera.macos` in the library shows both patterns.

The contract that declares these ports has its own schema — see
`agent_docs_read { "topic": "node-contract" }`.
