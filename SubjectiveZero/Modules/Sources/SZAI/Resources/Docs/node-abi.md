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
    // func setPaused(_ paused: Bool) { }   // optional; stop anything running on its own
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
```

## The injected types

```swift
protocol SZNode {
    func setup(_ ctx: SZSetupContext)   // default no-op; build pipelines here
    func update(_ ctx: SZFrameContext)  // per-frame GPU work
    func teardown()                     // default no-op
    func setPaused(_ paused: Bool)      // default no-op; see below
}
struct SZSetupContext { let device: any MTLDevice }
struct SZFrameContext {
    let device: any MTLDevice
    let commandBuffer: any MTLCommandBuffer
    let width: Int; let height: Int; let frameIndex: UInt64; let time: Double
    func inputTexture(_ port: String) -> (any MTLTexture)?   // declared texture input (may be nil before a frame)
    func outputTexture(_ port: String) -> (any MTLTexture)?  // declared texture output you must fill
    func inputFloat(_ port: String) -> Float?                // float input (e.g. a slider)
    func inputBool(_ port: String) -> Bool?                  // bool input (the card's toggle)
    func inputFloats(_ port: String) -> [Float]?             // float2/3/4, colorRGB/RGBA, float3x3/4x4
    func inputString(_ port: String) -> String?              // enum (chosen value) / string input
    func inputFloatArray(_ port: String) -> [Float]?         // connected `floatArray` input — any length (audio samples / spectrum)
    func setOutputFloat(_ port: String, _ value: Float)      // emit a single-float NON-texture output
    func setOutputFloats(_ port: String, _ values: [Float])  // emit a float/vector NON-texture output
    func setOutputString(_ port: String, _ string: String)   // emit an enum/string output
    func holdUntilFrameCompletes(_ object: AnyObject)        // pin an object until this frame's GPU work executes
                                                             // (framework/CF/host objects ONLY — never your own classes:
                                                             //  their deinit could run after your module was hot-reloaded)
    func reportError(_ message: String)                      // say why you are producing nothing (see below)
}
```

**Own an `AVPlayer` / `AVCaptureSession` / `AVAudioEngine`? Stop it in `setPaused(_:)`.** Pause stops the
frames, not your resource, and `update()` isn't called while paused — so this is your only signal, and
without it a paused graph keeps playing audio or holding the mic. Resume from your own state (the rate you
were playing at) and don't block. A *rewind* needs nothing here: it always arrives with a frame. Creating
one of those types without `setPaused` is a compile error.

## Saying why you produced nothing

A node that cannot do its job renders black, and black looks exactly like "no file chosen yet", like
"still loading", and like "working as asked". `ctx.reportError("…")` breaks that tie: the host shows the
message on the node and hands it to whoever reads the graph. Use it for the fault **only your code can
see** — a file that opened and would not decode, a shader that would not compile, a model this Mac cannot
run. Not for a missing or unreadable file: the host checks that from outside and would say it twice.

**It describes the frame it is called on, so call it on every frame the fault holds.** The first frame you
stay quiet, the message is gone. That is what clears a fixed node with nothing to remember, and why there
is no `clearError`.

So do not report from inside your reload gate: that gate runs on one frame, and the message would flash
for a sixtieth of a second and vanish. Discover the fault in the gate, then report it outside:

```swift
private var loadError: String?          // discovered once in the gate, re-reported every frame

func update(_ ctx: SZFrameContext) {
    let path = ctx.inputString("path") ?? ""
    if path != loadedPath {             // the usual gate: you only attempt the load when the path moves
        loadedPath = path
        loadError = nil                 // a new path is a clean slate
        do { try load(path) } catch { loadError = "could not decode \(path): \(error.localizedDescription)" }
    }
    if let loadError { ctx.reportError(loadError) }   // outside the gate, so it is said every frame
}
```

One message per node (the last call of a frame wins), so say it in one sentence and name the file.
Reporting every frame costs nothing: the host notices only when the message changes. Truncated past 512
bytes. `image-file` and `video-file` in the library both do exactly this.

## Rules

- **Textures are BGRA8, at the graph's render size.** The host allocates every node texture as `bgra8Unorm`
  at the project's render resolution — you cannot choose the output pixel format or size; a source of
  another size is fitted, letterboxed or cropped inside it by your own sampling. Build any pipeline ONCE in
  `setup()`; do per-frame work in `update()`, encoding onto `ctx.commandBuffer` (the host commits it).
- **Read every declared scalar/string input LIVE inside `update(ctx)` every frame** — never hardcode it,
  or the user's editor control becomes a dead knob.
- A node is **self-contained**: capabilities (camera, microphone, etc.) live in the node's own code (e.g.
  AVFoundation — `AVCaptureSession` for camera, `AVAudioEngine` for mic), not the runtime. A `camera` or
  `microphone` permission is declared in the contract and pre-granted before `setup()` runs.
- **Emit a NON-texture output with `ctx.setOutputFloats("port", values)`** (or `setOutputFloat` for one
  value), every frame, for any `float`/vector/color/matrix/`bool` output you declared. When that output is
  connected by a `.data` edge, the runtime delivers it to the downstream node's input — read it there with
  `inputFloats` / `inputFloat`, exactly like any other scalar input. A texture output still uses
  `outputTexture`; use a `texture` output for anything that must be **displayed**.
- **Emit an `enum`/`string` output with `ctx.setOutputString("port", value)`** — it flows across a `.data`
  edge into a downstream input of the same type (read there with `inputString`; the connect guard requires
  equal types: string→string, enum→enum). The host can read it too (a controller node's learn key).
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
        // Before any guard that can return: a pipeline that never built renders nothing forever, and a
        // report placed below an early return is a report that never happens.
        if pipeline == nil { ctx.reportError("contrast pipeline failed to build") }

        // Read EVERY declared input live, every frame — a hardcoded value is a dead knob in the editor.
        let amount = ctx.inputFloat("amount") ?? 1.0          // float
        let bypass = ctx.inputBool("bypass") ?? false         // bool
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
