# Building agents

SubjectiveZero's agents are not hardcoded. What each one does — how its door decides what
a message means, what a turn is told, how a decision routes — is a folder you can open,
edit and reload. This is the tutorial; [AGENT_GRAPHS.md](AGENT_GRAPHS.md) is the reference.

---

## An agent is a folder

```
agents/director/
  agent.json               who this agent is: id and seat
  graph.json               THE graph — one per agent
  prompts/*.md.mustache    what it says to a model — all prose lives here
  steps/<name>/Step.swift  one compiled decision per folder — one file, often one line
```

Three agents ship: **director** (plans a build, dispatches the fleet, answers your chat),
**coding** (one session per node — writes the Swift that renders), **debug** (a chat-only
helper, seatless). An agent takes a **seat** by declaring it; whoever holds `coding`
receives dispatches, whoever holds `director` owns build threads. Replace either folder
and the app does not notice.

The app copies its bundled packs to `~/Library/Application Support/SubjectiveZero/agents/`
at launch — that copy is yours to edit, and it wins until an app update ships a newer
file. Or point `SZ_AGENT_PACKS` at a pack root of your own.

## A message is words, and the door decides

Nothing calls an agent directly. Everything is a message — prose — and every graph opens
at its **door**: the step node with the reserved id `door`. The door is real code you can
open: it reads the message and the world (a granted run, a standing assignment, an
existing session) and answers an outcome, which routes like any other step's.

Here is the whole shipped coding agent's decision surface:

```swift
// coding/steps/door/Step.swift
struct Ruling: Codable { let outcome: String }

let step = SZStep(outcomes: ["implement", "continue", "edit", "chat", "chat-resumed"]) { ctx in
    if let job = ctx.assignment { return job.attempt > 1 ? "continue" : "implement" }
    let ruling = try await ctx.ask("triage", as: Ruling.self)
    if ruling.outcome == "edit" { return "edit" }
    return ctx.resuming ? "chat-resumed" : "chat"
}
```

Assigned work forks on the attempt — a retry continues the node's own session,
re-grounded on its blocker. Anything else is the user's prose, and the MODEL judges it
through the pack's own `triage` template: a change request against the node takes the
`edit` lane — a work order, re-grounded on the node's live contract and source every
turn — and a question stays conversation, forked on whether this scope already knows us.
One file, and you have read everything this agent will ever decide.

And here is the shipped director's build lane — the heart of `director/graph.json`:

```jsonc
{
  "nodes": [
    { "id": "door", "title": "On message", "step": "door" },
    { "id": "decompose", "title": "Decompose", "turn": { "brief": "decompose", "context": "conversation" } },
    { "id": "implement", "title": "Implement", "dispatch": { "to": "coding" } },
    { "id": "unresolved", "title": "Still unresolved?", "step": "work-left" },
    { "id": "reconcile", "title": "Reconcile", "turn": { "brief": "reconcile", "session": "resume" } }
  ],
  "edges": [
    { "from": "door", "outcome": "build", "to": "decompose" },
    { "from": "decompose", "outcome": "ok", "to": "implement" },
    { "from": "implement", "outcome": "settled", "to": "unresolved", "maxTraversals": 2 },
    { "from": "unresolved", "outcome": "yes", "to": "reconcile" },
    { "from": "reconcile", "outcome": "ok", "to": "implement" }
  ]
}
```

Read it: the door's `build` ruling enters the decompose turn; `ok` routes to `implement`,
which sends one assignment per work-set node and **waits for the whole set** — the
traversal holds at the dispatch while the fleet works, and settlement is the node's own
`settled` outcome. The settled edge loops back through the `unresolved` gate under a
`maxTraversals: 2` leash — the leash IS the retry budget — and a gate answering `no` has
no edge, so a resolved fleet ends the run right there. That is not an error; it is the
graph's honest ending.

A node is one of exactly three forms: a **step** (compiled code, its outcomes exported by
the step itself — the door is the step at the reserved id), a **turn** (a full agent turn
whose body is a mustache brief, named by stem; outcomes fixed `ok`/`error` — what an
agent *says* never routes), or a **dispatch** (fan the run's work set out to a seat,
wait, settle onward).

## Three ways to change what an agent does

**Change the words.** Every turn names a brief: edit `prompts/decompose.md.mustache` and
the next turn uses it — briefs are read per render, no relaunch. Templates use `{{token}}`
substitution from one closed table; a token nothing substitutes is refused at load, and
nothing ever ships to a model with a literal `{{token}}` left in it. (The SHIPPED packs'
briefs are byte-pinned by `SZBriefPinTests` — a deliberate prose change in the repo
re-records its pin, `SZ_RECORD_BRIEF_PINS=1 swift test --filter SZBriefPinTests`, and
commits the fixture diff with the template change. Your materialized or `SZ_AGENT_PACKS`
copies are yours; the pins guard the shipped bytes.)

**Change the flow.** Add a node, wire an edge, remove one. Outcomes are ports: the step
declares what it can answer, the graph decides where each answer goes, and an answer with
no edge ends the traversal.

**Change a decision.** Every question the run asks itself is one file:

```swift
// steps/work-left/Step.swift
let step = SZStep(outcomes: ["yes", "no"]) { $0.hasWorkLeft ? "yes" : "no" }
```

