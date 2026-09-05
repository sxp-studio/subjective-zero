# Agent graphs

**An agent is a folder with one graph, and a message is words.** Everything an agent does —
how it decides what a message means, what a turn is told, what happens when the fleet
settles — is data and code in the agent's own folder, validated as a library at load and
run by one engine. There is no message kind anywhere: what a delivery *means* is decided
by the agent's own door, in code you can open.

Model: `SZCore/Agents/SZAgentGraph.swift` (+ `SZAgentGraphRun.swift`, `SZSeatAssignment.swift`).
Facts: `SZCore/Agents/` (`SZFacts.swift` is the spec, `SZWorld.swift` the host
projection). Supervision: `SZCore/Supervision/SZDispatchSupervisor.swift`. Loader +
validation: `SZAI/Agents/SZAgentPackLoader.swift`. Engine: `SZAI/Engine/SZGraphEngine.swift`
(+ `SZBriefRenderer.swift`, `SZQueryService.swift`). Delivery: `SZApp/SZDelivery.swift` +
`SZHost+Run.swift` / `SZHost+Mailbox.swift`. Step runtime: `SZRuntime/Steps/`. Shipped
packs: `SZAI/Resources/Agents/`. Tutorial: [AUTHORING.md](AUTHORING.md).

## A message is words; structure is world state

A message carries prose and nothing else. Everything structural lives in the **world** —
state that is true between messages, minted by the host, read by steps and briefs:

| world state | true while | minted by |
|---|---|---|
| `run` | a granted build is live — its work set, round, retry cap, steers, standing instruction, and its intent (`convert` for the run a target switch mints; nil for a build) | admitting a scheduled task |
| `pendingTasks` | always — the asks scheduled and not yet started | the Build press, `ui_run`, or the door's `requestBuild` effect |
| `runningTasks` | always — the asks being built right now | admitting a scheduled task |
| `assignment` | work stands assigned to this scope — the attempt, the sender's note | a dispatch node's fleet delivery |
| `graph`, `statuses` | always — the live project document and the agents' reported statuses | the app |
| `node`, `resuming` | the delivery's binding: which node it is about, whether the scope's session is one the graph's resume turns would actually continue under the delivery's routes | the delivering host |

New machinery never grows a message: it mints world state and knocks. The rule that keeps
the spec honest: **every fact names its shipped consumer** (a step predicate or a brief
token) — a fact nothing reads is deleted, not kept warm.

**One message is one traversal.** Nothing re-enters a graph: a dispatch waits for its
fleet and settles onward over its own edge, so the whole journey from delivery to
conclusion is a single connected traversal — and the RUNS list maps one row to one message
received.

**Vocabulary.** A **task** is the scheduled unit of intent — what was asked, over which nodes;
it is *scheduled*, and produces one run when admitted. A build is a **thread**: the build
traversal and the work children it dispatched, sharing the build record's own id. A **turn** is
one agent running because a turn node asked — the unit that spends model time.
Turn ⊂ traversal ⊂ thread, and one admitted task ↔ one thread.

## One folder per agent

```
Resources/Agents/<id>/
  agent.json        identity and seat — nothing else
  graph.json        THE graph — one per agent, so it carries no name
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

Seats resolve over the loaded library: exactly one holder each, checked at validation. A
dispatch names a seat, never an agent id — replace a folder and whoever now holds the seat
receives the work.

## The graph: three node forms, and the door is a step

```jsonc
{
  "label": "Director",         // display name (optional)
  "hint": "…",                 // subtitle (optional)
  "nodes": [ { "id": "door", "title": "On message", "step": "door" }, … ],
  "edges": [ { "from": "door", "outcome": "build", "to": "decompose" }, … ]
}
```

A node takes **exactly one of three forms** — enforced at decode:

| form | body | outcomes |
|---|---|---|
| `"step": "<folder>"` | the compiled `Step.swift` in the agent's pack | whatever the step's own exported declaration names |
| `"turn": { "brief", "session"?, "tools"?, "slot"?, "context"? }` | a full agent turn; the mustache brief (named by stem) IS the body. `"context": "conversation"` puts the scope's prior conversation above a spawned turn's brief (a resumed session already holds it, so the pair is shape-gated); the recap keeps the user's opening message plus a bounded tail (last 20 messages, about 8,000 characters) | fixed `ok` / `error` — process truth only, content never routes |
| `"dispatch": { "to" }` | fan the run's work set out to a seat — and **wait for the set** | `settled`, when the last lands (or the watchdog synthesizes the stragglers) |

**Model slots** are the graph's declared kinds of model work — what a routing profile fills
with models ([AI_PROVIDERS.md](AI_PROVIDERS.md#model-routing)). The graph opens with
`"slots": [{ "id", "label"?, "description" }]` (ids lowercase `[a-z0-9-]`, declaration order
= the settings pane's row order, `description` is the pane's caption — the author's own
words); a turn node names its slot via `"slot"`, a step node's asks name theirs via `"ask"`
(with the graph-level `"asks"` as the fallback for steps that name none), and a pack that
receives dispatches maps the Director's task grades to slots via
`"grades": { "light", "standard", "heavy" }`. Every reference must land on a declaration
(shape-gated); an unfilled slot simply runs the app default.

A pack may also ship **recommended routes**: an optional `routing.json` beside `agent.json`,
shape `{ "<slot id>": { "providerID", "model"?, "reasoningEffort"?, "fastMode"? } }`, slot
ids from the pack's own graph (an undeclared id is a pack defect; an uninstalled provider is
not — the user may lack it, and live resolution narrates that). It is a recommendation, not
a route: it applies only when the user clicks the agent card's "Use Recommended Models" in
AI Settings → Routing, merging into the profile being edited.

**The door is the step node with the reserved id `door`** — every delivery enters there,
and it must be a step: the agent's routing intelligence is code the author opens, reads,
and replaces. It examines the message's words and the world's state and answers an outcome
like any step; nothing routes *into* it. The shipped director's door, whole:

```swift
// director/steps/door/Step.swift
struct Ruling: Codable { let outcome: String }

