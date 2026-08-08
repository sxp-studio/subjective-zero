# Building agents

SubjectiveZero's agents are not hardcoded. What each one does — which graph answers which
message, what a turn is told, how a decision routes — is a folder you can open, edit and reload.
This is the tutorial; [AGENT_GRAPHS.md](AGENT_GRAPHS.md) is the reference.

---

## An agent is a folder

```
agents/director/
  agent.json               who this agent is: id, seat, default variants
  graphs/*.json            what it does with each kind of message
  prompts/*.md.mustache    what it says to a model — all prose lives here
  steps/<name>/Step.swift  one compiled decision per folder — one file, often one line
```

Three agents ship: **director** (plans a build, dispatches the fleet, answers your chat),
**coding** (one session per node — writes the Swift that renders), **debug** (a chat-only helper,
seatless, zero compiled code). An agent takes a **seat** by declaring it; whoever holds `coding`
receives dispatches, whoever holds `director` owns build threads. Replace either folder and the
app does not notice.

The app copies its bundled packs to `~/Library/Application Support/SubjectiveZero/agents/` at
launch — that copy is yours to edit, and it wins until an app update ships a newer file. Or point
`SZ_AGENT_PACKS` at a pack root of your own.

## Messages, and the graph that answers them

Nothing calls an agent directly. Everything is a message, and a graph is a handler for one kind:
`chat` (answer this), `build` (open a fleet thread), `item` (one node's slice of the work),
`request` (a structured operation in your name), `settled` (the app's reply when work you
dispatched finishes). A graph declares the kind it handles and the node each delivery enters at.

Here is a whole build strategy — the shipped `director/graphs/procedural.json`, in full:

```jsonc
{
  "name": "procedural",
  "kind": "build",
  "label": "Procedural",
  "hint": "Token-free and contract-first: dispatch the work the graph already declares — no
           decompose turn, no reconcile. The first settle concludes the run.",
  "entry": { "build": "work-left" },
  "nodes": [
    { "id": "work-left", "title": "Work left?", "step": "work-left" },
    { "id": "implement", "title": "Implement", "dispatch": { "to": "coding", "items": "workSet" } }
  ],
  "edges": [
    { "from": "work-left", "outcome": "yes", "to": "implement" }
  ]
}
```

Read it: a `build` delivery enters at `work-left`, a compiled condition. `yes` routes to
`implement`, which sends one `item` message per work-set node — a dispatch **sends and the
traversal concludes** (an out-edge from one is refused at load). `no` has no edge, so a clean
project ends the run right there; that is not an error, it is the graph's honest ending. And
there is no `settled` entry, so when the fleet reports back the thread simply concludes — "no
retry rounds" is spelled by omission.

A node is one of exactly three forms: a **step** (compiled code, its outcomes exported by the
step itself), a **turn** (a full agent turn whose body is a mustache brief; outcomes fixed
`ok`/`error` — what an agent *says* never routes), or a **dispatch** (fan out and conclude).

## Three ways to change what an agent does

**Change the words.** Every turn names a brief: edit `prompts/decompose.md.mustache` and the next
turn uses it — briefs are read per render, no relaunch. Templates use `{{token}}` substitution
from a closed, per-kind namespace; a token nothing substitutes is refused at load, never shipped
to a model as a literal.

> **Which graphs are live today.** The director's build variants and `chat`, and the coding
> agent's `item`, are traversed. The coding agent's `chat` and `request` graphs, and the debug
> agent's `chat`, ship and validate but nothing routes to them yet — those conversations and the
> split/merge lane still render from the host's own copies under `Resources/Prompts/`. Editing
> their pack briefs changes nothing until they are routed; the graphs are there so the routing is
> a wiring change rather than a redesign.

**Change the flow.** Add a node, wire an edge, remove one. Outcomes are ports: the step declares
what it can answer, the graph decides where each answer goes, and an answer with no edge ends the
traversal.

**Change a decision.** Every question the run asks itself is one file:

```swift
// steps/work-left/Step.swift
let step = SZBuildCondition { $0.hasWorkLeft }
```

That is the entire step. The type names the graph kind it serves — `SZBuildCondition`,
`SZChatCondition`, `SZItemCondition`, `SZRequestCondition` — and `$0` is that kind's facts,
typed: reach for another kind's fact and the step does not compile. A condition answers
`yes`/`no`; when the answer IS data, name the outcomes and return one:

```swift
let step = SZRequestRouter("split", "merge") { $0.op }
```

A step may also ask one model question — `try await $0.askModel(template: "…", as: T.self)`
renders a pack template against the same facts, runs one completion, and re-asks with the decode
error attached until the reply fits (or the step throws honestly). Save a `Step.swift` and the
app recompiles and swaps it in place — the same hot reload render nodes get; a broken edit keeps
the previous build answering while the compiler's words surface at the next run's gate.

## The loop

```
edit  →  debug_check_pack  →  build
```

`debug_check_pack` loads and validates a pack root exactly as a run would — compiling every
referenced step through the real toolchain — without spending a token:

```
agent coding · seat: coding · 2 steps · 11 prompts
  graph chat · chat · 1 node
  graph item · item · 3 nodes
  graph request · request · 3 nodes
agent debug · no seat · 0 steps · 1 prompt
  graph chat · chat · 1 node
agent director · seat: director · 4 steps · 6 prompts
  graph agentic · build · rounds: 2 · 4 nodes
  graph chat · chat · 4 nodes
  graph procedural · build · 2 nodes
  graph recovery · build · rounds: 1 · 3 nodes
verdict: validates — 3 agents, zero defects
```

A defect names the file and the fix, and they are collected — one bad graph neither hides its
siblings' defects nor unseats its pack. Some of what the gate refuses: an edge on an outcome the
step never declares; a step compiled against one kind wired into another kind's graph; a brief
naming a token its kind cannot substitute, or a partial the pack does not carry; a dispatch to a
seat nobody holds, or whose holder handles no `item`; two variants of one kind with no named
default; an unbounded cycle.

## Your own pack, from scratch

A pack root needs both seats filled. This is the smallest library that validates — six files:

`my-packs/director/agent.json`
```json
{ "id": "director", "seat": "director" }
```

`my-packs/director/graphs/build.json`
```json
{
  "name": "build",
  "kind": "build",
  "entry": "plan",
  "nodes": [
    { "id": "plan", "turn": { "brief": "prompts/plan.md.mustache" } },
    { "id": "implement", "dispatch": { "to": "coding", "items": "workSet" } }
  ],
  "edges": [ { "from": "plan", "outcome": "ok", "to": "implement" } ]
}
```

`my-packs/director/prompts/plan.md.mustache`
```
Look at the graph and sharpen each unimplemented node's prompt.

{{graph}}

{{instruction}}
```

`my-packs/coding/agent.json`
```json
{ "id": "coding", "seat": "coding" }
```

`my-packs/coding/graphs/item.json`
```json
{
  "name": "item",
  "kind": "item",
  "entry": "implement",
  "nodes": [ { "id": "implement", "turn": { "brief": "prompts/implement.md.mustache" } } ],
  "edges": []
}
```

`my-packs/coding/prompts/implement.md.mustache`
```
Implement node {{node}}: {{prompt}}

{{boundary}}
```

`debug_check_pack {"path": "…/my-packs"}` answers `validates — 2 agents, zero defects`; launch
with `SZ_AGENT_PACKS=…/my-packs` and Build runs it. (This exact recipe is pinned by a test that
loads these very bytes through the loader — if the rules drift, the tutorial fails before you do.)

## A worked change: gate the build on a failing fleet

The shipped `recovery` variant is this recipe, and it is two small files. The step:

```swift
// director/steps/nodes-failing/Step.swift
let step = SZBuildCondition { $0.fleetIsFailing }
```

The graph — `director/graphs/recovery.json` — enters at that condition for **both** the build
delivery and the settled re-entry, buys one recovery round, and reuses the pack's existing
reconcile brief for the unblocking turn:

```jsonc
{
  "name": "recovery",
  "kind": "build",
  "caps": { "rounds": 1 },
  "entry": { "build": "nodes-failing", "settled": "nodes-failing" },
  "nodes": [
    { "id": "nodes-failing", "step": "nodes-failing" },
    { "id": "reconcile", "turn": { "brief": "prompts/reconcile.md.mustache", "session": "message" } },
    { "id": "implement", "dispatch": { "to": "coding", "items": "workSet" } }
  ],
  "edges": [
    { "from": "nodes-failing", "outcome": "yes", "to": "reconcile" },
    { "from": "reconcile", "outcome": "ok", "to": "implement" }
  ]
}
```

A healthy fleet answers `no` — no edge, run over, zero tokens. A failing one gets one reconcile
turn (`session: "message"` continues the director's own session mid-run) and a re-dispatch. Since
the director's build kind now has variants, `agent.json` names the default (`agentic`); the new
variant appears in the run-graph picker by existing.

## What is closed, and why

**A turn's outcomes.** `ok`/`error`, period. Content routing belongs to steps, where the answer
is typed and declared — prose scanning for verdicts is unrepresentable.

**A step's reach.** It reads facts and returns an outcome — plus, when it needs the world to move,
a named EFFECT the host performs (`.outcome("build", effects: ["requestBuild"])`). It never mutates
the app itself, and an effect name outside its kind's declared set is refused before anything runs.
Anything else it
wants done travels through the graph.

**The token namespaces.** A brief may only name what its kind's assembly substitutes, so a
template cannot promise a model something that will not be there.

**Seats.** Exactly one holder each, over the whole loaded library — dispatch is by seat, so the
work always has exactly one place to land.

Everything else is yours: the graphs, the prose, the decisions, and which folder holds which seat.
