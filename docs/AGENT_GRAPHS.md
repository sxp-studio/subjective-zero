# Agent graphs

**An agent is a mailbox plus graphs.** Everything an agent does — which graph answers which
message, what a turn is told, what happens when the fleet settles — is data in the agent's own
folder, validated as a library at load and traversed by one engine.

Model: `SZCore/Agents/SZAgentGraph.swift` (+ `SZMessageKind.swift`, `SZSeatAssignment.swift`).
Facts: `SZCore/AgentFacts/SZFacts.swift`. Supervision: `SZCore/Supervision/SZThreadMachine.swift`.
Loader + validation: `SZAI/Agents/SZAgentPackLoader.swift`. Engine: `SZAI/Engine/SZGraphEngine.swift`
(+ `SZGraphStrategy.swift`, `SZBriefRenderer.swift`). Step runtime: `SZRuntime/Steps/`.
Shipped packs: `SZAI/Resources/Agents/`. Tutorial: [AUTHORING.md](AUTHORING.md).

## The message vocabulary

One enum, `SZMessageKind`, spoken everywhere — queue intent, graph kind, entry key, delivery
record. A graph declares which kind it **handles**, and a delivered message enters the handling
graph at that kind's declared entry node.

| message | means | who sends it |
|---|---|---|
| `chat` | one reply on a scope's transcript | the user, or a tool |
| `build` | open a fleet thread over the project's work set | the Build press, `ui_build`, a chat turn's requestBuild effect |
| `item` | one dispatched work item | a director graph's dispatch node |
| `settled` | the dispatch set's single terminal reply | the host, as supervisor — it IS the reply |
| `request` | a structured proxied operation (split/merge …) | `ui_split_node`, `ui_merge_nodes` — routed on payload, never prose |
| `steer` | a note folded into the recipient's NEXT brief | the user, mid-run |

`steer` is the one kind that never enters a graph: the thread machine drains steers into the next
traversal's facts, and a conclusion sweeps leftovers.

**Vocabulary.** A build is a **thread**: short graph **traversals** joined by messages, sharing one
identity from the Build press to the conclusion. A **turn** is one agent running because a turn
node asked — the unit that spends model time. Turn ⊂ traversal ⊂ thread.

## One folder per agent

```
Resources/Agents/<id>/
  agent.json        identity, seat, per-kind default variants
  graphs/           one file per graph — the graph's name IS the filename stem
  prompts/          brief templates (*.md.mustache) — ALL prompt prose lives here
  steps/<name>/     one compiled decision per folder: a single Step.swift
```

`agent.json` is small on purpose:

```jsonc
{
  "id": "director",                  // must equal the folder name — identity lives in the filesystem
  "seat": "director",                // director | coding; omit = seatless (addressable, never dispatched to)
  "defaults": { "build": "agentic" } // kind → graph name, only where a kind has VARIANTS
}
```

Seats resolve over the loaded library: exactly one holder each, checked at validation. A dispatch
names a seat, never an agent id — replace a folder and whoever now holds the seat receives the work.

## Graph files: an entry map and three node forms

```jsonc
{
  "name": "agentic",           // must equal the filename stem
  "kind": "build",             // the kind this graph HANDLES
  "label": "Agentic",          // picker display name (optional)
  "hint": "…",                 // picker subtitle (optional)
  "caps": { "rounds": 2 },     // settled re-entries this graph buys (≥ 1; omit with the settled entry)
  "entry": { "build": "decompose", "settled": "work-left" },
  "nodes": [ … ],
  "edges": [ { "from": "decompose", "outcome": "ok", "to": "implement" } ]
}
```

`entry` maps a **message kind to the node its delivery enters at**. A graph always declares its
own kind's entry; `settled` re-enters here after a dispatch set concludes — and *omitting* the
settled entry is how a graph says "the first settle concludes the run" (the shipped `procedural`).
Wire sugar: a bare string (`"entry": "plan"`) is the graph's own kind.

A node takes **exactly one of three forms** — enforced at decode, so a malformed node is
unrepresentable:

| form | body | outcomes |
|---|---|---|
| `"step": "<folder>"` | the compiled `Step.swift` in the agent's pack | whatever the step's own exported declaration names |
| `"turn": { "brief", "session"?, "tools"? }` | a full agent turn; the mustache brief IS the body | fixed `ok` / `error` — process truth only, content never routes |
| `"dispatch": { "to", "items" }` | fan work out: one `item` message per element of the `items` fact | `sent`, and **no out-edges** — send-and-conclude is structural |

