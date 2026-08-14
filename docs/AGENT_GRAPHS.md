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

One enum, `SZMessageKind`, spoken everywhere — queue intent, message-node port, delivery record.
A graph's **message node** is its one door: a delivered message leaves by the port bearing its own
kind.

| message | means | who sends it |
|---|---|---|
| `chat` | one reply on a scope's transcript | the user, or a tool |
| `build` | open a fleet thread over the project's work set | the Build press, `ui_build`, a chat turn's requestBuild effect |
| `item` | one dispatched work item | a director graph's dispatch node |
| `request` | a structured proxied operation (split/merge …) | `ui_split_node`, `ui_merge_nodes` — routed on payload, never prose |
| `steer` | a note folded into the recipient's NEXT brief | the user, mid-run |

`steer` is the one kind that never enters a graph: the thread machine drains steers into the next
traversal's facts, and a conclusion sweeps leftovers.

**One message is one traversal.** Nothing re-enters a graph: a dispatch waits for its fleet and
settles onward over its own edge, so the whole journey from delivery to conclusion is a single
connected walk — and the RUNS list maps one row to one message received. (`settled` used to be a
fifth kind, the fleet's reply re-entering the sender's graph as a second traversal; the waiting
dispatch made it the dispatch node's own outcome instead, and the kind is gone.)

**Vocabulary.** A build is a **thread**: short graph **traversals** joined by messages, sharing one
identity from the Build press to the conclusion. A **turn** is one agent running because a turn
node asked — the unit that spends model time. Turn ⊂ traversal ⊂ thread.

## One folder per agent

```
Resources/Agents/<id>/
  agent.json        identity and seat — nothing else
  graphs/           one file per graph — the graph's name IS the filename stem
  prompts/          brief templates (*.md.mustache) — ALL prompt prose lives here
  steps/<name>/     one compiled decision per folder: a single Step.swift
```

`agent.json` is small on purpose:

```jsonc
{
  "id": "director",   // must equal the folder name — identity lives in the filesystem
  "seat": "director"  // director | coding; omit = seatless (addressable, never dispatched to)
}
```

There is no third field: which graph answers which kind is said by the graphs' own message nodes,
so the manifest has nothing left to arbitrate. (A leftover `defaults` key is refused by name rather
than ignored — an author must not believe they still steer routing from here.)

The shipped packs each carry ONE document — `director/graphs/director.json`,
`coding/graphs/coding.json`, `debug/graphs/debug.json`. That is a convention, not a rule: an agent
may spread its lanes over several files, as long as each kind has exactly one destination
(`kindRoutedTwice` refuses the tie).

Seats resolve over the loaded library: exactly one holder each, checked at validation. A dispatch
names a seat, never an agent id — replace a folder and whoever now holds the seat receives the work.

## Graph files: one door and five node forms

```jsonc
{
  "name": "director",          // must equal the filename stem
  "label": "Director",         // display name (optional)
  "hint": "…",                 // subtitle (optional)
  "nodes": [ { "id": "message", "title": "On message", "onMessage": {} }, … ],
  "edges": [ { "from": "message", "outcome": "build", "to": "strategy" }, … ]
}
```

Every graph has exactly **one message node** — its door — and the kinds it accepts are the
**outcomes of the edges leaving it**. There is no `kind` field, no `entry` map, and no `caps`
budget: the ports and the routing cannot disagree because they are the same edges, and retry
depth is the settled edge's own leash. All three retired keys are refused by name at decode
rather than ignored.

> **Why the door is a node.** `entry` used to be a map from kind to node, so a graph with two doors
> drew as two disconnected fragments — the fleet's `settled` reply in particular had nowhere to
> enter but a second entry key, leaving the retry lane attached to nothing. As a node, every kind
> the agent accepts is one port on one card, the whole document is one connected picture, and
> `unreachable` refuses a floating fragment at load instead of leaving it to be noticed on a canvas.

A node takes **exactly one of five forms** — enforced at decode, so a malformed node is
unrepresentable:

| form | body | outcomes |
|---|---|---|
| `"onMessage": {}` | the door — no body, no cost, no host seam | the message kinds it routes; `steer` is not among them |
| `"step": "<folder>"` | the compiled `Step.swift` in the agent's pack | whatever the step's own exported declaration names |
| `"ask": { "prompt", "outcomes", "effects"? }` | a structured model query authored as data — the prompt file is the question | its declared `outcomes`; the reply's `{"outcome": …}` routes, repaired once on a shape mismatch |
| `"turn": { "brief", "session"?, "tools"? }` | a full agent turn; the mustache brief IS the body | fixed `ok` / `error` — process truth only, content never routes |
| `"dispatch": { "to", "items" }` | fan work out — one `item` message per element of the `items` fact — and **wait for the set** | `settled`, when the last item lands (or the watchdog synthesizes the stragglers) |

**A dispatch waits.** The traversal holds at the node while the fleet works — the card is live,
its sub-agent lanes ticking under it — and when the set closes it produces `settled` and routes
its one edge. No edge = settlement ends the run (procedural's spelling). A settled edge that
loops back is the RETRY ROUND, and it must carry a `maxTraversals` leash — the same bound every
other loop speaks; an unleashed settled loop is refused at load like any unbounded cycle. There
is no separate "rounds" budget any more: the leash is the budget.

**`ask` vs a step's `askModel`.** Both run one stateless completion through the same serving path
(render like a brief, route, complete, journal, repair). The ask form is the declarative spelling
— prompt file + declared outcomes + per-outcome `effects`, all validated at load — for the common
ruling that needs no computation. A step with `askModel` remains the code spelling for rulings
that weigh facts first. The shipped `route-reply` is an ask node: its `build` outcome carries the
`requestBuild` effect as config, and no `Step.swift` exists for it.

`session` on a turn: `spawn` (default) cold-starts; `message` continues the scope's existing
session (spawning when none exists). `tools` narrows the turn's tool surface; nil is the agent's
default — and `[]` means no MCP server at all. `dispatch.to` is a seat; `dispatch.items` must be a
`[String]`-typed fact of the node's lane (the catalog check at load) — `workSet` is the one builds
use.

Edges are `{ from, outcome, to, maxTraversals? }`. An outcome with **no edge ends the traversal**
— that is not an error; it is how a condition's `no` ends a run. A cycle is legal only across a
`maxTraversals`-bounded edge; unbounded cycles are refused at load.

## Lanes: one document, several kinds, still typed

A document may route several kinds — the shipped director carries its chat lane and its build lane
in one file — but a NODE may not straddle two. Steps and briefs are typed to one kind's facts, so
the gate computes, per node, which ports can reach it: exactly one lane, or `laneImpure`. That is
strictly stronger than the era when a graph simply declared one `kind` by fiat, because now the
lane is *proven* by reachability from the door the message actually enters.

Merging kinds into one file is therefore allowed and never required. What it buys is
deduplication: the director's three build strategies share `reconcile`, `implement` and
`nodes-failing`, which would have to be triplicated across separate variant files.

## Strategies: a route, not a file

A build **strategy** is a step at the head of the build lane, not a choice of document. The
director's `strategy` step is one line:

```swift
let step = SZBuildRouter("agentic", "procedural", "recovery") {
    ["procedural", "recovery"].contains($0.runVariant) ? $0.runVariant : "agentic"
}
```

Its three ports route into three lanes that share nodes wherever their wiring agrees:
**agentic** (decompose → dispatch, whose leashed settled edge buys the reconcile rounds; the
default the step falls back to), **procedural** (token-free and contract-first — no planning
turn, and its own dispatch carries no settled edge, so the first settlement concludes), and
**recovery** (gated on `nodes-failing`: a failing fleet gets a reconcile turn and a re-dispatch
through the same loop; a healthy fleet ends the run untouched).

The requested name reaches the step as the `runVariant` fact: `SZ_RUN_GRAPH` (env, per launch) >
the persisted choice (`debug_set_orchestrator`). The host does **not** validate it — the step owns
the fallback, and refusing a name here could overrule a pack that would have honoured it — but a
name the wiring does not offer gets one honest status line, and the canvas shows which port fired.

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
the host's. The director's `route-reply` step is the shipped example: it rules what a chat turn
was, and only its `build` ruling carries the effect that starts a run.

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
holder each), one destination per kind per agent, graph shape (duplicate ids, dangling/duplicate
edges, undeclared outcomes, unbounded cycles, the door's cardinality, reachability, lane purity),
turn briefs (the template exists; every `{{token}}` is
one the LANE's assembly substitutes; every partial a token renders from ships in the pack — no
literal token reaches a model from a turn brief; an `askModel` template is resolved at RUN time and
is not scanned, so a typo there ships literally), dispatch targets (a held seat whose holder handles `item`)
and items facts (catalogued, `[String]`-typed), and — through the step seam — each compiled step's
declared outcomes and facts kind, checked against the one lane that reaches it. With no step provider those checks are **skipped and the report
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
a step opens its `Step.swift`, a turn opens its brief, and a dispatch links into the graph it calls
— the very files (and graphs) the next traversal will use.

## RUNS records and the panel

Every message an agent receives — a Build press, each dispatched item, each chat reply — is ONE
record, an `SZAgentGraphRun`: who received which kind, the ordered trace of the whole journey
(running → done/failed, outcome, detail — a dispatch visit carrying its fleet's tally, live on
the entry while the set works), and the conclusion. The trace opens at the door, so a record's
first entry says what arrived, and a build's record stays LIVE for its whole run — fleets
included — sealing only when the story actually ends. Live records exist only in memory; a
record persists at seal into the project's `runs.json`, so the panel's RUNS list, each row's
trace, and the conclusions survive a relaunch while a crash mid-traversal loses the record and
keeps the transcript. The history caps per budget, never evicting a live record.

A chat record carries **no thread**, even when delivered mid-build: a node outside the work set can
be chatted while the fleet runs, and the list's thread header picks the newest non-item traversal
as the thread's decider — so a chat joining the group would paint its own ending as the build's.

The list names the **agent** ("Director", "Coding"), with the graph's authored `label` on the line
below and the raw pack id / file stem in the tooltip. On the canvas, a dispatch card carries a band
of its sub-agents: one lane per dispatched item, each naming the node that agent is on right now,
its running clock, and a pulsing `live` badge — swapped for a conclusion badge and a frozen clock
as each settles, so the band drains from working to done while the fleet lands.

## The set supervisor

One pure value machine (`SZThreadMachine`) supervises each dispatch set while the traversal's
dispatch node waits; hosts are its motor — they deliver items, arm timers, and report back as
events — and tests drive the real machine with event lists. The invariants:

- **One open set at a time, structurally.** The engine is sequential and the dispatch node holds
  the traversal until its set closes; the machine refuses a second set defensively.
- **Exactly one settled summary per set.** Collected from item outcomes when the last lands, or
  synthesized when the per-set watchdog fires: stragglers are cancelled *before* the summary
  ships and marked `timedOut` with the deadline stated at millisecond precision. A closed set
  drops every later event — keyed by set id, never node id, which a re-dispatch makes ambiguous.
  The deadline mirrors the coding-turn budgets, so the watchdog can never fire before a healthy
  turn's own budget would have ended it.
- **Attempts accumulate per item across sets** — the retry loop re-dispatches a node as attempt
  2, stamped into the order as it is minted.
- **Steers queue, never traverse.** A steer raised while a fleet is out is folded into the
  traversal's NEXT brief render; the conclusion carries whatever was never consumed.
- **Stop is not timeout.** Cancellation propagates into the waiting dispatch; the set is swept
  with no summary synthesized, and the traversal concludes `cancelled`. Termination is absorbing:
  after a stop, every event is a no-op by construction.

## Effects

A step answers with an outcome, and may ask for named host ACTIONS alongside it:

```swift
return .outcome("build", effects: ["requestBuild"])
```

The names are closed per kind, declared in the facts spec beside the facts themselves
(`SZChatEffect.requestBuild`, `SZBuildEffect.captureStatuses`, `SZRequestEffect.split`/`.merge`)
and generated into `SZEffectCatalog`. The engine validates every requested name against the graph
kind's set BEFORE performing any of them — an unknown or cross-kind name is a traversal defect
naming it, and nothing runs. What survives validation the host performs in the step's own order,
after the step returned and before the edge routes.

That ordering is the contract: an effect is how a step reaches the world (a chat turn ruling
`build` starts the run), and it lands before the traversal moves on. Today `requestBuild` is the
only one a shipped step requests; the others exist in the spec, and the host answers them with an
honest status line until their lanes are graph-routed.

## Termination

Two vocabularies, deliberately: **outcomes route** (the graph's open set — an outcome with no
edge ends the traversal), **conclusions end** (the closed set, exactly one per traversal:
`ended`, `failed`, `cancelled`, `declined` — a refusal is never a failure and never "complete" —
and `defect`, the traversal's own integrity breaking, which validation makes unreachable for
shipped packs). The thread maps the last traversal's conclusion onto its own ending, plus
`roundCeiling`. **Sessions survive every ending**: the host keeps each node's coding session
across traversals, a retry resumes it re-grounded on the blocker, and a fresh thread's first
dispatch still cold-starts by design — each item's `attempt` restarts at 1.
