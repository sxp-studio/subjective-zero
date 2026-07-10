# Graph & Nodes

**Packages: SZCore (model) · SZRuntime (execution) · SZUI (editor).** This defines what a node
*is* on disk, the typed I/O contract and its UI, the two kinds of connections, and how split/
merge act on the graph.

## On-disk layout

State is portable JSON; node source is isolated per node so it's independently inspectable and
hot-reloadable.

```
MyProject.subz/
├─ project.json            // App/Project/Graph: nodes (by id), connections, viewport - see STATE.md
├─ nodes/
│  ├─ n1/
│  │  ├─ node-contract.json
│  │  └─ Node.swift
│  └─ n2/
│     ├─ node-contract.json
│     └─ Node.swift
├─ transcripts/            // chat transcript sidecars, one per scope (director.json / <node-id>.json) - see STATE.md
├─ attachments/            // durable chat-attachment copies (<attachment-id>/<filename>)
└─ .staging/               // staged agent/build writes, promoted on success (see STATE.md)
```

`project.json` references nodes by id and owns the connection list. Each node folder owns its
contract + source. This "per-node `Node.swift` + `node-contract.json`" shape keeps each node a
self-contained, inspectable unit on disk.

## Node kinds

- **Prompt node (pre-gen):** an intent in natural language. No typed ports yet; shows its prompt
  and a pending state. This is what the user draws first.
- **Generated node (post-gen):** has a real contract (typed I/O), a title, and an SF Symbol.
  Produced by a coding agent. Its UI is a pure function of its contract.

A prompt node becomes a generated node when a coding agent writes its contract + source; the
node id is stable across that transition.

## Node contract (`node-contract.json`)

The contract is the single source of truth for a node's UI and for the runtime's I/O
enforcement. Illustrative shape:

```json
{
  "title": "Make Grayscale",
  "sfSymbol": "circle.lefthalf.filled",
  "summary": "Converts an input texture to luminance grayscale.",
  "inputs": [
    { "name": "input",  "type": "texture" },
    { "name": "amount", "type": "float", "ui": { "kind": "slider", "min": 0, "max": 1, "step": 0.01 }, "default": { "type": "float", "value": 1.0 } }
  ],
  "outputs": [
    { "name": "output", "type": "texture", "display": true }
  ]
}
```

- `title` + `sfSymbol` drive the node header in the editor.
- `inputs`/`outputs` declare typed ports; the runtime enforces that the node reads/writes only
  these ([RUNTIME.md](RUNTIME.md)).
- `display: true` on a texture output marks it as the current render endpoint candidate.
- **`ui`** is an object `{ "kind", "min"?, "max"?, "step"? }` - `kind` ∈ `slider · field · colorWell · toggle · dropdown · filePicker`. **`default`** is a *tagged* object `{ "type", "value" }` matching the port's type (e.g. `{"type":"float","value":1.0}`, `{"type":"colorRGB","value":[1,0,0]}`, `{"type":"enum","value":"warm"}`) - never a bare value. An `enum` also carries `options` as positional pairs `[["Label","value"], …]`. The complete per-type table (every `default`/`ui`/runtime read) is the canonical `node-contract` agent doc (`agent_docs_read`), kept in sync with `SZContract.swift`.

## I/O types and their UI

When an input is **unconnected** and its type has a compatible control, the editor shows that
control with a default value and sends edits to the node's runtime value.

| Type | UI when unconnected |
|---|---|
| `float` | text field, or slider (`min`, `max`, `step`) |
| `float2` / `float3` / `float4` | one text field per component |
| `float3x3` / `float4x4` | matrix of text fields (no default control beyond fields) |
| `colorRGB` / `colorRGBA` | color well (picker); convertible to/from `float3`/`float4` |
| `texture` (`MTLTexture`) | no inline control (must be connected, or sourced by a node) |
| `bool` | toggle |
| `enum` (string options, e.g. `["a","b"]`) | dropdown |
| `string` | text field, **or file picker** when the node marks it as a path |
| `event` | no control; fires only when an upstream node triggers it |

Outputs use the same type set. **Texture outputs** additionally show a **display** icon: toggle
it to push that texture to the viewport. By default agents set `display` on the node most likely
to be the final output, but the user can toggle any texture output to preview it instead.

> **Why these types.** Colors (`colorRGB/RGBA`) stay distinct from `float3/4` because of their
> color-well UI and alpha-default conversion. A file path is just a `string` carrying a
> **file-picker** UI hint - there is no separate `file` type, which means one fewer runtime type
> and no lost capability. Numeric widening/narrowing and color↔float conversions are supported.

## Connections: flow vs data

Two distinct edge types - they are *not* always the same, and conflating them is a mistake
worth avoiding:

- **Flow** - intent / scheduling. Expresses "this leads to that" and orders work; used when the
  user is drafting before contracts exist, and to express scheduling intent.
  - *Consumed since M7c as the pre-contract topology signal:* the procedural strategy drafts a
    contract-less drawn node's texture I/O from its flow edges (`SZGraph.draftContractsFromFlow`,
    contract-first authorship), and the LLM Director Agent reads flow as its who-feeds-whom signal
    on a not-yet-contracted graph. The *scheduler* still orders execution by **data** edges only
    (see [AGENT_ORCHESTRATION.md](AGENT_ORCHESTRATION.md)).
- **Data** - a typed value flowing from a specific output port to a specific input port of a
  compatible type. This is what the runtime actually reads at execution time.

A data connection is only valid between **type-compatible** ports. The graph is a **strict DAG**;
frame feedback is expressed with the explicit **feedback node**, never a cycle
([RUNTIME.md](RUNTIME.md)).

## Lifecycle

1. User adds a **prompt node** (flow-connected to neighbors).
2. Director Agent assigns a **coding agent**, which drafts `node-contract.json` (→ `ui_update_node`, UI
   reflows) and `Node.swift` (staged).
3. Runtime compiles + hot-reloads; node becomes **generated** and starts executing.
4. User iterates: edit defaults, draw data connections, chat with the node's agent, or split/merge.

## Split / merge as graph transactions

Both are **host-owned, atomic transactions** ([STATE.md](STATE.md)); V1 is user-initiated.

- **Split** one node → a pipeline. The host adds the new nodes, drafts their contracts, and
  **rewires** connections: external inputs feed the first piece, the last piece feeds external
  outputs, and the pieces are data-connected in between. Affected pieces are then implemented by
  coding agents.
  - *Example:* "Make the MacBook camera grayscale" → **MacBook Camera** (`output: texture`) →
    **Make Grayscale** (`input: texture` → `output: texture`).
- **Merge** adjacent nodes → one node. The host removes the constituents, creates the merged
  node, and rewires external connections to it; a coding agent implements the merged node.

**Contract reconciliation:** after a split/merge, the host computes the new boundary contracts
(what the pieces must expose so external connections stay valid) and hands those to the coding
agents as the API contract to implement against. External type-compatibility is preserved by
construction so the rest of the graph keeps working.

## Test scenarios

- A prompt node with no contract renders as pending; adding a contract reflows it to typed ports.
- An unconnected `float` input shows a slider and feeds its default into `update()`.
- Splitting a single grayscale-camera node yields two type-compatible, data-connected nodes whose
  external wiring matches the original; one undo restores the original.
- Toggling `display` on a different texture output redirects the viewport without rebuilding.
