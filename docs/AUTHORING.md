# Building agents

SubjectiveZero's agents are not hardcoded. What each one does — which graph answers which
message, what a turn is told, how a decision routes — is a folder you can open, edit and reload.
This is the tutorial; [AGENT_GRAPHS.md](AGENT_GRAPHS.md) is the reference.

---

## An agent is a folder

```
agents/director/
  agent.json               who this agent is: id and seat
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

Nothing calls an agent directly. Everything is a message, and every graph opens at its **message
node** — its one door, with a port per kind it accepts: `chat` (answer this), `build` (open a
fleet thread), `work` (one node's coding assignment), `request` (a structured operation in your
name). A delivery leaves by the port bearing its own name — and when work you dispatched
finishes, the reply lands at the WAITING dispatch node as its own `settled` outcome, not as a
new message.

Here is the shipped build lane — the heart of `director/graphs/director.json`:

```jsonc
{
  "nodes": [
    { "id": "message", "title": "On message", "onMessage": {} },
    { "id": "decompose", "title": "Decompose", "turn": { "brief": "prompts/decompose.md.mustache" } },
    { "id": "implement", "title": "Implement", "dispatch": { "to": "coding", "items": "workSet" } },
    { "id": "unresolved", "title": "Still unresolved?", "step": "work-left" },
    { "id": "reconcile", "title": "Reconcile", "turn": { "brief": "prompts/reconcile.md.mustache", "session": "message" } }
  ],
  "edges": [
    { "from": "message", "outcome": "build", "to": "decompose" },
    { "from": "decompose", "outcome": "ok", "to": "implement" },
    { "from": "implement", "outcome": "settled", "to": "unresolved", "maxTraversals": 2 },
    { "from": "unresolved", "outcome": "yes", "to": "reconcile" },
    { "from": "reconcile", "outcome": "ok", "to": "implement" }
  ]
}
```

Read it: a `build` delivery leaves the door by its `build` port into the decompose turn; `ok`
routes to `implement`, which sends one `work` message per work-set node and **waits for the whole
set** — the traversal holds at the dispatch while the fleet works, and settlement is the node's
own `settled` outcome. The settled edge loops back through the `unresolved` gate under a
`maxTraversals: 2` leash — the leash IS the retry budget — and a gate answering `no` has no edge,
so a resolved fleet ends the run right there. That is not an error; it is the graph's honest
ending.

A node is one of exactly five forms: the **message** door (no body — the delivered kind is the
outcome), a **step** (compiled code, its outcomes exported by the step itself), an **ask** (a
prompt file + declared outcomes: one structured model query routes, no code), a **turn** (a full
agent turn whose body is a mustache brief; outcomes fixed `ok`/`error` — what an agent *says* never
routes), or a **dispatch** (fan out, wait, settle onward).

## Three ways to change what an agent does

**Change the words.** Every turn names a brief: edit `prompts/decompose.md.mustache` and the next
turn uses it — briefs are read per render, no relaunch. Templates use `{{token}}` substitution
from a closed, per-kind namespace; a token nothing substitutes is refused at load, never shipped
to a model as a literal.

> **Which lanes are live today.** The director's build and `chat` lanes, the coding agent's `work`
> and `chat` lanes, and the debug agent's `chat` are all traversed — every conversation in the app
> now walks its agent's graph and lands in the RUNS list. The coding agent's `request` lane ships
> and validates but nothing routes to it yet: the split/merge path still renders from the host's
> own copy. Editing that brief changes nothing until it is routed; the lane is there so the routing
> is a wiring change rather than a redesign.

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

## Ask the model from code

The ask NODE covers the declarative case; when a ruling needs computation around it, the same
one-question contract is available inside a step. This is the whole shape — call the provider,
await the typed answer, act on it:

```swift
// director/steps/triage/Step.swift
struct Verdict: Codable {
    enum Call: String, Codable { case retry, park }
    let call: Call
}
let step = SZBuildRouter("retry", "park") { ctx in
    let verdict = try await ctx.askModel(template: "triage", as: Verdict.self)
    return verdict.call.rawValue
}
```

`askModel` names a pack template (`prompts/triage.md.mustache`), which the HOST renders against
the same facts snapshot the evaluation holds, runs as ONE stateless completion through the routed
provider, and decodes into your `Codable` type — re-asking once with the decode error attached
when the reply doesn't fit, then throwing honestly. The step never sees a provider, never names a
model, and never assembles a prompt string; what it does with the answer is ordinary Swift — here
the enum routes, but any facts-weighing logic can sit before or after the ask, and an outcome may
carry effects (`.outcome("retry", effects: [...])`). (This exact step is compiled through the real
toolchain and driven, repair loop included, by `SZRuntimeTests/SZAskModelExampleTests` — if the
SDK drifts, the tutorial fails before you do.)

## The loop

```
edit  →  debug_check_pack  →  build
```

`debug_check_pack` loads and validates a pack root exactly as a run would — compiling every
referenced step through the real toolchain — without spending a token:

```
agent coding · seat: coding · 3 steps · 12 prompts
  graph coding · chat · request · work · 10 nodes