That is the entire step, and the entire authoring surface is this one construct: declare
the outcomes (the card's ports), write the body. `ctx` carries the delivery's facts —
`message` (the words), `node`, `resuming`, `run`, `assignment`, `hasWorkLeft` — plus one
capability, `ask`. Save a `Step.swift` and the app recompiles and swaps it in place — the
same hot reload render nodes get; a broken edit keeps the previous build answering while
the compiler's words surface at the next run's gate.

## Ask the model from code

A ruling that needs a model's judgment is one awaited call — this is the whole shape:

```swift
// director/steps/triage/Step.swift
struct Verdict: Codable {
    enum Call: String, Codable { case retry, park }
    let call: Call
}
let step = SZStep(outcomes: ["retry", "park"]) { ctx in
    let verdict = try await ctx.ask("triage", as: Verdict.self)
    return verdict.call.rawValue
}
```

`ctx.ask` names a pack template (`prompts/triage.md.mustache`), which the HOST renders
against the same facts snapshot the evaluation holds, runs as ONE stateless completion
through the routed provider, and decodes into your `Codable` type — re-asking once with
the decode error attached when the reply doesn't fit, then throwing honestly. The step
never sees a provider, never names a model, and never assembles a prompt string; what it
does with the answer is ordinary Swift, and an outcome may carry an effect
(`.outcome("implement", effects: [.requestBuild])` — the shipped director door's own
line, which mints a run with the user's message as its instruction). (This exact step is
compiled through the real toolchain and driven, repair loop included, by
`SZRuntimeTests/SZAskModelExampleTests` — if the kit drifts, the tutorial fails before
you do.)

## The loop

```
edit  →  debug_check_pack  →  build
```

`debug_check_pack` loads and validates a pack root exactly as a run would — compiling
every referenced step through the real toolchain — without spending a token:

```
agent coding · seat: coding · 1 step · 14 prompts
  graph · door: implement · continue · edit · chat · chat-resumed · 6 nodes
agent debug · no seat · 1 step · 1 prompt
  graph · door: answer · 2 nodes
agent director · seat: director · 2 steps · 6 prompts
  graph · door: build · answer · answer-resumed · implement · 7 nodes
verdict: validates — 3 agents, zero defects
```

Each graph line leads with the DOOR'S declared outcomes — everything this agent can
decide about a message, read off its compiled door.

A defect names the file and the fix, and they are collected — one bad graph neither hides
its siblings' defects nor unseats its pack. Some of what the gate refuses: an edge on an
outcome the step never declares; no `door` node, or a door that is not a step; a brief
naming a token nothing substitutes, or a partial the pack does not carry; a dispatch to a
seat nobody holds; a node the door cannot reach; an unbounded cycle.

## Your own pack, from scratch

A pack root needs both seats filled. This is the smallest library that validates — eight
files (the recipe is pinned byte-for-byte by
`SZAITests.theAuthoringTutorialsMinimalPackValidates`, so if the rules drift, this
tutorial fails before you do):

`my-packs/director/agent.json`
```json
{ "id": "director", "seat": "director" }
```

`my-packs/director/graph.json`
```json
{
  "nodes": [
    { "id": "door", "step": "door" },
    { "id": "plan", "turn": { "brief": "plan" } },
    { "id": "implement", "dispatch": { "to": "coding" } }
  ],
  "edges": [
    { "from": "door", "outcome": "build", "to": "plan" },
    { "from": "plan", "outcome": "ok", "to": "implement" }
  ]
}
```

`my-packs/director/steps/door/Step.swift`
```swift
// Every delivery here is the granted build — route it to work.
let step = SZStep(outcomes: ["build"]) { _ in "build" }
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

`my-packs/coding/graph.json`
```json
{
  "nodes": [
    { "id": "door", "step": "door" },
    { "id": "implement", "turn": { "brief": "implement" } }
  ],
  "edges": [
    { "from": "door", "outcome": "implement", "to": "implement" }
  ]
}
```

`my-packs/coding/steps/door/Step.swift`
```swift
// Assigned work goes straight to the implementation turn.
let step = SZStep(outcomes: ["implement"]) { _ in "implement" }
```

`my-packs/coding/prompts/implement.md.mustache`
```
Implement node {{node}}: {{prompt}}

{{boundary}}
```

`debug_check_pack {"path": "…/my-packs"}` answers `validates — 2 agents, zero defects`;
launch with `SZ_AGENT_PACKS=…/my-packs` and Build runs it.

## A worked change: third-strike escalation

Say attempt 3 on a node should stop resuming the same stuck session and start over with a
sharper framing. Two lines in the coding door — the guard and its declared outcome:

```swift
let step = SZStep(outcomes: ["implement", "continue", "escalate", "edit", "chat", "chat-resumed"]) { ctx in
    if let job = ctx.assignment {
        if job.attempt > 2 { return "escalate" }
        return job.attempt > 1 ? "continue" : "implement"
    }
    let ruling = try await ctx.ask("triage", as: Ruling.self)
    if ruling.outcome == "edit" { return "edit" }
    return ctx.resuming ? "chat-resumed" : "chat"
}
```

And the wiring — inside `coding/graph.json` — one node and one edge:

```jsonc
{ "id": "escalate", "title": "Start over, sharper", "turn": { "brief": "escalate" } },

{ "from": "door", "outcome": "escalate", "to": "escalate" }
```

Write `prompts/escalate.md.mustache` and you are done: the decision is visible in the
door's code, the new lane is visible on the canvas, and nothing in Swift outside your
pack knows it exists.

## What is closed, and why

**A turn's outcomes.** `ok`/`error`, period. Content routing belongs to steps, where the
answer is typed and declared — prose scanning for verdicts is unrepresentable.

**A step's reach.** It reads facts and returns an outcome — plus, when it needs the world
to move, a typed EFFECT the host performs. It never mutates the app itself; anything else
it wants done travels through the graph.

**The token table.** A brief may only name tokens the assembler substitutes, so a
template cannot promise a model something that will not be there.

**Seats.** Exactly one holder each, over the whole loaded library — dispatch is by seat,
so the work always has exactly one place to land.

Everything else is yours: the graph, the prose, the decisions, and which folder holds
which seat.