`session` on a turn: `spawn` (default) cold-starts; `message` continues the scope's existing
session (spawning when none exists). `tools` narrows the turn's tool surface; nil is the agent's
default. `dispatch.to` is a seat; `dispatch.items` must be a `[String]`-typed fact of the graph's
kind (the catalog check at load) — `workSet` is the one builds use.

Edges are `{ from, outcome, to, maxTraversals? }`. An outcome with **no edge ends the traversal**
— that is not an error; it is how a condition's `no` ends a run. A cycle is legal only across a
`maxTraversals`-bounded edge; unbounded cycles are refused at load.

## Variants, defaults, and the picker

Several graphs may handle one kind — they are that kind's **variants** — but only under a named
default: `agent.json`'s `defaults` must name exactly one of them, or the pack is refused (a plain
delivery must never open a coin toss). A single-graph kind needs no entry.

The director ships three build variants: **agentic** (decompose → dispatch → reconcile rounds; the
default), **procedural** (token-free and contract-first — no turns, first settle concludes), and
**recovery** (entry at the `nodes-failing` condition: a failing fleet gets one reconcile turn and a
re-dispatch; a healthy fleet ends the run untouched).

Selection is per-run, resolved at Build: `SZ_RUN_GRAPH` (env, per launch) > the persisted choice
(the AI Settings run-graph pane, or `debug_set_orchestrator`) > the pack default. A stale or
typoed choice falls back to the default with one honest status line, never silently. A new
build-kind file in the director's `graphs/` is selectable with no Swift change.

## Steps: one Step.swift, typed to its kind

A step folder holds **one file**. The ordinary step is one line:

```swift
let step = SZBuildCondition { $0.hasWorkLeft }
```

The kind is part of the type name — `SZBuildCondition`, `SZChatCondition`, `SZItemCondition`,
`SZRequestCondition` (and `SZ<Kind>Router` where the answer IS data and names its own outcomes:
`SZRequestRouter("split", "merge") { … }`). A condition declares `yes`/`no` on its own; conforming
to `SZStep` directly stays available for a question that wants its own type.

The host compiles the file beside an **assembled SDK** (`SZRuntime/Steps/SZStepSDK.swift`, step
ABI v4) whose middle section is the facts spec itself — so `$0.fleetIsFailing` compiles against
the very source the app compiled, and reading a fact another kind publishes is a **compile error**
in the step, not a text-scan approximation. The compiled module **exports its declaration**
(outcomes + facts kind, `SZStepDeclare`); the pack gate reads it to validate every outcome-labeled
edge and to refuse a step wired into the wrong kind's graph. A step body may `await`; it cannot
mutate the host — anything it wants done travels back as its outcome.

### askModel and the repair loop

The SDK's one capability beyond facts: a step may ask one model question.

```swift
try await $0.askModel(template: "classify-reply", as: Ruling.self)
```

The host renders the named pack template against the SAME facts snapshot the evaluation holds,
runs one stateless completion, and decodes the reply into the requested type — tolerantly (the
first balanced JSON object in a fenced or prose-wrapped reply counts). On a shape mismatch the
host is asked again with the decode error and the previous reply attached (the repair loop), up
to `retries` more times, then the step throws honestly. The step never names a model — routing is
the host's. The shipped packs' steps are pure conditions; the surface is there for the step that
needs it.

## Facts: one spec, compiled twice

`SZCore/AgentFacts/SZFacts.swift` is the single spec of everything a step or brief can read. It
compiles normally into SZCore — and the `SZFactGen` build-tool plugin parses its sentinel-marked
region (a rigid grammar; any line it cannot classify fails the build, and a stray sentinel that
would truncate the region silently is refused loudly) to generate, at build time:

- `SZFactCatalog.generated.swift` (SZCore) — one record per fact field; what the pack gate uses
  to type-check a dispatch's `items` fact, and what tooling lists;
- `SZStepSDKGenerated.swift` (SZRuntime) — the region's verbatim text plus the derived
  conveniences below it, spliced into every step's SDK so both sides decode the same wire shape
  and spellings like `hasWorkLeft` exist exactly once.

**Adding a fact is two edits**: the documented `public var` line in the spec region, and the host
projection that populates it (`SZAI/Engine/SZGraphTraversalHosts.swift`). Every step and every
brief can then read it — no registry, no third spelling.

## The pack gate

