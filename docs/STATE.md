# State & Checkpoints

**Package: SZCore.** SZCore is the single source of truth: the canonical model, its JSON
serialization (for portability), and the `SZStore` every mutation goes through - which is what
makes state observable everywhere and gives undo (M8) a single surface to checkpoint. UI renders
from it, agents read it via MCP, the runtime compiles from it.

## Principles

- **Portable formats, not portable code.** Every persisted type is plain, `Codable`, and maps to
  stable JSON. macOS-specific types (Metal handles, etc.) live in SZRuntime, never in SZCore.
- **All mutation goes through `SZStore`.** Nothing edits the project behind the store's back. The
  store exposes named edit ops (`addPromptNode`, `connect`, `updateNode`, `splitNode`, …), each a
  single atomic reassignment of the value-type `SZProject` - so observers (UI re-render, runtime
  reschedule) see every change, whoever made it (user, agent via MCP, or host).
- **Undo is artifact-level checkpoints, not command sourcing (M8).** We deliberately do NOT build
  a serializable command/`Transaction` log with per-command `revert`. There are only two kinds of
  mutable state, so a checkpoint is a full snapshot of both; restore is "set it back", not "replay
  inverses". (An earlier draft of this doc specced command-sourced undo; the checkpoint model
  superseded it - see M8.)
- **Generated artifacts are staged.** Node source and contracts are written to a staging area
  and only promoted into the live project on a successful build, so a failed agent/build run
  never corrupts the project.

## State model

```
App                      // app-level prefs
├─ panel layout, window size, theme
└─ open project ref

Project                  // one effect / document
├─ name, author
├─ viewport: zoom, translation, fps, resolution, pixelFormat
└─ Graph
   └─ [Node]             // DAG of nodes
      ├─ id, kind (prompt | generated)
      ├─ title, sfSymbol
      ├─ prompt (for prompt/pre-gen nodes)
      ├─ contract (node-contract.json: typed inputs/outputs) - see GRAPH_AND_NODES.md
      ├─ position
      └─ connections are stored on the Graph, not the Node
```

Connections live on the `Graph` (a list of edges) rather than inside nodes, so rewiring during
split/merge is a graph-level edit and nodes stay independently serializable.

