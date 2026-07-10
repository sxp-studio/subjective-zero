# Node Library

**Packages: SZRuntime (the nodes) · SZApp host (agent access via the MCP server).** A curated set of
pre-implemented, tested nodes that coding agents use as a **reference** - to learn from, and to
copy *only* when a node would work as-is. The goals: accelerate effect development, give agents a
solid base (so the runtime can stay lean and general), and let agents stay **correct** without
blowing their context window.

The library is also **where capabilities live**: because the runtime is primitives-only
([RUNTIME.md](RUNTIME.md#scope-primitives-only--capabilities-live-in-nodes)), domain features (camera,
image/file sources, common effects) are *library nodes*, not runtime features. The agent's **default
move** is to find a built-in node with a strong reference implementation and adapt it, rather than
write from scratch.

Library nodes are **reference points, not runtime dependencies**: when reused, their source is
**copied into the new node's folder and edited there**. We never link a generated node against a
library node.

## Static and fast by design

The library is a set of **plain files on disk** - no database, no indexer, no embeddings. Search is
just reading the assembled index (each node's `node-contract.json` merged with its `index.json`
curation) and reasoning over it. At this scale (tens of curated nodes) that's not a
limitation but an advantage: the whole catalog fits cheaply in an agent's context, so it does
full-information semantic matching with no retrieval-recall loss, and the library ships and versions
like source, not like a service. This is a **scale-appropriate choice, not a ban** - an indexer or
embeddings become worth their cost only once the catalog outgrows what fits cheaply in context (see
[How discovery scales](#how-discovery-scales) below). We just don't pay for that machinery before then.

## The 3-tier "earn the tokens" model

Discovery is staged so an agent spends tokens in proportion to its confidence. Optimized for
correctness: the cheap tier carries enough signal to pick the right node **or decide none fits**.

```
Tier 1: index.json   - load the WHOLE catalog cheaply, reason over it
Tier 2: card         - read the short card for the 1–2 finalists
Tier 3: Node.swift   - fetch full source for the ONE chosen node, only if copying/closely adapting
```

Accessed through MCP ([MCP.md](MCP.md)): `agent_library_index` → `agent_library_card` →
`agent_library_source`.

### How discovery scales

Fetch (Tier 3) is O(1) - only the one chosen node is pulled, whatever the catalog size. The cost that
grows is **discovery** ("which of N is the right reference?"), paid by every coding agent. The MCP seam
lets discovery climb without changing the agent contract or the on-disk format:

1. **Reason over `index.json`** (today) - the whole catalog fits cheaply in context; the agent does
   full-information semantic matching. Best while the library is small (tens of nodes).
2. **Narrow before reasoning** - once the index no longer fits cheaply in every agent's context, add a
   host-side `agent_library_search {q|tags|io}` returning a shortlist. Start lexical/tag/port-shape
   (still plain files); reach for an **embedding / vector index only if lexical recall proves too weak**
   at that scale - that's the point where an indexer earns its keep. Same seam either way.
3. **Lift discovery to the Director / a librarian agent** - search once per graph and hand each coding
   agent a pre-selected `ref` (amortizes across the fan-out); an LLM-judge reranks the shortlist when
   fit needs real judgment. Multi-agent reasoning belongs *here*, over a pre-narrowed set - never agents
   scanning the full catalog first-pass.

Rungs 2–3 are unbuilt: earned when the catalog actually outgrows rung 1, not before. Embeddings aren't
rejected - they're simply not worth their cost until the catalog stops fitting cheaply in context.

### Tier 1 - the assembled index (cheap, loaded whole)

One compact record per node. For 30–50 nodes this is a few thousand tokens - an agent loads the
entire catalog once and reasons over it. The **I/O contract** + **use-when/avoid-when** are the
highest-signal fields for matching.

Each record is **assembled** by `agent_library_index`, not stored whole:

- **Identity + I/O + permissions are DERIVED from the node's `node-contract.json`** (`title`, `sfSymbol`,
  `summary`, `io`, `permissions`) - the contract is the single source of truth, so `io` can never drift
  from what the node actually declares.
- **Discovery metadata is curated in `index.json`** (`tags`, `purpose`, `useWhen`, `avoidWhen`, `reuse`,
  `platform`) - the fields that can't be derived from the contract.

So `index.json` holds **only curation**, one entry per node keyed by folder `id`:

```json
{
  "nodes": [
    {
      "id": "camera.macos",
      "tags": ["source", "camera", "video", "macos"],
      "purpose": "Provides the built-in/selected Mac camera feed as an MTLTexture.",
      "platform": "macos",
      "useWhen": "You need live camera input as a texture source.",
      "avoidWhen": "You need a still image or a non-camera video source.",
      "reuse": "copy-as-is"
    }
  ]
}
```

…and the agent receives the merged record (curation above + contract-derived identity/io):

```json
{
  "id": "camera.macos",
  "title": "MacBook Camera",
  "sfSymbol": "camera",
  "summary": "Live Mac camera feed as a texture (built-in or selected camera).",
  "io": {
    "inputs": [
      { "name": "mirror",    "type": "bool" },
      { "name": "aspectFit", "type": "bool" },
      { "name": "camera",    "type": "enum" }
    ],
    "outputs": [ { "name": "texture", "type": "texture" } ]
  },
  "permissions": ["camera"],
  "tags": ["source", "camera", "video", "macos"],
  "purpose": "Provides the built-in/selected Mac camera feed as an MTLTexture.",
  "platform": "macos",
  "useWhen": "You need live camera input as a texture source.",
  "avoidWhen": "You need a still image or a non-camera video source.",
  "reuse": "copy-as-is"
}
```

### Tier 2 - card (per node, read for finalists only)

A short summary the agent reads to confirm or reject a candidate **without** the full source:
the docstring, key implementation notes, gotchas, and any setup/permission caveats. Stored
alongside the node (e.g. `library/<id>/CARD.md`).

### Tier 3 - `Node.swift` (full source, one node)

The complete implementation, fetched only for the single chosen reference and only when the agent
intends to copy or closely adapt it.

## The `reuse` flag (reference vs copy)

Each curated node declares a `reuse` mode:

- **`copy-as-is`** - the node works unchanged for its stated purpose; an agent may copy its source
  into the new node verbatim (then adjust the contract metadata as needed).
- **`reference-only`** - the node illustrates an approach but should **not** be copied blindly;
  the agent writes original source informed by it.

This makes the "use as a reference, don't blindly copy it" rule **structural** rather than
a prompt suggestion. The coding-agent tree honors it explicitly
([AGENT_ORCHESTRATION.md](AGENT_ORCHESTRATION.md): `choose_reference` returns `mode`).

## Showing results

The library is only trustworthy if its nodes demonstrably render. Each library node:

- compiles against the host ABI and runs in the runtime like any other node,
- has at least one **known-good preview** (e.g. the camera node renders the live feed),
- is exercisable through the same closed-loop `ui_*`/`debug_*` path as generated nodes, so we can
  assert it still works as the runtime evolves ([MCP.md](MCP.md)).

Treat a library node that can't show a result as broken - it defeats the point.

## Seed entry: macOS camera node

The first library node (and a core-loop dependency):

- **id:** `camera.macos`, **title:** "MacBook Camera", **SF Symbol:** `camera`
- **inputs:** `mirror` (bool), `aspectFit` (bool), `camera` (enum - device selection)
- **output:** `texture` (`MTLTexture`) stored in the runtime asset manager
- **permissions:** camera (requested/held by the runtime, [RUNTIME.md](RUNTIME.md))
- **reuse:** `copy-as-is`

With this plus a generated grayscale node, the canonical demo
("Make the MacBook camera grayscale") runs end to end.

## Adding a library node

A library node is a self-contained folder under `NodeLibrary/<id>/`, plus one curation entry in
`index.json`. Copy an existing node (e.g. `camera.macos`, or an `audio-*` node) and adapt it.

A node folder has three files:

- **`node-contract.json`** - the node's typed interface: `title`, `sfSymbol`, `summary`, `inputs`,
  `outputs`, `permissions`. **This is the source of truth for I/O and identity.**
- **`Node.swift`** - the implementation. Every port it reads/writes via `ctx.input*` / `ctx.output*` /
  `ctx.setOutput*` must use a `name` declared in the contract. (Copying a clean library node keeps you on
  the right side of this; the same rule is enforced automatically for *generated* nodes - see
  [the port-name check](#the-port-name-check).)
- **`CARD.md`** - prose reuse guidance + gotchas (Tier 2), short by design.

Then add **one curation entry** to `NodeLibrary/index.json`, keyed by folder `id`, carrying only the
fields that aren't in the contract: `tags`, `purpose`, `useWhen`, `avoidWhen`, `reuse`, `platform`.

> **Derive, don't duplicate.** `title`, `sfSymbol`, `summary`, `io`, and `permissions` are read from
> `node-contract.json` and merged into the served record automatically. **Never restate them in
> `index.json` or `CARD.md`** - a hand-copied `io` is exactly how the old `camera.macos` index drifted to
> claim a phantom `resolution` input the contract never had. (Legacy `io`/`title` keys in an `index.json`
> entry are tolerated but ignored.)

#### The port-name check

When a *generated* node is compiled, `agent_compile_node` cross-checks the contract against `Node.swift`
(`SZPortBindingAudit`): a port the code reads/writes that the contract doesn't declare is a **hard error**
(the source isn't promoted); a port declared in the contract that the code never touches is a **warning**
(usually a dead control). Hand-added library nodes don't pass through this tool, so keep the contract and
`Node.swift` in agreement yourself - copying a clean node is the easiest way.

## Authoring guidelines

- Keep each node **single-purpose** so `useWhen`/`avoidWhen` stay crisp and matching stays
  correct.
- Keep cards short - they exist to save a source fetch, not to duplicate the source.
- Keep `index.json` to **curation only**; the node's I/O and identity are derived from its contract, so
  never hand-copy them into the index (see [Derive, don't duplicate](#adding-a-library-node)).

## Test scenarios

- An agent loads the index, picks `camera.macos` as `copy-as-is`, and the camera renders.
- An agent given a task with no good match returns `none` and writes original source.
- A `reference-only` node is not copied verbatim by the coding-agent flow.
- Every library node renders its known-good preview through the closed-loop harness.