Loading (`SZAgentPackLoader`) collects defects, never first-errors: one unreadable pack reports
while its siblings load, and inside a folder one bad graph file reports while the folder's healthy
graphs — and its seat — still load. Validation covers the library as a whole: seats (exactly one
holder each), variant defaults, graph shape (duplicate ids, dangling/duplicate edges, undeclared
outcomes, unbounded cycles, entry rules), turn briefs (the template exists; every `{{token}}` is
one the kind's assembly substitutes; every partial a token renders from ships in the pack — no
literal token ever reaches a model), dispatch targets (a held seat whose holder handles `item`)
and items facts (catalogued, `[String]`-typed), and — through the step seam — each compiled step's
declared outcomes and facts kind. With no step provider those checks are **skipped and the report
says so**; they never pass silently.

`debug_check_pack` runs the same load + validation as a pre-flight, without spending a token, and
renders the report: each agent's surface, the sorted defects, and a verdict naming the highest
tier honestly attained — `does not load`, `loads, does not validate`, or `validates`.

## Materialization, hot reload, and the source pills

Bundled resources are sealed inside a signed .app, so at start the host **materializes** the pack
tree into `~/Library/Application Support/SubjectiveZero/agents/` — the writable copy everything
then reads (`SZ_AGENT_PACKS` overrides the root wholesale). Freshness is per file by mtime: an
app update's newer copy refreshes; your newer edit wins until then; files the bundle no longer
ships are pruned (your own top-level pack folders are left alone).

Prompts need no watcher — briefs are read from disk per render, so a saved edit reaches the very
next turn. Step sources are compiled code, so each `steps/<name>/Step.swift` is watched:
save → recompile → swap on green, keep the old module on red, with the compiler's own words
surfacing at the next run's gate. In the Agent Graph panel every card carries its **source pill**:
a step opens its `Step.swift`, a turn opens its brief — the very files in the materialized tree —
and a turn's hover shows the template and, once delivered, the rendered bytes of the actual turn.

## RUNS records and the panel

Every traversal — a director's, each item's, each chat reply — is recorded as an
`SZAgentGraphRun`: who entered which graph on which kind, a per-node trace (running → done/failed,
outcome, detail), the conclusion, and — for a dispatching traversal — the set's live tally,
amended as items settle (the one sanctioned post-seal write). Live records exist only in memory; a
record persists at seal into the project's `runs.json`, so the panel's RUNS list, each row's
trace, and the conclusions survive a relaunch while a crash mid-traversal loses the record and
keeps the transcript. The history caps per budget, never evicting a live record.

## The thread machine

One pure value machine (`SZThreadMachine`) owns a thread's whole lifecycle; hosts are its motor —
they run traversals, deliver items, arm timers, and report back as events — and tests drive the
real machine with event lists. The invariants:

- **One open dispatch set at a time, structurally.** Dispatch is send-and-conclude, orders are
  minted only when the sending traversal concludes, and the settled re-entry starts only when the
  set closes — a set can never overlap a traversal, nor two sets each other.
- **Exactly one settled reply per set.** Collected from item outcomes when the last lands, or
  synthesized when the per-set watchdog fires: stragglers are cancelled *before* the reply ships
  and marked `timedOut` with the deadline stated at millisecond precision. A closed set drops
  every later event — keyed by set id, never node id, which a re-dispatch makes ambiguous.
- **Rounds.** Each settled re-entry increments the thread's round; the graph's `caps.rounds`
  (one round when it declares none) and the host ceiling (8) bound it — `min` of the two —
  and a re-entry past the bound concludes the
  thread loudly (`roundCeiling`), so a graph that ships without its own gate can never re-dispatch
  forever. The deadline itself mirrors the coding-turn budgets, so the watchdog can never fire
  before a healthy turn's own budget would have ended it.
- **Steers queue, never traverse.** A steer in any live state is folded into the NEXT traversal's
  brief; the conclusion carries whatever was never consumed, so the ending ceremony can say so.
- **Stop is not timeout.** Stop cancels the traversal and outstanding items and concludes
  `cancelled` — nothing is synthesized; a stopped conversation just ends. Termination is
  absorbing: after the conclusion, every event is a no-op by construction.

## Termination

Two vocabularies, deliberately: **outcomes route** (the graph's open set — an outcome with no
edge ends the traversal), **conclusions end** (the closed set, exactly one per traversal:
`ended`, `failed`, `cancelled`, `declined` — a refusal is never a failure and never "complete" —
and `defect`, the traversal's own integrity breaking, which validation makes unreachable for
shipped packs). The thread maps the last traversal's conclusion onto its own ending, plus
`roundCeiling`. **Sessions survive every ending**: the host keeps each node's coding session
across traversals, a retry resumes it re-grounded on the blocker, and a fresh thread's first
dispatch still cold-starts by design — each item's `attempt` restarts at 1.
