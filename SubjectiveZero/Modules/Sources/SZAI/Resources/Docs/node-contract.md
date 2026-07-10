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
| `bool`      | `{"type":"bool","value":true}`                      | `toggle` | `ctx.inputFloat("name")` (`> 0.5`) |
| `enum`      | `{"type":"enum","value":"warm"}` + an `options` list | `dropdown` | `ctx.inputString("name")` (the chosen `value`) |
| `string`    | `{"type":"string","value":"hi"}`                    | `field`, or `filePicker` for a path | `ctx.inputString("name")` |
| `texture`   | — (no by-value default)                              | — | `ctx.inputTexture` / `ctx.outputTexture` (by id; input may be nil before a frame) |
| `floatArray`| — (no by-value default)                              | — | `ctx.inputFloatArray("name")` (connected; any length) — emit with `ctx.setOutputFloats("name", array)` |
| `event`     | — (no by-value default)                              | — | declared for the UI; **not delivered to the node yet** |

Notes: `min`/`max`/`step` (inside `ui`) only apply to `slider`/numeric kinds. `colorRGB/RGBA` are distinct
from `float3/4` purely by their color-well UI. **Never hardcode an input you declared** — read it live each
frame, or the user's control is a dead knob. Full runtime ABI: `agent_docs_read { "topic": "node-abi" }`.
