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
  mutable state, so a checkpoint is a full snapshot of both; restore is "set it back", not
  "replay inverses".
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
Tiles are addressed by `SZPanelID` tokens (`viewport`, `viewport:2` for clones) - a clone-free
layout encodes byte-identically to the pre-instance format, so old builds keep reading new files
until a clone exists. Also live: `poppedOutPanels` - panels living in their own windows with their
screen frames, restored (frames sanitized against the current displays) when the workspace next
appears; the panel's dock-back spot rides `panelLayout.restorePositions`, not this record.
Also live: `defaultProviderID` - the provider confirmed in the Agent Providers setup sheet
([AI_PROVIDERS.md](AI_PROVIDERS.md)); nil means first-run setup hasn't been confirmed, which is
what auto-presents the sheet at launch (post-first-run, picking a ready card in AI Settings
re-persists it). Also live:
`openProjectPath` (the last USER-opened project, reopened next launch) and `recentProjectPaths`,
i.e. File ▸ Open Recent, newest first, capped at 10 (`SZAppState.noteRecentProject`). Also live:
`providerGenerationSettings` - per-provider generation choices (model /
reasoning effort / fast mode) keyed by provider id, written immediately from AI Settings and
`ui_set_provider`; rows are stored raw and clamped against the provider's real capabilities at read
(`resolvedGenerationSettings`), so a stale model id degrades to the default instead of failing.
Per-provider keying = switching codex→claude→codex keeps each provider's choices. Also live:
`routingProfiles` + `activeRoutingProfileName` - the named model-routing profiles and which one
governs new work ([AI_PROVIDERS.md](AI_PROVIDERS.md#model-routing)); profiles are stored
raw and resolved at delivery time, and a stale active name (its profile deleted elsewhere) reads
as routing off, like every other preference. Also live: `routingSeededStarterNames` - the
shipped starter profiles already seeded, so deleting one stays deleted - and
`routingLastProfileName` - the arm the Routing toggle released, restored when it flips back on.
`windowSize`/`theme` remain dormant placeholders.

**Project lifecycle.** The launch chain is `SZ_PROJECT` env (dev override - never recorded in
history) → `openProjectPath` if it still loads → a fresh copy of the bundled sample into the
**untitled projects' home**: `~/Library/Application Support/SubjectiveZero/Projects/<uuid>/
<Name>.subz` (`SZUntitledProjects` - not "workspace"/"temp": these projects persist, they're
merely unplaced). "Untitled" is derived - a project is untitled iff its URL is under that
directory - never a stored flag; the window title gains a "not saved" suffix, and Save As out of it
deletes the source folder once the new location is written.

**Save As moves the project; New and Open replace it.** Persistence is automatic (`persistProject`
on every edit), so a placed project has no Save item; an untitled one shows Save… on ⌘S, which opens
the Save As panel. Save As copies the bundle, then `SZHost.relocateProject(to:)` re-points
`loadedProjectURL`, the instance lock, the node-source and card watchers, the session map and the
attachment urls. Nothing reloads - the runtime takes a project URL per call and caches dylibs by
content - so a move costs no compiles and leaves the render clock alone; `.staging` travels with the
bundle, so queued messages, scheduled asks and staged node sources follow. Nothing is torn down, so
Save As works mid-run, refusing only while an open is in flight. New / Open / Open Recent DO tear
down (`clearPerProjectState` drops live runs, and the fleet's MCP listeners would then write into the
new project), so they refuse while `agentsOwnProject`. All switching funnels through
`SZHost.switchProject(to:)` - validate-first, one await (declared permissions) before any mutation,
runtime swap as the last fallible step, so a failed open always leaves the current project live.
`SZHost.flushEverything()` is the durable set named once (transcripts, both `.staging` queues,
`runs.json`, sessions, graph): a switch freezes the outgoing project with it, quit writes it, and a
Save As lands it at the new path.

**Chat transcripts are project state; agent sessions are machine state.** Each scope's transcript
persists as `transcripts/<scope.key>.json` inside the `.subz` (`SZChatTranscriptIO`) and durable
copies of chat attachments live at `attachments/<attachment-id>/<filename>` - both travel with the
project, and on a machine with no resumable session the restored transcript is replayed into the
fresh agent session's first prompt (the cold-start recap) so it catches up. Resumable provider
session ids are bound to this machine's CLI state, so they live beside app-state.json in
`~/Library/Application Support/SubjectiveZero/agent-sessions.json` (`SZAgentSessionIO`), keyed by
project path - never in the bundle. Each session record also carries its `envelope` - the
generation envelope the thread OPENED with, which is the session pin routing's affinity honours
on resume ([AI_PROVIDERS.md](AI_PROVIDERS.md#model-routing)); records without one (older
files) decode untouched. The `.debug` scratch transcript stays ephemeral. Sidecars load
forgivingly: a missing or corrupt file means an empty transcript, never a project-open error.

**Undelivered work is machine-local, deliberately.** Two queues persist under `.subz/.staging/`:
undelivered chat envelopes (`message-queue.json`, `SZMessageQueueIO`) and SCHEDULED-not-yet-started
tasks (`tasks.json`, `SZTaskQueueIO`). Both spend tokens the moment they are acted on, so neither
may travel in a bundle someone else opens - `.staging` is stripped on Save As and machine-local by
convention, and same-machine restart survival (the actual requirement) comes free. Only PENDING
tasks persist: a task that was RUNNING is never restored, because its claim, its fleet and its
traversal all died with the process, and re-admitting it would redo work that may already have
landed. Both load forgivingly, and a broken entry drops alone rather than sinking the file.

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
- **After an edit, a node's next chat never continues a thread older than the edit.** An edit
  runs in a fresh session and rewrites the files. If the node already had a session (say, the
  one that built it), that session still believes the old files, so it is dropped and the next
  chat turn starts cold with the transcript recap and the current contract and source. If the
  node had no session, the edit's own session becomes the node's session: it made the change,
  so it knows the current files, and the next chat turn resumes it.
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
