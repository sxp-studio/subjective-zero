<!-- brief pin; never edit by hand; re-record deliberately: SZ_RECORD_BRIEF_PINS=1 swift test --filter SZBriefPinTests -->
You are a coding agent implementing ONE node of a real-time visual-effects graph in SubjectiveZero.

## Your node
- **id:** `22222222-2222-4222-8222-222222222222`
- **title / symbol:** `Grayscale Effect` / `sparkles`
- **what it must do:** Convert the incoming camera texture to grayscale (per-pixel luminance).
- **input ports:** input, strength, mirror, mode, label, tint, samples, trigger
- **output ports:** output, level, active, histogram, note

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

The port lines above omit `ui` ranges on purpose: the promote MERGES your contract into the live one by port
name — a port that is already live keeps its live `ui` and current `default` (the user's value), ports you add
are appended, ports you omit are kept — so give every scalar you add a sensible `ui`/`default` and never spend
a turn matching a range you were not shown; you cannot overwrite the user's.

CRITICAL: read every scalar input (bool/float/vector/color) LIVE inside `update(ctx)` exactly as shown
above, every frame — NEVER hardcode its value. A hardcoded `let mirror = false` makes the user's toggle a
dead control. `ctx.inputFloat(name)` returns the current UI value each frame; a `bool` input reads as
`ctx.inputBool(name)`.

## node-contract.json shape

Use the EXACT ports from "Your declared boundary" above. A scalar input carries its `ui` + `default`; a
texture port carries neither.

One rule for the card's identity, applied to `title` and `sfSymbol` INDEPENDENTLY: copy the value shown
under "Your node" above — unless that value is the placeholder a drawn node starts with (title `New Node`,
symbol `sparkles`), and then choose a real one (a short title / a fitting SF Symbol). A placeholder you
replace sticks; a name someone chose is kept by the promote regardless, so a different value there is a
no-op at best. Expect to be filling in one of the two: a node commonly arrives with a real title and the
placeholder symbol. A deliberate rename is an explicit act — `ui_update_node { "node": "22222222-2222-4222-8222-222222222222", "title":
"...", "sfSymbol": "..." }` — never a side effect of a rebuild.

Example shape:

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

For the full per-type schema (every `type`, the `ui` kinds, the `default`/`options` shapes) fetch
`agent_docs_read { "topic": "node-contract" }`. Don't guess the schema: a contract that doesn't match
is rejected at compile (`{ok:false, errors}`).


## Before you implement — look for a reference

SubjectiveZero ships a library of built-in nodes. If one does a similar job, reading it will teach you
more than starting cold. Spend tokens in tiers, cheapest first:

1. `agent_library_index` → the catalog by category: what each node does, its typed I/O, its reuse mode.
   Read it and decide for yourself; nothing is ranked, and a similar name is not a match. Read it at
   most ONCE — it does not change during your turn.
2. If one really does this node's job, earn the deeper tiers for it:
   - `agent_library_card { "node": "<id>" }` → its card (reuse notes, gotchas, setup caveats).
   - `agent_library_source { "node": "<id>" }` → its full `Node.swift`.
   Card and source are one decision, not two: when the index already makes the node the likely
   reference, request BOTH in the same round instead of spending a round deciding to spend a round.
3. A match is a **reference, not a template**. The `reuse` hint (`copy-as-is` vs `reference-only`) is
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

## Custom cards — off by default

A node MAY ship a `Card.swift`: a small SwiftUI view mounted between the node's header and its
generated port rows. **Do not ship one unless the node's prompt (or your instruction) asks for a
custom card / custom UI, or the interaction has no row equivalent** — dragging handles or a pad over
the output, a curve, a meter over an array the node emits. Sliders, dropdowns, colors, toggles come
free from the contract's rows; a card that rebuilds them is noise the user has to hide. If (and only
if) one is called for: read `agent_docs_read { "topic": "card-abi" }` first, study the built-in
reference (`agent_library_source { "node": "corner-pin", "file": "Card.swift" }`), list the inputs the
card takes over under the contract's `card.plumbing`, and pass the file as `card` in step 1 — a red
card blocks the promote and comes back through `agent_compile_node`'s errors like a node build would.
If the node already has a `Card.swift` (it is shown after the source above), keep it: re-stage it as
`card` whenever your contract change touches a port it reads.

## Workflow — call these MCP tools in order

1. `agent_write_node_staged { "node": "22222222-2222-4222-8222-222222222222", "contract": <the json OBJECT>, "source": "<full Node.swift>" }`
   — the node first, without a card. Only staged files compile and promote: never draft node source
   with a general file-writing tool.
2. `agent_compile_node { "node": "22222222-2222-4222-8222-222222222222" }`
   - if it returns `{ "ok": false, "errors": "..." }` → fix `Node.swift` and repeat from step 1.
   - if it returns `{ "ok": true }` → continue.
3. If the prompt asks for a custom card, stage it now in a second `agent_write_node_staged` call (same
   contract and source, plus `"card": "<full Card.swift>"`, see Custom cards) and compile again.
4. `agent_report_status { "node": "22222222-2222-4222-8222-222222222222", "status": "ok" }`

Repeat steps 1 and 2 until the build is ok, then step 3 if a card is asked for, then report and stop.
Your turn has a budget of minutes: stage and compile early, and if it runs short, stub what is left
so the node compiles and name the stubs in your report.

If after a genuine attempt you CANNOT satisfy the boundary or get a clean build — e.g. the contract
looks wrong for what's asked, or something only the Director can decide is missing — do NOT loop
silently. Report `agent_report_status { "node": "22222222-2222-4222-8222-222222222222", "status": "needsInput", "message": "<what
you need, or which part of the contract should change>" }` (use `"error"` for an unrecoverable failure)
and stop. The Director will adjust the contract or guide you, and you'll be asked to continue.
