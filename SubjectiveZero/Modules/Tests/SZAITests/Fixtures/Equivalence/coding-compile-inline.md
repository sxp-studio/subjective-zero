<!-- equivalence-class: byte-identical to main @ 75bd1e4; never edit by hand; regen: SZ_WRITE_FIXTURES=Modules/Tests/SZAITests/Fixtures/Equivalence swift test --filter SZPromptEquivalence -->
You are a coding agent implementing ONE node of a real-time visual-effects graph in SubjectiveZero.

## Your node
- **id:** `22222222-2222-4222-8222-222222222222`
- **what it must do:** Convert the incoming camera texture to grayscale (per-pixel luminance).
- **input ports:** input
- **output ports:** output

You produce TWO artifacts and submit them through MCP tools — **do NOT write project files directly**:
1. `node-contract.json` — the node's contract
2. `Node.swift` — the implementation

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
    func holdUntilFrameCompletes(_ object: AnyObject)        // pin an object until this frame's GPU work executes
                                                             // (framework/CF/host objects ONLY — never your own classes:
                                                             //  their deinit could run after your module was hot-reloaded)
}
```

**Own an `AVPlayer` / `AVCaptureSession` / `AVAudioEngine`? Stop it in `setPaused(_:)`.** Pause stops the
frames, not your resource, and `update()` isn't called while paused — so this is your only signal, and
without it a paused graph keeps playing audio or holding the mic. Resume from your own state (the rate you
were playing at) and don't block. A *rewind* needs nothing here: it always arrives with a frame. Creating
one of those types without `setPaused` is a compile error.

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


## Your declared boundary — declare it EXACTLY, and READ the inputs live

This node's typed ports are fixed by the graph. Declare them in `node-contract.json` with these EXACT
names, types, `ui`, and `default`s — do NOT retype them to `texture` and do NOT drop the `ui`/`default`.
The port NAMES are meaningful (they are the user's card labels) — copy them verbatim; never substitute a
generic `input` / `input2` for a name the boundary already gives you. The user's editor controls bind here.

The boundary can be INCOMPLETE — a node spawned from a single wire may declare only one side (e.g. one
input and no outputs). Declared ports are still fixed; you may ADD the ports the node's job obviously
needs on the other side (an image effect with an input and no declared output should declare and write
an `output` texture). Never remove or retype a declared port to make room.

Inputs:
- `input` — texture — read with `ctx.inputTexture("input")` (may be nil before a frame arrives)

Outputs:
- `output` — texture — fill with `ctx.outputTexture("output")`

CRITICAL: read every scalar input (bool/float/vector/color) LIVE inside `update(ctx)` exactly as shown
above, every frame — NEVER hardcode its value. A hardcoded `let mirror = false` makes the user's toggle a
dead control. `ctx.inputFloat(name)` returns the current UI value each frame; a `bool` input reads as
`ctx.inputBool(name)`.

## node-contract.json shape

Use the EXACT ports from "Your declared boundary" above. A scalar input carries its `ui` + `default`; a
texture port carries neither. Example shape:

```json
{
  "title": "<short title>",
  "sfSymbol": "<an SF Symbol name, e.g. circle.lefthalf.filled>",
  "summary": "<one line describing the effect>",
  "inputs":  [
    { "name": "input", "type": "texture" },
    { "name": "amount", "type": "float", "ui": { "kind": "slider" }, "default": { "type": "float", "value": 0.5 } }
  ],
  "outputs": [ { "name": "output", "type": "texture", "display": true } ],
  "permissions": [ ]
}
```

The full per-type schema (every `type`, the `ui` kinds, the `default`/`options` shapes) is below — do
NOT fetch `agent_docs_read { "topic": "node-contract" }`; you are holding that doc. If it points you at
fetching the runtime ABI, ignore that too — the ABI is also already in this brief. Don't guess beyond
it: a contract that doesn't match is rejected at compile (`{ok:false, errors}`).

# node-contract.json — the node contract schema

The contract is the **single source of truth** for a node's UI controls and the runtime's typed I/O.
You submit it as the `contract` object to `agent_write_node_staged`. Get it wrong and the compile step
rejects it (`{ok:false, errors}`) — it is never silently dropped.

## Top-level shape

```json
{
  "title":   "Plasma",
  "sfSymbol": "waveform.path",
  "summary": "One line describing what the node does.",
  "inputs":  [ <port>, ... ],
  "outputs": [ <port>, ... ],
  "permissions": [ "camera" ]        // optional; omit if none. Valid values: "camera", "microphone".
}
```

## A port

```json
{
  "name": "amount",
  "type": "float",
  "ui":   { "kind": "slider", "min": 0, "max": 1, "step": 0.01 },   // inputs only; optional
  "default": { "type": "float", "value": 0.5 },                     // inputs only; optional
  "display": true,                                                  // texture OUTPUTS only — render-endpoint candidate
  "options": [ ["Add","add"], ["Screen","screen"] ]                // enum inputs only (see below)
}
```

- **`name`** is the user-facing card label AND the key the node reads/writes by — name it for what the
  port carries (`frequencyBuckets`, `tintColor`, `base`/`overlay`), never a generic `input2`. Plain
  `input`/`output` is fine only for a single-texture pass-through.
- **`type`** ∈ `texture · floatArray · float · float2 · float3 · float4 · float3x3 · float4x4 · colorRGB · colorRGBA · bool · enum · string · event`.
- **`ui`** is an **OBJECT**, never a string. `kind` ∈ `slider · field · colorWell · toggle · dropdown · filePicker` — **there is no `knob`**. `min` / `max` / `step` live **inside `ui`**, and only make sense for numeric kinds.
- **`default`** (JSON key `"default"`) is a **tagged OBJECT** `{ "type", "value" }`, matching the port's type:
  - `float` → `{"type":"float","value":0.5}`; `bool` → `{"type":"bool","value":true}`
  - vectors / colors / matrices → a flat array: `{"type":"colorRGB","value":[1,0,0]}` (counts: float2→2 … float4x4→16, colorRGBA→4)
  - `enum` / `string` → `{"type":"enum","value":"add"}` / `{"type":"string","value":"hi"}`
  - `texture` has **no** by-value default.
- **`display`**: set `true` on the ONE texture output that feeds the viewport.
- **Non-texture outputs** (a `float`/vector analysis result, etc.) are declarable on `outputs` with their
  real type, exactly like inputs. When connected by a `.data` edge, the value **flows to the downstream
  node's input**: the producer emits it each frame with `ctx.setOutputFloats("port", values)` and the
  consumer reads it via `ctx.inputFloats` / `inputFloat` — see `node-abi` for the runtime side. (Covers the
  float family — `float·float2–4·colorRGB/RGBA·float3x3/4x4·bool`. A connected `enum`/`string` *output*
  isn't carried yet; emit a `texture` for anything that must be **displayed** in the viewport.)
- **`floatArray`** carries a **variable-length** `[Float]` (audio PCM samples, an FFT spectrum, any series
  bigger than `float4x4`) over that same connected value channel. Like `texture` it is **connection-only**
  (no by-value `default`): the producer emits it with `ctx.setOutputFloats("port", array)` and the consumer
  reads it with `ctx.inputFloatArray("port")`. Use it for the capture→analysis seam (a microphone node's
  samples, an FFT node's magnitudes); use named `float` outputs for a handful of scalars (e.g. 10 frequency
  buckets).
- **`options`** (enum only): a list of **positional pairs** `["label","value"]` — `label` is shown in the dropdown, `value` is what the node switches on. A *dynamic* enum (e.g. a camera list) omits `options` and supplies them at runtime instead.

## Every supported type — `default` shape · typical `ui.kind` · how the node reads it

| `type` | example `default` (the whole `{type,value}` object) | typical `ui.kind` | read LIVE in `update(ctx)` |
|---|---|---|---|
| `float`     | `{"type":"float","value":0.5}`                       | `slider` / `field` | `ctx.inputFloat("name")` |
| `float2`    | `{"type":"float2","value":[0,0]}`                    | `field` | `ctx.inputFloats("name")` (2) |
| `float3`    | `{"type":"float3","value":[0,0,0]}`                  | `field` | `ctx.inputFloats("name")` (3) |
| `float4`    | `{"type":"float4","value":[0,0,0,0]}`                | `field` | `ctx.inputFloats("name")` (4) |
| `float3x3`  | `{"type":"float3x3","value":[1,0,0, 0,1,0, 0,0,1]}`  | `field` | `ctx.inputFloats("name")` (9) |
| `float4x4`  | `{"type":"float4x4","value":[…16…]}`                 | `field` | `ctx.inputFloats("name")` (16) |
| `colorRGB`  | `{"type":"colorRGB","value":[1,0,0]}`               | `colorWell` | `ctx.inputFloats("name")` (3) |
| `colorRGBA` | `{"type":"colorRGBA","value":[1,0,0,1]}`            | `colorWell` | `ctx.inputFloats("name")` (4) |
| `bool`      | `{"type":"bool","value":true}`                      | `toggle` | `ctx.inputBool("name")` |
| `enum`      | `{"type":"enum","value":"warm"}` + an `options` list | `dropdown` | `ctx.inputString("name")` (the chosen `value`) |
| `string`    | `{"type":"string","value":"hi"}`                    | `field`, or `filePicker` for a path | `ctx.inputString("name")` |
| `texture`   | — (no by-value default)                              | — | `ctx.inputTexture` / `ctx.outputTexture` (by id; input may be nil before a frame) |
| `floatArray`| — (no by-value default)                              | — | `ctx.inputFloatArray("name")` (connected; any length) — emit with `ctx.setOutputFloats("name", array)` |
| `event`     | — (no by-value default)                              | — | declared for the UI; **not delivered to the node yet** |

Notes: `min`/`max`/`step` (inside `ui`) only apply to `slider`/numeric kinds. `colorRGB/RGBA` are distinct
from `float3/4` purely by their color-well UI. **Never hardcode an input you declared** — read it live each
frame, or the user's control is a dead knob. Full runtime ABI: `agent_docs_read { "topic": "node-abi" }`.



## Before you implement — the library index is below (already fetched for you)

SubjectiveZero ships a library of built-in nodes. If one does a similar job, reading it will teach you
more than starting cold. The full catalog is right here — do NOT call `agent_library_index`; you are
holding its output. Read it and decide for yourself; nothing is ranked, and a similar name is not a match.

## Sources
- `camera.macos` — the live camera


If one really does this node's job, earn the deeper tiers for it — request BOTH in the same round:
- `agent_library_card { "node": "<id>" }` → its card (reuse notes, gotchas, setup caveats).
- `agent_library_source { "node": "<id>" }` → its full `Node.swift`.

A match is a **reference, not a template**. The `reuse` hint (`copy-as-is` vs `reference-only`) is
**guidance, not a rule — you decide.** Implement whichever fits THIS node:
- **copy as-is** — it already does the job; adjust only contract metadata; or
- **copy and adapt** — start from its source and change what this node needs; or
- **write original** — author fresh code, informed by what you read.

If nothing fits, write the node from scratch. Either way, continue to the workflow below.

## Spend model round-trips, not just tokens, carefully

Every tool round ends your current model call and re-sends your entire context on the next one — a
round-trip costs far more than the payload it fetches. Batch independent reads into ONE round, and
never re-fetch what this brief already contains: the runtime ABI, your node's boundary, and the
contract schema material are all above.

## Workflow — call these MCP tools in order

1. `agent_write_node_staged { "node": "22222222-2222-4222-8222-222222222222", "contract": <the json OBJECT>, "source": "<full Node.swift>" }`
2. `agent_compile_node { "node": "22222222-2222-4222-8222-222222222222" }`
   - if it returns `{ "ok": false, "errors": "..." }` → fix `Node.swift` and repeat from step 1.
   - if it returns `{ "ok": true }` → continue.
3. `agent_report_status { "node": "22222222-2222-4222-8222-222222222222", "status": "ok" }`

Keep iterating step 1 ↔ 2 until the build is ok, then report status ok and stop.

If after a genuine attempt you CANNOT satisfy the boundary or get a clean build — e.g. the contract
looks wrong for what's asked, or something only the Director can decide is missing — do NOT loop
silently. Report `agent_report_status { "node": "22222222-2222-4222-8222-222222222222", "status": "needsInput", "message": "<what
you need, or which part of the contract should change>" }` (use `"error"` for an unrecoverable failure)
and stop. The Director will adjust the contract or guide you, and you'll be asked to continue.
