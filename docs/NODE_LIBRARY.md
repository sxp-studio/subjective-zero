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
library node. A person places them the same way, from the **Library panel**
([UI.md](UI.md#library-panel)), with no agent and no provider configured; the copy keeps its
origin so the agents can tell copies apart ([GRAPH_AND_NODES.md](GRAPH_AND_NODES.md#copies-and-lineage)).

## Where library nodes come from

A library is a **folder of node folders** in the layout below. The app reads every library it knows
through one list of roots (`SZHost.libraryRoots`), so the panel, the agents' index and placement see
the same nodes.

- **Built in** - `NodeLibrary/` in this repo, bundled as a folder reference and read in place.
  Tested against the app it ships with; works offline on first launch.
- **My Library** - the user's own, created by the first **Save to Library…** under Application
  Support (movable from Settings ▸ Library). A save writes one node folder (contract with file
  inputs cleared, each source file the node has, `Card.swift` if any, `CARD.md` with the description
  and prompt) and one `index.json` entry, then commits; git is never required and never shown.
  Saving the same node again updates its entry, and the project's node is stamped as a copy of it.
- **Added libraries** - a folder on this Mac, or a copy downloaded from a link (`SZAddedLibrary`,
  remembered in the prefs). A folder is read where it lives and never written to. A link is fetched
  as an archive and unpacked under `Application Support/libraries/<key>/`, read-only. Both are added
  from Settings ▸ Library ▸ Add Library, or by an agent with `ui_add_library`. A library that is not
  there right now (an unplugged disk, a folder someone moved) is skipped, not forgotten, so it comes
  back when the folder does.

**The app never runs anybody's version control.** A link is somewhere to download a copy from, not a
repository the app maintains: no clone, no commit, no push, and a saved node is a file write and
nothing more. Whoever maintains a library does that in their own repository with their own tools.
This is deliberate, and it is why saving into a library that happens to live inside someone's own
repository cannot touch their work.

**Updating is always asked for.** The settings row's Check for Updates downloads a fresh copy and
says what would change, then moves nothing until told. `library.json`'s `version` is the signal when
both copies have a readable one; without that, the node folders are compared. A library never
changes under a project that is open, and nodes already on a canvas are copies, so an update never
rewrites anyone's graph.

**Trust.** Two different things, both worth naming.

The archive is checked before a single file is written: `SZArchiveListing.refusal` reads `tar -tv`
and refuses the whole download on anything that is not a plain file or folder, any path that climbs
out or starts at the root, a silly depth, and sizes or counts past the caps. The download itself is
https on every hop, capped, and assembled in a staging folder deleted on every path. All of that
runs before the person has agreed to anything, which is exactly why it must not be exploitable.

The nodes are a different matter: they are compiled and loaded into the app, so they run with
everything the app can reach, and no scan of ours would honestly change that. That part is identity
and consent, not inspection. The Add sheet says so once, in those words, at the moment the person
decides, and an agent is told to add only the library the user named.

Ids may repeat across libraries, so rows are keyed by library and id, and the agents' tools take an
optional `library` argument when two libraries carry the same id (built in wins when omitted).

**Groups, not categories.** Every surface groups nodes by their ports (`SZLibraryGroup.derived`):
Sources (a texture out, none in), Effects (texture in and out), Audio (sample arrays either way),
Control (anything else with outputs). Nothing is curated; `tags` are search terms.

## Making a library of your own

A library is **a folder with node folders in it**. Nothing else is required, and that is the whole
format:

```
their-nodes/
  library.json          the manifest: name, author, license, which app it was made with
  index.json            the discovery entries agents read first (one per node, optional but wanted)
  gaussian-blur/        one node folder, exactly as under NodeLibrary/
    node-contract.json
    Node.swift
    Node.js             optional, for browser projects
    Card.swift          optional, a custom card
    CARD.md             optional, what it does and the prompt that made it
  edge-detect/
```

The fastest way to start is to ask the Director for one: **"make me a library called Their Nodes,
MIT, by me"**, then **"save the blur into it"**. That runs `ui_create_library` and
`ui_save_to_library { library }`, which writes the manifest, the node folder and the index entry
correctly the first time. Doing it by hand is the same three files.

Put the folder in a repository on GitHub, GitLab or Codeberg and it is shareable as-is: **Add
Library** takes a link to it and downloads the current copy. Bump `version` in `library.json` when
you want people's Check for Updates to offer the new one.

### `library.json`

Only `name` is required. Everything else is what makes a library safe to hand to someone else, so
fill it in before you publish:

```json
{
  "name": "Their Nodes",
  "version": "1.2.0",
  "description": "Feedback and glitch effects for live visuals.",
  "author": "Their Name",
  "license": "MIT",
  "homepage": "https://github.com/someone/their-nodes",
  "madeWith": "0.4.0",
  "minAppVersion": "0.4.0",
  "abi": 9
}
```

| field | what it is for |
| --- | --- |
| `name` | What the library is called in the panel, the chips and Settings. **Required.** |
| `description` | One line on what the library is for. |
| `author` | Who made it. A person or a project, not an id. |
| `license` | An SPDX id (`MIT`, `AGPL-3.0-only`). A node is code somebody copies into their own project, so a library with no license says nothing about whether they may. |
| `homepage` | Where to read the source or file an issue. |
| `madeWith` | The SubjectiveZero this was written and last tested against. Advisory, and the first thing to read when a node misbehaves on a much later build. |
| `minAppVersion` | The earliest SubjectiveZero that can run these nodes. **The one field that is enforced**: an older app refuses the library outright, rather than failing every node one at a time. |
| `abi` | The node ABI you wrote against ([RUNTIME.md](RUNTIME.md)). Shown, never checked: the app has no ABI number of its own to compare with. |
| `version` | Which version this library is, as `MAJOR.MINOR.PATCH`. What Check for Updates compares, and the only thing that makes an update a decision rather than a diff. Bump it when you publish; saving a node never bumps it for you. |

Publishing a library with no `author` or `license` still works, and says so: whoever receives it
cannot tell who wrote it or whether they may use it.

### For agents

Three tools, in the order they are usually needed:

- `ui_create_library { name, author?, license?, description?, folder? }` - a new empty library,
  registered and visible in the panel immediately. Ask the user who to credit and under what
  license; never invent either.
- `ui_save_to_library { node, name?, description?, library? }` - put a built node in it. Without
  `library` the node goes to **My Library**, which is the right answer for almost every save.
- `ui_add_library { link | folder }` - add somebody else's. Its nodes are code that will run on this
  Mac, so add **only** the library the user named or linked.

Plus `agent_library_index` to find nodes and `ui_add_library_node` to place one, which is what an
agent reaches for far more often than any of the above.

**Updating a library is not an agent tool.** It is in Settings ▸ Library, because it is a deliberate
act with a consequence outside the project: it changes which nodes exist on this Mac. An agent asked
to update should point at that screen. There is no publishing from the app at all: a library is
published the way any repository is, by its author.

A library fetched from a link **cannot be saved into**: the next update would overwrite whatever was
written there. Save to My Library, or to a library the user created.

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
`agent_library_source`. Cold-start run briefs embed Tier 1 (and the contract-schema doc)
directly, so a first dispatch spends no tool round fetching them — a tool round replays
the agent's whole context, which costs more than the payload. The tools remain the access path
for chat turns and any agent whose brief carries no index.

### How discovery scales

Fetch (Tier 3) is O(1) - only the one chosen node is pulled, whatever the catalog size. The cost that
grows is **discovery** ("which of N is the right reference?"), paid by every coding agent. The MCP seam
lets discovery climb without changing the agent contract or the on-disk format:

1. **Reason over `index.json`** (today) - the whole catalog fits cheaply in context; the agent does
   full-information semantic matching. Best while the library is small (tens of nodes).
2. **Narrow before reasoning** - once the index no longer fits cheaply in every agent's context, narrow
   it first. `agent_library_index { "query": "..." }` does the lexical half today (every term of the
   query must appear in a node's id, title, tags, purpose or summary), and the cold-start brief inlines
   the whole block only while the offered nodes number 60 or fewer; above that it inlines the group
   counts and tells the agent to query. Reach for an **embedding / vector index only if lexical recall
   proves too weak** at that scale - that's the point where an indexer earns its keep. Same seam either way.
3. **Lift discovery to the Director / a librarian agent** - search once per graph and hand each coding
   agent a pre-selected `ref` (amortizes across the fan-out); an LLM-judge reranks the shortlist when
   fit needs real judgment. Multi-agent reasoning belongs *here*, over a pre-narrowed set - never agents
   scanning the full catalog first-pass.

Rung 3 is unbuilt, and rung 2 has only its lexical half: earned when the catalog actually outgrows
rung 1, not before. Embeddings aren't rejected - they're simply not worth their cost until the
catalog stops fitting cheaply in context.

### Tier 1 - the assembled index (cheap, loaded whole)

One compact record per node. For 30–50 nodes this is a few thousand tokens - an agent loads the
entire catalog once and reasons over it. The **I/O contract** + **use-when/avoid-when** are the
highest-signal fields for matching.

Each record is **assembled** by `agent_library_index`, not stored whole:

- **Identity + I/O + permissions are DERIVED from the node's `node-contract.json`** (`title`, `sfSymbol`,
  `summary`, `io`, `permissions`) - the contract is the single source of truth, so `io` can never drift
  from what the node actually declares.
- **Discovery metadata is curated in `index.json`** (`tags`, `purpose`, `useWhen`, `avoidWhen`, `reuse`,
  `platform`) - the fields that can't be derived from the contract. `platform` is informational only:
  whether a node is offered to a platform is decided by which source files its folder holds.

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

A node folder has three files (four with a web version):

- **`node-contract.json`** - the node's typed interface: `title`, `sfSymbol`, `summary`, `inputs`,
  `outputs`, `permissions`. **This is the source of truth for I/O and identity.**
- **`Node.swift`** - the implementation. Every port it reads/writes via `ctx.input*` / `ctx.output*` /
  `ctx.setOutput*` must use a `name` declared in the contract. (Copying a clean library node keeps you on
  the right side of this; the same rule is enforced automatically for *generated* nodes - see
  [the port-name check](#the-port-name-check).)
- **`Node.js`** *(optional)* - the same node for a web project. A node is offered to a target iff
  its folder has that target's source file, so a folder with only `Node.swift` never shows up in a
  web project. Every pure GPU effect ships both today, plus `camera.web` beside `camera.macos`. The
  accessor names match the Swift kit, so one contract serves both files.
- **`CARD.md`** - prose reuse guidance + gotchas (Tier 2), short by design.
- **`Card.swift`** *(optional, rare)* - a custom card ([GRAPH_AND_NODES.md](GRAPH_AND_NODES.md#custom-card-cardswift)),
  copied along when the node is instantiated (`ui_add_library_node` / the palette); a contract that
  declares a `card` block lands with the card ON (it is the node's face — corner-pin's handles over
  the output, a controller's learn strips), a `Card.swift` without one waits in the context menu.
  The index derives `card: true` from the file (served as "ships a card"). `corner-pin`, `midi.macos`
  and `osc-input` ship one today: library nodes get a card only when the interaction has no row
  equivalent. The two controller nodes share ONE card file byte-for-byte (`SZOscNodeTests` pins it) —
  edit `midi.macos/Card.swift`, copy to `osc-input/`.

Then add **one curation entry** to `NodeLibrary/index.json`, keyed by folder `id`, carrying only the
fields that aren't in the contract: `tags`, `purpose`, `useWhen`, `avoidWhen`, `reuse`, `platform`.
A test pins that the index names exactly the shipped folders, so a folder without an entry (or an
entry without a folder) fails `swift test`.

> **Derive, don't duplicate.** `title`, `sfSymbol`, `summary`, `io`, and `permissions` are read from
> `node-contract.json` and merged into the served record automatically. **Never restate them in
> `index.json` or `CARD.md`** - a hand-copied `io` is exactly how the old `camera.macos` index drifted to
> claim a phantom `resolution` input the contract never had. (Legacy `io`/`title` keys in an `index.json`
> entry are tolerated but ignored.)

#### The port-name check

When a *generated* node is compiled, `agent_compile_node` cross-checks the contract against `Node.swift`
(`SZPortBindingAudit`): a port the code reads/writes that the contract doesn't declare is a **hard error**
(the source isn't promoted); so is a declared port named off the wrong **channel**. The runtime carries a
port on one of three wires per direction - values, textures, strings - and the accessor picks the wire, so
`ctx.inputFloat` on a `texture` port resolves to nil every frame and the node silently falls back to its
hardcoded default. The numeric accessors all share one wire (`inputFloat` is `inputFloats(port)?.first`,
`inputBool` reads the same floats), so a `bool` read as a float is fine; an `event` port is never delivered
at all. A port declared in the contract that the code never touches is a **warning** (usually a dead
control). Hand-added library nodes don't pass through this tool, so keep the contract and
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