let step = SZStep(outcomes: ["build", "convert", "answer", "answer-resumed", "implement", "amend"]) { ctx in
    if ctx.run?.intent == "convert" { return "convert" }   // a target switch's run: dispatched as it stands
    if ctx.run != nil { return "build" }        // a granted build arrives PRE-RULED
    let ruling = try await ctx.ask("triage", as: Ruling.self)
    if ruling.outcome == "amend",
       !ctx.pendingTasks.isEmpty || !ctx.runningTasks.isEmpty { return "amend" }
    if ruling.outcome == "implement" || ruling.outcome == "amend" {
        return .outcome("implement", effects: [.requestBuild])   // the task is the reply
    }
    return ctx.resuming ? "answer-resumed" : "answer"
}
```

Every line is a real decision: a grant goes straight to work (re-triaging it would spend a
token to maybe drop a build), and a conversion run takes the `convert` lane before the build
ruling: its work set is every built node with no source for the platform the project just
switched to, and the convert turn dispatches them as they stand, contracts and wires kept, no
redesign (a node the platform cannot serve comes back `needsInput`, which is the right answer,
not a retry). Prose is triaged by the model, an `implement` ruling schedules
the task, and an `amend` ruling only stands when there is something scheduled to fold into —
otherwise the ask is a fresh one, because routing a hallucinated amend would reach a turn with
no work to do. Amending is a TURN (`ui_amend_task` / `ui_cancel_task`), not an effect: naming
*which* task needs an argument, and deciding which is judgement. The coding agent's whole decision surface is one file, same shape:
assigned work is deterministic (a retry continues the node's session), and the user's
prose is judged by its own pack-local `triage` ask — a change request takes the `edit`
lane (a work order re-grounded on the node's live files), a question stays conversation:

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

**A dispatch waits.** The traversal holds at the node while the fleet works — the card is
live, its sub-agent lanes ticking under it — and when the set closes it produces `settled`
and routes its one edge. No edge = settlement ends the run. A settled edge that loops back
is the RETRY ROUND, and it must carry a `maxTraversals` leash — the same bound every other
loop speaks; an unleashed settled loop is refused at load like any unbounded cycle. The
leash IS the retry budget (the reconcile brief's `{{cap}}` reads it off the graph).

`session` on a turn: `spawn` (default) cold-starts; `resume` continues the scope's
existing session (spawning when none exists). A resume whose route lands on another provider
than the session's cold-starts, since a session id cannot cross CLIs. `tools` narrows the
turn's tool surface; `[]` means no MCP server at all.

Edges are `{ from, outcome, to, maxTraversals? }`. An outcome with **no edge ends the
traversal** — that is not an error; it is how a gate's `no` ends a run. A cycle is legal
only across a `maxTraversals`-bounded edge.

## Steps: one construct, one context, one capability

A step folder holds one file, and there is one way to write a step:

```swift
let step = SZStep(outcomes: ["yes", "no"]) { $0.hasWorkLeft ? "yes" : "no" }
```

`ctx` is the delivery's facts plus one capability, exhaustively: `message` (the words),
`node`, `resuming`, `run`, `assignment`, `hasWorkLeft`, and `ask`. The host compiles the
file beside an **assembled kit** (`SZRuntime/Steps/SZStepKit.swift`, step ABI v5) whose
middle section is the facts spec itself, so both sides of the ABI decode the same wire
shape and spellings like `hasWorkLeft` exist exactly once. The compiled module **exports
its declaration** (its outcomes); the pack gate reads it to validate every outcome-labeled
edge. A step body may `await`; it cannot mutate the host.

### ask and the repair loop

The kit's one capability beyond facts: a step may ask one model question.

```swift
try await ctx.ask("triage", as: Ruling.self)
```

The host renders the named pack template (`prompts/triage.md.mustache`) against the SAME
snapshot the evaluation holds, runs one stateless completion, and decodes the reply into
the requested type — tolerantly (the first balanced JSON object in a fenced or
prose-wrapped reply counts). On a shape mismatch the host is asked again with the decode
error and the previous reply attached, up to `retries` more times, then the step throws
honestly. The step never names a model — routing is the host's.

### Effects

A step answers with an outcome, and may ask for a typed host ACTION alongside it:

```swift
return .outcome("implement", effects: [.requestBuild])
```

The set is `SZEffect` in the facts spec — one case today, because one has a live
consumer: `requestBuild` SCHEDULES A TASK with the delivered message as its standing
instruction. A plain string enum by grammar, so an effect can never carry an argument;
anything needing one is a turn with a tool. Effects are performed after the step returns and before its edge routes.

## Facts: one spec, compiled twice

`SZCore/Agents/SZFacts.swift` is the single spec of everything a step can read:
`SZFacts` (the wire document — message, node, resuming, and the typed optional groups
`SZRun` / `SZAssignment`) and `SZEffect`. The SZFactGen build-tool plugin splices the
sentinel-marked region verbatim into the step kit, so a step compiles against the very
source the app compiled. **Adding a fact is two edits**: the documented `public var` line
in the spec (its doc comment must name the consumer), and the projection in `SZWorld` —
which also carries the host-side-only values (the typed project graph, the statuses) that
feed brief rendering and never cross the ABI.

## Briefs: one token table

A turn's brief is a mustache template; the prompt assembler (`SZBriefRenderer`) computes
exactly the `{{tokens}}` the template mentions from `(message, world, extras)` and
substitutes them. There is ONE token table — every token has one meaning (`{{node}}` is
the node this delivery is about; `{{boundary}}` is the contract to honor, from a staged
op's bundle when one is present, else from the graph) — and two guarantees: an unknown
token is refused at load, and rendered output with any live `{{token}}` left throws
rather than ship a literal to a model. Briefs are read from disk per render, so a saved
edit reaches the very next turn.

## The pack gate

Loading collects defects, never first-errors: one unreadable pack reports while its
siblings load. Validation covers the library as a whole: seats (exactly one holder each),
one `graph.json` per agent, graph shape (duplicate ids, dangling/duplicate edges,
undeclared outcomes, unbounded cycles, the door's existence and step-ness, reachability
from the door), turn briefs (the template exists; every token is in the table; every
partial a token renders from ships in the pack), dispatch seats, and — through the step
seam — each compiled step's declared outcomes, the door included. With no step provider
those checks are **skipped and the report says so**.

What a code door makes honest: whether a brief's tokens fit the messages that will
actually arrive is *not statically knowable* — that check runs at render, loudly, into
the traversal's trace.

`debug_check_pack` runs the same load + validation as a pre-flight, without spending a
token, and renders the report: each agent's surface (its door's declared outcomes lead
the graph line), the sorted defects, and a verdict — `does not load`, `loads, does not
validate`, or `validates`.

## The runtime: one delivery, no orchestrator

Every message is delivered the same way: the host builds one **`SZDelivery`** — the
message's words, a live world projection for the delivery's binding, the turn transport,
and (for a build) the fleet seam — and the engine runs the agent's graph against it.

- **Prose** is queued in the mailbox and pumped when the recipient's resources free.
  Consecutive queued messages from the same sender to one recipient **fold into one
  delivery** (`SZMessageQueue.fold`), so three clarifications typed in a row are one turn that
  answers all three rather than three turns each blind to the next.
- **A task** is scheduled by the Build press, `ui_run`, or the door's `requestBuild` effect,
  and admitted at the head of the next pump pass — ahead of any queued prose — the moment the
  work it needs is free. A second ask is queued, never dropped.
- **A build** is one traversal: admitting the task mints the run (work set, instruction,
  claims), and the director's engine runs from door to conclusion, holding at the
  dispatch while the fleet works. **Runs whose work sets are disjoint run at the same time**;
  the Director transcript is claimed per TURN, so their decompose turns take it in turn.
- **Work children** are not queued: the waiting dispatch delivers them directly as child
  traversals under the run's own claim — same engine, same seam, same record shape.

The fleet is supervised by **`SZDispatchSupervisor`** (one pure value machine; tests
drive it with event lists): one open set at a time, exactly one settled summary per set
(collected, or synthesized by the per-set watchdog with stragglers cancelled first and
marked `timedOut`), attempts accumulate per item across sets, steers queue and fold into
the next brief render, and stop is absorbing — a stopped set ships no summary; the
traversal concludes `cancelled`.

## Hot reload and the source pills

Bundled resources are sealed inside a signed .app, so at start the host **materializes**
the pack tree into `~/Library/Application Support/SubjectiveZero/agents/<id>/` — the writable
copy everything reads, one per app so two builds can never drag one copy back and forth
(`SZ_AGENT_PACKS` overrides the root wholesale, and is then only read). Ours-or-theirs is
decided by content: a manifest beside the root hashes every byte the host wrote, so an
unedited copy follows the bundle in either direction (update or downgrade) while a file
you edited stays yours. Prompts need no
watcher — briefs are read per render. Step sources are compiled code, so each
`steps/<name>/Step.swift` is watched: save → recompile → swap on green, keep the old
module on red. In the Agent Graph panel every card carries its **source pill**: a step —
the door included — opens its `Step.swift`, and a dispatch links into the target seat's graph.
A turn opens its brief, and which brief depends on what you are looking at. Browsing a
graph there is no run, so the pill opens the mustache **template**. On a RUN card whose visit
actually ran, it opens the **prompt that turn sent**, macros expanded: the visit's `turnID`
resolves the rendered text captured per turn (20 in memory, 40 on disk, pruned). Past those
caps, and on records written before the stamp existed, the template stands in.

## RUNS records and the panel

Every message an agent receives is ONE record, an `SZAgentGraphRun`: the ordered trace of
the whole journey (entry 1 is the door visit — its outcome says what arrived and how it
was ruled), and the conclusion. The record carries no kind: a build **leads its thread**
(its `thread` is its own id, shared by the work children it dispatched), a work child
carries the node it served, a conversation stands alone. A build's leader also carries the
ask it was scheduled under (`title`); the RUNS list and the chat name the build by it, through
one rule (`SZBuildName`). A build's record stays LIVE for
its whole run — fleets included — sealing only when the story actually ends. Live records
exist only in memory; sealed records persist into the project's `runs.json`, capped per
budget (thread leaders and the rest separately), never evicting a live record.

The list names the **agent**, with the door's ruling on the line below. On the canvas, a
dispatch card carries a band of its sub-agents: one lane per work child, each naming the
node that agent is on right now, its running clock, and a pulsing `live` badge — swapped
for a conclusion badge as each settles.

A **turn card opens its own activity**: the chevron beside the clock unfolds what that agent
said on that visit — its tool calls as steps, its reasoning between them, then its reply.
Closed by default, session-only, reset by switching run (ordinals are per record). Only a
visit that ran a turn offers it: `Entry.turnID` names the transcript message the turn streamed
into, and the host reports that id (with the envelope the router picked) the moment the message
opens, so the band follows a turn as it works rather than appearing once it is over.

The **footer runs two lines**: the wall time with the spend beside it
(`2m 45s · tok 230.9k in / 13.1k out`), then the envelope receipt on its own
(`claude · claude-opus-5 · high`), indented to share the clock's left edge. The receipt takes a
line because beside the clock it truncated to "cla…opus-5", hiding the model it names. Both
lines are reserved by FORM — every turn card has them — never by whether the numbers have
arrived, so a card cannot resize under the pointer mid-turn.

The band is a FIXED height that scrolls inside itself and grows the card DOWNWARD from its
closed frame, so streaming text neither resizes its own card nor moves the ports and wires you
read it against. The forecast and the follow-cam measure against the CLOSED frame for the same
reason. The band reads the transcript itself, never the canvas: reading it higher up would
re-render the whole canvas at streaming cadence.

## Termination

Two vocabularies, deliberately: **outcomes route** (the graph's open set — an outcome
with no edge ends the traversal), **conclusions end** (the closed set, exactly one per
traversal: `ended`, `failed`, `cancelled`, `declined` — a refusal is never a failure —
and `defect`, the traversal's own integrity breaking, which validation makes unreachable
for shipped packs). **Sessions survive every ending**: the one session store keeps each
scope's agent session across traversals, a retry resumes it when the session still
continues under the delivery's routes (else it starts over on the blocker),
and a fresh run's first dispatch still cold-starts by design. Pins persist by lane: a chat
turn pins on resume or when the slot is empty, a run's Director turn pins on the run only,
and a run's coding turn always pins.
