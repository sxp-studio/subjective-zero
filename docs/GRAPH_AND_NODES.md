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
│  │  ├─ Node.swift
│  │  └─ Card.swift          // optional: the node's custom card (see below)
│  └─ n2/
│     ├─ node-contract.json
│     └─ Node.swift
├─ transcripts/            // chat transcript sidecars, one per scope (director.json / <node-id>.json) - see STATE.md
├─ attachments/            // durable chat-attachment copies (<attachment-id>/<filename>)
└─ .staging/               // staged agent/build writes, promoted on success (see STATE.md)
```

`project.json` references nodes by id and owns the connection list. Each node folder owns its
contract + source (+ an optional `Card.swift`). This "per-node `Node.swift` + `node-contract.json`"
shape keeps each node a self-contained, inspectable unit on disk.

## Node kinds

- **Prompt node (pre-gen):** an intent in natural language. Usually no typed ports yet (a
  wire-spawned node carries its one seeded port); shows its prompt and a pending state. This is
  what the user draws first.
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

- **`card`** (optional) declares the node's custom card: `{ "cols"?, "rows"?, "backdrop"?, "plumbing"? }`
  - a minimum width in grid columns, the region's default height in rows, the texture output the
  host draws live under the card, and the inputs the card owns (their generated rows step aside
  while the card shows). Hints only - the card itself is `Card.swift`, below.

## Controller nodes and derived bindings

A **binding source** is any node whose contract declares a string `mappings` input and a string
`lastKey` output (`SZNodeContract.isBindingSource`) — the shipped ones are `midi.macos` (USB MIDI CC)
and `osc-input` (OSC over wifi). Its `mappings` default is a JSON array of rows
`{"key", "port", "min", "max", "label"}`: `key` is the controller's own wire identity (MIDI
`"ch1/cc7"`, OSC `"/1/fader1"`), opaque to the host; each row is a float output named `port` on the
node INSTANCE's contract, emitting the control pre-scaled `min…max`. Node code is table-generic, so a
binding is pure graph state — `SZStore.commitDerivedBinding` / `removeDerivedBinding` update the
table default + the instance output + (optionally) a data edge in ONE transaction and deliberately do
not raise a rebuild. **Learn** reads the node's `lastEvent` (`[seq, value01]`) + `lastKey` outputs
(ABI v8 string channel) at ~30 Hz (`SZBindingLearnController`), elects the control the user moved
(`SZBindingLearnModel`: the control already moving at arm time is excluded until it settles), and
commits through `SZHost.commitBinding` — reached by the `binding_*` MCP tools and by the controller
card's `learn_arm` / `learn_commit` / `remove_binding` verbs.

## Custom card (`Card.swift`)

A generated node MAY ship a **custom card**: a small SwiftUI view, compiled at runtime exactly like
`Node.swift`, mounted as a **region** of the node card between the header and the generated port
rows - where the live preview would sit. Everything else stays system-generated from the contract:
header, input rows (control + socket), output rows (monitor toggle + socket). A card is for
interactions the rows can't express - dragging corner handles over the output (the built-in
`corner-pin` projection-mapping node), an XY pad, a curve - never for restyling a slider.

- **Model:** the node's `body` is `none | preview | custom` (graph state, persisted like `position`);
  `custom` is only accepted when `Card.swift` exists on disk. Right-click → **Show Custom Card /
  Hide Custom Card** flips it; `ui_set_node_body` is the same edit from MCP. The file stays either way.
- **Data flow:** the card reads a scoped snapshot of its node (contract, current input values,
  connected inputs, render size) and, for nodes with float/floatArray outputs, a lossy ~30 Hz
  telemetry stream. It writes through two verbs only - `live` (per-gesture-tick, unpersisted) and
  `commit` (on release, persisted) - which land on the same input-default path a slider drag uses.
  Cards never see the graph, other nodes, or Metal.
- **Who writes it:** the user (right-click → **New Custom Card…** scaffolds a starter and opens it;
  saving hot-reloads, a red edit keeps the last good build mounted with a warning chip) or an agent
  (`agent_write_node_staged { card }`, compile-checked with the node; the first promoted card turns
  the body on). Agents are told cards are **off by default** - a Director-level call, made only when
  the user asks for custom UI or the interaction has no row equivalent. The authoring contract is
  the `card-abi` agent doc; the runtime side is in [RUNTIME.md](RUNTIME.md#custom-cards).

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

- **Flow** - drawing intent. Expresses "this leads to that" while the user drafts before contracts
  exist; it orders nothing at runtime and schedules nothing - the scheduler orders execution by
  **data** edges only (see [AGENT_ORCHESTRATION.md](AGENT_ORCHESTRATION.md)).
  - *Consumed as the pre-contract topology signal:* the procedural strategy drafts a contract-less
    drawn node's texture I/O from its flow edges (`SZGraph.draftContractsFromFlow`, contract-first
    authorship), and the LLM Director Agent reads flow as its who-feeds-whom signal on a
    not-yet-contracted graph. Laying the data edge along a flow arrow realizes and clears it.
- **Data** - a typed value flowing from a specific output port to a specific input port of a
  compatible type. This is what the runtime actually reads at execution time.

A data connection is only valid between **type-compatible** ports. The graph is a **strict DAG**;
frame feedback is expressed with the explicit **feedback node**, never a cycle
([RUNTIME.md](RUNTIME.md)).

Dropping a fresh data wire on empty canvas spawns a prompt node whose contract is pre-seeded with
one port of the dragged port's type (named `input`/`output` per the draft convention), so the data
edge lands typed and legal; the edge stays runtime-inert until the node is implemented (the
renderable subgraph only includes edges between generated nodes). Drafting never rewrites an
existing contract, but it does realize flow arrows into an already-contracted prompt node's unwired
texture inputs - and any arrow it can't realize (cycle, or no compatible texture port) is left as
visible intent and narrated, never silently dropped.

## Lifecycle

1. User adds a **prompt node** (flow-connected to neighbors).
2. Director Agent assigns a **coding agent**, which drafts `node-contract.json` (→ `ui_update_node`, UI
   reflows) and `Node.swift` (staged).
3. Runtime compiles + hot-reloads; node becomes **generated** and starts executing. The promote
   records a **build stamp** (the port surface + prompt the compile consumed); a built node reads
   *needs rebuild* only by derivation from it - `contractChanged` (surface off the stamp),
   `intentChanged` (prompt off the stamp) - or from the port audit (`sourceMismatch`: `Node.swift`
   names a port the contract doesn't declare, or owns a live AV resource with no `setPaused`; never
   `ui`/defaults/formatting). Nothing is latched: the next promote re-stamps and re-audits.
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