`App` state is **local, per-machine** - `SZAppState`, persisted by `SZAppStateIO` as
`~/Library/Application Support/SubjectiveZero/app-state.json` (pretty-printed JSON, same
human-diffable style as `project.json`, but never part of a `.subz`: a project is a portable
document and says nothing about this machine's window). Live today: `panelLayout` - the window's
panel split tree + remembered reopen spots ([UI.md](UI.md#layout)), saved on every layout change
and restored (sanitized via `normalize()`) at launch; a missing/corrupt file just means defaults.
Also live: `defaultProviderID` - the provider confirmed in the Agent Providers setup sheet
([AI_PROVIDERS.md](AI_PROVIDERS.md)); nil means first-run setup hasn't been confirmed, which is
what auto-presents the sheet at launch (post-first-run, a composer picker switch re-persists it -
the selection front-and-center must survive relaunch). Also live:
`openProjectPath` (the last USER-opened project, reopened next launch) and `recentProjectPaths`,
i.e. File ▸ Open Recent, newest first, capped at 10 (`SZAppState.noteRecentProject`). Also live:
`providerGenerationSettings` - per-provider generation choices (model /
reasoning effort / fast mode) keyed by provider id, written immediately on every composer-picker
change; rows are stored raw and clamped against the provider's real capabilities at read
(`resolvedGenerationSettings`), so a stale model id degrades to the default instead of failing.
Per-provider keying = switching codex→claude→codex keeps each provider's choices.
`windowSize`/`theme` remain dormant placeholders.

**Project lifecycle.** The launch chain is `SZ_PROJECT` env (dev override - never recorded in
history) → `openProjectPath` if it still loads → a fresh copy of the bundled sample into the
**untitled projects' home**: `~/Library/Application Support/SubjectiveZero/Projects/<uuid>/
<Name>.subz` (`SZUntitledProjects` - not "workspace"/"temp": these projects persist, they're
merely unplaced). "Untitled" is derived - a project is untitled iff its URL is under that
directory - never a stored flag; the window title gains a "not saved" suffix, and Save As out of it
deletes the source folder. There is no Save item: persistence is automatic (`persistProject` on
every edit), so Save As… is duplicate-and-switch. All switching funnels through
`SZHost.switchProject(to:)` - validate-first, one await (declared permissions) before any
mutation, runtime swap as the last fallible step, so a failed open always leaves the current
project live.

**Chat transcripts are project state; agent sessions are machine state.** Each scope's transcript
persists as `transcripts/<scope.key>.json` inside the `.subz` (`SZChatTranscriptIO`) and durable
copies of chat attachments live at `attachments/<attachment-id>/<filename>` - both travel with the
project, and on a machine with no resumable session the restored transcript is replayed into the
fresh agent session's first prompt (the cold-start recap) so it catches up. Resumable provider
session ids are bound to this machine's CLI state, so they live beside app-state.json in
`~/Library/Application Support/SubjectiveZero/agent-sessions.json` (`SZAgentSessionIO`), keyed by
project path - never in the bundle. The `.debug` scratch transcript stays ephemeral. Sidecars load
forgivingly: a missing or corrupt file means an empty transcript, never a project-open error.

### JSON shapes (portability)

State serializes to human-diffable JSON. Representative shape (illustrative, not final):

```json
{
  "project": {
    "name": "Grayscale Camera",
    "author": "SXP Studio",
    "viewport": { "zoom": 1.0, "translation": [0, 0], "fps": 60,
                  "resolution": [1280, 720], "pixelFormat": "bgra8Unorm" },
    "graph": {
      "nodes": [
        { "id": "n1", "kind": "generated", "title": "MacBook Camera",
          "sfSymbol": "camera", "position": [120, 200], "contract": "…see node-contract.json…" },
        { "id": "n2", "kind": "generated", "title": "Make Grayscale",
          "sfSymbol": "circle.lefthalf.filled", "position": [380, 200], "contract": "…" }
      ],
      "connections": [
        { "from": { "node": "n1", "port": "texture" },
          "to":   { "node": "n2", "port": "input" }, "type": "data" }
      ]
    }
  }
}
```

The per-node Swift source and full contract live in the node's folder on disk
([PROJECT layout in GRAPH_AND_NODES.md](GRAPH_AND_NODES.md)); the project JSON references nodes
by id and stores only graph-level info. This keeps node source isolated and inspectable.

## Mutation model

Every edit is a named `SZStore` op (`SZStore+GraphEdits`): `addPromptNode`, `connect` /
`disconnect`, `updateNode`, `removeNode`, `moveNode(s)`, `setInputDefault`, `setRenderEndpoint`,
`splitNode`, `mergeNodes`. Each op funnels through the store's single `mutate` entry point - one
atomic reassignment of the value-type `SZProject`, so a compound edit (a split's add-pieces +
remove-original + rewire) commits as one observable change. Ops are invoked by SZUI (user edits),
by agents via the host's MCP server, and by the host itself - all three converge on the same store
surface, which is what keeps agent-driven and user-driven edits identical.

## Undo / redo & checkpoints (M8)

Artifact-level, Cursor-style. Built last (after M6 split/merge and M7 agentic Director settled the
full mutation surface) so the engine is designed once against the complete set.

- **Only two kinds of mutable state** → a checkpoint =
  `(SZProject snapshot, [SZNodeID: Node.swift source])`. Everything else - contracts, graph,
  defaults, endpoint - lives inside the value-type `SZProject`; `Node.swift` files are the only
  mutable state outside it.
- **Restore = set it back**: set `store.project`, write the snapshotted sources, `SZProjectIO.save`,
  `runtime.loadProject` (the `promoteStagedNode` pattern). No per-command inverses to maintain.
- **One unified undo stack.** Cmd-Z reverts source + contract + graph together and recompiles.
  Structural edits and agent-run / chat-turn checkpoints share the stack: one Run = one step, one
  chat turn = one step, one split/merge = one step.
- **The chat transcript is never truncated** - undo rewinds artifacts, not the conversation.
- **Lazy agent re-grounding.** When a node's artifacts changed under its resumed session
  (undo/redo/hand edit), the next chat turn re-grounds the agent with the current contract+source.
- **Transient churn stays out of history.** Status changes, lock/busy flags, and live agent
  progress are observable state (`SZNodeAgentState`) but never checkpointed.

## Staging & failure isolation

- Agents write node source/contracts to a **staging area**.
- The host asks SZRuntime to compile staged source. On success, the host promotes the staged
  source + contract into live state (one store mutation + disk copy) and the module hot-reloads.
- On failure, staging is discarded (or kept for inspection) and live state is untouched. The
  failure is surfaced as observable status, not as a committed change.

## Test scenarios

- Round-trip: serialize a project to JSON, reload, byte-stable graph (modulo formatting).
- Undo a split restores the exact pre-split graph + wiring + sources in one step (one checkpoint);
  redo re-applies it.
- A failed compile during a coding-agent run leaves live state and the checkpoint stack unchanged
  (staging never checkpoints).
- Live agent status updates do not create checkpoints.