agent debug · no seat · 0 steps · 1 prompt
  graph debug · chat · 2 nodes
agent director · seat: director · 2 steps · 6 prompts
  graph director · build · chat · 9 nodes
verdict: validates — 3 agents, zero defects
```

Each graph line names the KINDS its door routes — that is what an agent accepts, and the shipped
packs each answer everything they handle from one document.

A defect names the file and the fix, and they are collected — one bad graph neither hides its
siblings' defects nor unseats its pack. Some of what the gate refuses: an edge on an outcome the
step never declares; a step compiled against one kind wired into a lane of another; a brief naming
a token its lane cannot substitute, or a partial the pack does not carry; a dispatch to a seat
nobody holds, or whose holder routes no `work`; two of an agent's graphs routing one kind; a node
the door cannot reach; a node two lanes can reach; an unbounded cycle.

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
  "nodes": [
    { "id": "message", "onMessage": {} },
    { "id": "plan", "turn": { "brief": "prompts/plan.md.mustache" } },
    { "id": "implement", "dispatch": { "to": "coding", "items": "workSet" } }
  ],
  "edges": [
    { "from": "message", "outcome": "build", "to": "plan" },
    { "from": "plan", "outcome": "ok", "to": "implement" }
  ]
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

`my-packs/coding/graphs/work.json`
```json
{
  "name": "work",
  "nodes": [
    { "id": "message", "onMessage": {} },
    { "id": "implement", "turn": { "brief": "prompts/implement.md.mustache" } }
  ],
  "edges": [ { "from": "message", "outcome": "work", "to": "implement" } ]
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

## A worked change: a strategy router

The shipped pack has one build lane, but strategies are a pack edit away. Say you want a
token-free `procedural` lane beside the default. One step:

```swift
// director/steps/strategy/Step.swift
let step = SZBuildRouter("agentic", "procedural") {
    $0.runVariant == "procedural" ? "procedural" : "agentic"
}
```

And the wiring — inside `director/graphs/director.json` — re-points the door's `build` port at
the router and adds the new lane (a work gate and a dispatch with NO settled edge, so its first
settlement concludes):

```jsonc
{ "id": "strategy", "title": "Strategy", "step": "strategy" },
{ "id": "work-left", "title": "Work left?", "step": "work-left" },
{ "id": "implement-once", "title": "Implement once", "dispatch": { "to": "coding", "items": "workSet" } },

{ "from": "message", "outcome": "build", "to": "strategy" },
{ "from": "strategy", "outcome": "agentic", "to": "decompose" },
{ "from": "strategy", "outcome": "procedural", "to": "work-left" },
{ "from": "work-left", "outcome": "yes", "to": "implement-once" }
```

Save both, and `SZ_RUN_GRAPH=procedural` (or `debug_set_orchestrator`) reaches the router as the
`runVariant` fact — the default lives in the step's own `?:`, the host never second-guesses the
name, and the requested strategy shows on the agent's graph row. Nothing in `agent.json` names
any of it, and nothing in Swift knows it exists.

Reach a node from two ports of DIFFERENT kinds — `chat` and `build`, say — and the gate refuses
it (`laneImpure`): a node reads one kind's facts.

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
