<!-- brief pin; never edit by hand; re-record deliberately: SZ_RECORD_BRIEF_PINS=1 swift test --filter SZBriefPinTests -->
You are a coding agent implementing ONE node of a real-time visual-effects graph in SubjectiveZero.

## Your node
- **id:** `22222222-2222-4222-8222-222222222222`
- **title / symbol:** `Grayscale Effect` / `sparkles`
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
`subz_agent_docs_read { "topic": "node-contract" }`.


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
placeholder symbol. A deliberate rename is an explicit act — `subz_ui_update_node { "node": "22222222-2222-4222-8222-222222222222", "title":
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

The full per-type schema (every `type`, the `ui` kinds, the `default`/`options` shapes) is below — do
NOT fetch `subz_agent_docs_read { "topic": "node-contract" }`; you are holding that doc. If it points you at
fetching the runtime ABI, ignore that too — the ABI is also already in this brief. Don't guess beyond
it: a contract that doesn't match is rejected at compile (`{ok:false, errors}`).

# node-contract.json — the node contract schema

The contract is the **single source of truth** for a node's UI controls and the runtime's typed I/O.
You submit it as the `contract` object to `subz_agent_write_node_staged`. Get it wrong and the compile step
rejects it (`{ok:false, errors}`) — it is never silently dropped.

## Top-level shape

```json
{
  "title":   "Plasma",
  "sfSymbol": "waveform.path",
  "summary": "One line describing what the node does.",
  "inputs":  [ <port>, ... ],
  "outputs": [ <port>, ... ],
  "permissions": [ "camera" ],       // optional; omit if none. Valid values: "camera", "microphone", "screenRecording".
  "card": { "cols": 12, "rows": 8, "backdrop": "output" }   // optional; ONLY if the node ships a Card.swift
}
```

`card` (all fields optional) hints how the node's custom card mounts: `cols`/`rows` = its footprint in
grid cells (defaults 9 × 8), `backdrop` = a texture OUTPUT drawn live inside the card region (the region
then follows the render aspect), `plumbing` = inputs the card owns (their generated rows step aside while
the card shows). Omit the block entirely for a node without a `Card.swift`. See `subz_agent_docs_read { "topic": "card-abi" }`.

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
- **`ui`** is an **OBJECT**, never a string. `kind` ∈ `slider · field · colorWell · toggle · dropdown · filePicker` — **there is no `knob`**. `min` / `max` / `step` live **inside `ui`**, and only make sense for numeric kinds. `fileTypes` lives there too, for `filePicker` alone: the filename extensions the port accepts, lowercased, no dot — `"ui": {"kind":"filePicker","fileTypes":["mlpackage","mlmodelc"]}`. **Declare them whenever you know them.** They drive the chooser, they let a *package* (a folder macOS shows as one file, like `.mlpackage`) be picked at all, and they let the host tell the user "that is a `.mlmodel`, this port takes `.mlpackage`" instead of your node quietly rendering black. Leaving `fileTypes` out means any file.
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
  float family — `float·float2–4·colorRGB/RGBA·float3x3/4x4·bool`; an `enum`/`string` output is emitted
  with `ctx.setOutputString` and read downstream with `inputString`. Emit a `texture` for anything that
  must be **displayed** in the viewport.)
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
| `enum`      | `{"type":"enum","value":"warm"}` + an `options` list | `dropdown` | `ctx.inputString("name")` (the chosen `value`) — emit with `ctx.setOutputString` |
| `string`    | `{"type":"string","value":"hi"}`                    | `field`, or `filePicker` for a path | `ctx.inputString("name")` — emit with `ctx.setOutputString` |
| `texture`   | — (no by-value default)                              | — | `ctx.inputTexture` / `ctx.outputTexture` (by id; input may be nil before a frame) |
| `floatArray`| — (no by-value default)                              | — | `ctx.inputFloatArray("name")` (connected; any length) — emit with `ctx.setOutputFloats("name", array)` |
| `event`     | — (no by-value default)                              | — | declared for the UI; **not delivered to the node yet** |

Notes: `min`/`max`/`step` (inside `ui`) only apply to `slider`/numeric kinds. `colorRGB/RGBA` are distinct
from `float3/4` purely by their color-well UI. **Never hardcode an input you declared** — read it live each
frame, or the user's control is a dead knob. Full runtime ABI: `subz_agent_docs_read { "topic": "node-abi" }`.

**A `filePicker` port and the file it names.** The picked file is copied INTO the project, and the
contract stores a path relative to it (`media/<uuid>/IMG_2479.MOV`) so the project still works on
another machine. None of that changes your code: `ctx.inputString` hands you an **absolute** path,
every frame, exactly as before. Open it with `URL(fileURLWithPath:)` and never build a path yourself.
The default you write is a value, not a promise the file exists — if it cannot be read, the host says
so on the node, and `subz_agent_read_node` reports it as `inputFileErrors`. To check a path before you
rely on it, use `subz_agent_check_path`. That check is from outside, though: a file that is present,
readable and of the right kind can still be refused by the loader you hand it to, and only your code
sees that. Say so with `ctx.reportError` (see `subz_agent_docs_read { "topic": "node-abi" }`); it reaches
`subz_agent_read_node` as `nodeError`.

## What a promote keeps — the live contract merges with yours

`subz_agent_compile_node` never replaces the live contract with yours; it **merges per port, by name**. A port that
is already live keeps its live `type`, `ui` and current `default` (that default is the user's slider value);
ports you add are appended; ports you omit are kept (removing a port is `subz_ui_edit_ports`' job). So declare a
sensible `ui`/`default` for every scalar you add, and never worry about matching a range you were not shown —
you cannot overwrite the user's.

The same rule holds for `subz_ui_edit_ports`: re-declaring a port rewrites its declaration and keeps the value the
port already holds, so widening a slider or adding an option never resets the render. Only
`subz_ui_set_input_default` changes a value, and only a retype (or withdrawing an `enum` option that is in use)
drops one.

## What makes a built node "outdated" — the port audit and the build stamp

A built node reads **outdated / needs rebuild** for exactly one of three reasons — none of them authored state
you can edit. The two stamp comparisons are derived every read; the audit fault is a flag the host recomputes
from the live source at load, after every promote, after a hot reload and after a port edit.

- **`sourceMismatch`** — the port audit found a fault in `Node.swift`. Exactly two things raise it, and the
  `rebuildDetail` line says which: (a) the code reads or writes a port **name** the contract does not declare
  (`ctx.inputFloat("scale")` with no input `scale`; `ctx.setOutputFloat("level", …)` with no output `level`) —
  the audit compares the names your code passes to the `ctx` accessors against the names the contract declares,
  per direction, and looks at nothing else about them; (b) the node constructs a live AV resource (`AVPlayer`,
  `AVCaptureSession`, `AVAudioEngine`) without a `func setPaused(` to stop it, so a paused graph would keep
  playing. Nothing else is involved either way: `ui` ranges, `default` values, port order, `title`/`summary`,
  JSON formatting and byte-identical files can never cause or clear a mismatch. The same audit gates
  `subz_agent_compile_node`: while it errors nothing is promoted and the reply quotes the offending lines
  (`{ok:false, errors}`); a declared port the code never touches is only a warning. A clean promote clears the
  state — there is nothing to reset and no point re-emitting an unchanged file.
- **`contractChanged`** — the contract's port surface (direction · name · type of every port) differs from the
  one the last promote compiled against (the build stamp). Benign: the node keeps rendering and the new ports
  are inert until you implement them. Cleared by a promote (the stamp is rewritten from what the compile saw)
  or by the surface moving back.
- **`intentChanged`** — the node's `prompt` differs from the brief its build was written to. Benign; cleared by
  a promote against the current prompt.

The audit fault outranks the two stamp comparisons. `subz_agent_read_node` / `subz_agent_read_graph` report the reason as
`rebuildReason` and, when there is one, the audit's lines (or the surface diff) as `rebuildDetail` — read those
instead of theorizing about the files. A mismatch is fixed by whatever that detail names: reconcile the port
name (declare the port the code needs, or drop that read/write — whichever keeps the node's behavior), or add
the missing `setPaused`. Then re-stage and compile.



## Before you implement — the library index is below (already fetched for you)

SubjectiveZero ships a library of built-in nodes. If one does a similar job, reading it will teach you
more than starting cold. The full catalog is right here — do NOT call `subz_agent_library_index`; you are
holding its output. Read it and decide for yourself; nothing is ranked, and a similar name is not a match.

## Sources
- `camera.macos` — the live camera


If one really does this node's job, earn the deeper tiers for it — request BOTH in the same round:
- `subz_agent_library_card { "node": "<id>" }` → its card (reuse notes, gotchas, setup caveats).
- `subz_agent_library_source { "node": "<id>" }` → its full `Node.swift`.

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

## Custom cards — off by default

A node MAY ship a `Card.swift`: a small SwiftUI view mounted between the node's header and its
generated port rows. **Do not ship one unless the node's prompt (or your instruction) asks for a
custom card / custom UI, or the interaction has no row equivalent** — dragging handles or a pad over
the output, a curve, a meter over an array the node emits. Sliders, dropdowns, colors, toggles come
free from the contract's rows; a card that rebuilds them is noise the user has to hide. If (and only
if) one is called for: read `subz_agent_docs_read { "topic": "card-abi" }` first, study the built-in
reference (`subz_agent_library_source { "node": "corner-pin", "file": "Card.swift" }`), list the inputs the
card takes over under the contract's `card.plumbing`, and pass the file as `card` in step 1 — a red
card blocks the promote and comes back through `subz_agent_compile_node`'s errors like a node build would.
If the node already has a `Card.swift` (it is shown after the source above), keep it: re-stage it as
`card` whenever your contract change touches a port it reads.

## Workflow — call these MCP tools in order

1. `subz_agent_write_node_staged { "node": "22222222-2222-4222-8222-222222222222", "contract": <the json OBJECT>, "source": "<full Node.swift>" }`
   — the node first, without a card. Only staged files compile and promote: never draft node source
   with a general file-writing tool.
2. `subz_agent_compile_node { "node": "22222222-2222-4222-8222-222222222222" }`
   - if it returns `{ "ok": false, "errors": "..." }` → fix `Node.swift` and repeat from step 1.
   - if it returns `{ "ok": true }` → continue.
3. If the prompt asks for a custom card, stage it now in a second `subz_agent_write_node_staged` call (same
   contract and source, plus `"card": "<full Card.swift>"`, see Custom cards) and compile again.
4. `subz_agent_report_status { "node": "22222222-2222-4222-8222-222222222222", "status": "ok" }`

Keep iterating step 1 ↔ 2 until the build is ok, then report status ok and stop. Your turn has a
budget of minutes, not hours: stage and compile early, and if it runs short, stub what is left so the
node compiles, and name the stubs in your report.

If after a genuine attempt you CANNOT satisfy the boundary or get a clean build — e.g. the contract
looks wrong for what's asked, or something only the Director can decide is missing — do NOT loop
silently. Report `subz_agent_report_status { "node": "22222222-2222-4222-8222-222222222222", "status": "needsInput", "message": "<what
you need, or which part of the contract should change>" }` (use `"error"` for an unrecoverable failure)
and stop. The Director will adjust the contract or guide you, and you'll be asked to continue.
