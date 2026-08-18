# Agent Orchestration

**Package: SZAI.** How the host orchestrates agents, behind the `Orchestrator` seam defined in
`SZCore` ([ARCHITECTURE.md](ARCHITECTURE.md#the-host-seam)). Agents act on the app only through the
host's MCP server ([MCP.md](MCP.md)).

> **Status — orchestration is now AUTHORED, and its spec is
> [AGENT_GRAPHS.md](AGENT_GRAPHS.md).**
> The strategies this document once described — a procedural one and an LLM Director one,
> selected by a debug toggle behind `SZOrchestrating` — are **deleted**. A run is a
> traversal of an agent's declared graph: JSON topology wiring runtime-compiled Swift
> steps, with prose in `.md.mustache` briefs. The words *procedural* and *agentic* survive
> as two of the shipped **strategy ports** the director's build lane routes on, not as
> strategies in Swift.
>
> What remains true here, and what the source headers cite this file for: the **roles**
> (Director and Coding agents), **cross-agent messaging**, how work is **routed**, and the
> **task** vocabulary. Read the JSON trees below as history — the authored format that replaced
> them is specced in AGENT_GRAPHS.md, and the authoring loop in
> [AUTHORING.md](AUTHORING.md).
>
> Still true of both eras: orchestration is **contract-first** — the Director declares each
> node's typed I/O upfront (and a promote MERGES the agent's authored contract into that
> live boundary rather than replacing either side), so the graph "comes to life" with
> visible I/O before the coding agents fill the source.

## Roles

- **Director Agent** - coordinates the project from a high level. Reads the graph, plans, dispatches
  and messages coding agents, waits on their results, and reconciles. (Working name; replaces the
  earlier "Project Agent".)
- **Coding Agent** - one per graph node. Receives an API contract + prompt, implements the node
  (`node-contract.json` + `Node.swift`), drives its node's UI via MCP, and reports status. The
  user can chat with it directly to iterate on just that node.

Agents act on the app **only through MCP** ([MCP.md](MCP.md)) - there is no privileged back
channel. The host owns graph mutations and the build; agents propose and implement.

## Behavior tree model

A node in an agent's tree is one of:

- **Message node** - a prompt sent to the agent (LLM). It may:
  - be a hardcoded string, or a template with **mustache** variables the host populates
    (e.g. `{{node.title}}`, `{{contract}}`, `{{user_message}}`);
  - request a **specific response format** (e.g. answer a yes/no, or emit JSON to parse);
  - come from the host, from the **user** (a chat message), or from **another agent**;
  - optionally **wait for completion** before the tree advances.
- **Tool-call node** - the host runs code on the agent's behalf: compile with swiftc, read/write
  state via MCP, check a condition (e.g. "is this a new node?"), query the node library, etc.

**Transitions** between nodes are gated by **conditionals** (the state-machine part). A tree can
also **send a message to another agent** and optionally await it - e.g. the Director Agent messages a
coding agent and waits for `status == ok` before continuing.

### Why a tree (and not just a loop)

It makes the agent's intended behavior explicit and debuggable, lets us template prompts
consistently, and lets the Director Agent coordinate many coding agents with clear wait/reconcile
points instead of ad-hoc orchestration code.

## Director Agent tree - worked example

*(Illustrative of intended behavior - the JSON format is provisional; V1 implements this flow in Swift.)*

Goal: turn a drafted prompt graph into implemented, rendering nodes.

```jsonc
{
  "agent": "director",
  "root": "read_graph",
  "nodes": {
    "read_graph": {
      "type": "tool", "tool": "agent_read_graph",
      "next": "plan"
    },
    "plan": {
      "type": "message",
      // `order` is derived from the graph's FLOW edges - the only who-feeds-whom signal before
      // contracts/data edges exist. This full LLM Director (plan/decompose/flow-ordered dispatch/
      // reconcile) is unbuilt: V1 uses the hardcoded Swift SZOrchestrator; it lands at M7.
      "prompt": "You are the Director Agent. Given this graph:\n{{graph}}\nProduce a plan: for each prompt node, a draft contract (title, sfSymbol, typed inputs/outputs) and the implementation order. Respond as JSON: { \"nodes\": [...], \"order\": [...] }.",
      "responseFormat": "json", "await": true,
      "next": "create_nodes"
    },
    "create_nodes": {
      "type": "tool", "tool": "agent_apply_plan",   // host creates/assigns nodes (one transaction)
      "next": "dispatch"
    },
    "dispatch": {
      "type": "tool", "tool": "agent_spawn_coding_agents",  // one per node, with contract + prompt
      "next": "await_nodes"
    },
    "await_nodes": {
      "type": "tool", "tool": "agent_await_all",     // blocks until each coding agent reports terminal status
      "next": "reconcile?"
    },
    "reconcile?": {
      "type": "conditional",
      "cond": "any(node.status == 'failed' || node.status == 'needs-input')",
      "ifTrue": "reconcile", "ifFalse": "done"
    },
    "reconcile": {
      "type": "message",
      "prompt": "These nodes did not complete cleanly:\n{{failed_nodes}}\nDecide for each: re-prompt the coding agent (give a refined prompt), adjust the contract, or ask the user. Respond as JSON.",
      "responseFormat": "json", "await": true,
      "next": "dispatch"     // loop back to re-dispatch affected nodes
    },
    "done": { "type": "tool", "tool": "agent_report_complete" }
  }
}
```

When the user chats with the Director Agent mid-run, the message arrives as a `message` node input
(`{{user_message}}`) that can re-enter `plan`/`reconcile` - iteration is just more tree traversal.

## Coding Agent tree - worked example

*(Illustrative of intended behavior - the JSON format is provisional; V1 implements this flow in Swift.)*

Goal: implement one node against the contract the Director Agent assigned.

```jsonc
{
  "agent": "coding",
  "root": "inspect",
  "nodes": {
    "inspect": {
      "type": "tool", "tool": "agent_read_node",     // {{node}}, {{contract}}, {{prompt}}
      "next": "library_scan"
    },
    "library_scan": {
      "type": "tool", "tool": "agent_library_index",  // cheap Tier-1 index (see NODE_LIBRARY.md)
      "next": "choose_reference"
    },
    "choose_reference": {
      "type": "message",
      "prompt": "Implement: {{prompt}}\nContract: {{contract}}\nLibrary index:\n{{library_index}}\nPick the single best reference node, or none. If you pick one, say whether it is usable as-is (reuse=copy-as-is) or reference-only. Respond as JSON: { \"ref\": \"<id|null>\", \"mode\": \"copy|reference|none\" }.",
      "responseFormat": "json", "await": true,
      "next": "fetch_reference?"
    },
    "fetch_reference?": {
      "type": "conditional", "cond": "ref != null",
      "ifTrue": "fetch_reference", "ifFalse": "implement"
    },
    "fetch_reference": {
      "type": "tool", "tool": "agent_library_source",  // Tier-3: full Node.swift for the chosen ref only
      "next": "implement"
    },
    "implement": {
      "type": "message",
      "prompt": "Write node-contract.json and Node.swift conforming to the SZNode ABI. {{#reference}}Reference (mode={{mode}}):\n{{reference_source}}{{/reference}}\nFinalize the contract (title, sfSymbol, typed inputs/outputs).",
      "await": true,
      "next": "write"
    },
    "write": {
      "type": "tool", "tool": "agent_write_node_staged",  // stage contract + source
      "next": "update_ui"
    },
    "update_ui": {
      "type": "tool", "tool": "ui_update_node",           // title, sfSymbol, typed ports reflow
      "next": "compile"
    },
    "compile": {
      "type": "tool", "tool": "agent_compile_node",       // host runs swiftc on staged source
      "next": "compiled?"
    },
    "compiled?": {
      "type": "conditional", "cond": "build.ok",
      "ifTrue": "report_ok", "ifFalse": "fix"
    },
    "fix": {
      "type": "message",
      "prompt": "The build failed:\n{{build.errors}}\nFix Node.swift.",
      "await": true, "next": "write"
    },
    "report_ok": { "type": "tool", "tool": "agent_report_status", "args": { "status": "ok" } }
  }
}
```

A user chatting with a single node's agent enters at a `message` node with `{{user_message}}`,
loops through `implement → write → compile`, and re-reports - iterating just that node without
involving the Director Agent.

## Message routing

- **Every user message goes to the Director's door**, which triages it.
  `SZChatRouting.resolveRecipient` (SZCore) is still THE one routing-policy seam, but it no
  longer takes an active scope and no longer has a direct-to-node lane: with the single chat
  panel there is no tab to address, and with tasks running concurrently a message that reached
  a Coding Agent without passing the Director could mutate a node a scheduled or live task
  holds. A **mention is a targeting HINT**, not an address — it stays in the words, and the
  triage reads it (`@Blur make it softer` is still unambiguous). Non-leading mentions are
  references, expanded for the recipient (`SZMentionExpansion`).
- **The door decides what the words mean** ([AGENT_GRAPHS.md](AGENT_GRAPHS.md)): answer, build,
  or fold into work already scheduled. An `implement` ruling carries the `requestBuild` effect,
  which SCHEDULES A TASK — the run is the reply. An `amend` ruling routes to a turn holding
  `ui_amend_task` / `ui_cancel_task`, because deciding *which* scheduled ask a follow-up belongs
  with is judgement, not a routing token.
- **A node question still reaches its agent**: the Director relays it with `ui_send_chat`, and
  the reply lands in the one feed attributed to that node.

## Tasks: what is scheduled, and what is running

A **task** is the scheduled unit of intent — instruction, work set, state (`SZTask`). A **run**
is one traversal of an agent graph, recorded (`SZAgentGraphRun`). A task is *scheduled*; a run is
*executed and recorded*; an admitted task produces exactly one thread-leading run.

- A second ask is **queued, never dropped**. `SZHost.pendingTasks` is the FIFO;
  `admitPendingTasks` runs at the head of every mailbox pump pass, so a task always beats queued
  prose to a freed resource.
- **Runs are scoped by their work set, not serialized.** A run claims its work set's node +
  transcript pairs through `SZResourceLedger`; disjoint runs are live together, overlapping ones
  wait on the holder. The Director transcript is claimed **per turn**, not per run, so two runs'
  decompose turns serialize while their fleets do not.
- `workSetCandidates` is the single home of "what would a new run take": dirty, minus
  undescribed, minus what another run already holds.
- Pending tasks persist to `.subz/.staging/tasks.json` (`SZTaskQueueIO`) — under staging because
  a task spends tokens when it starts. A RUNNING task is never restored.

## Cross-agent messaging

- Director Agent → a node's Coding Agent DURING a run: `ui_send_chat` is recorded as a `.steer`
  envelope and folded into that node's reconcile retry — never a nested turn inside a synchronous
  MCP handler. The note also lands in the node's transcript as a `.director`-role message.
- A coding agent reports back via `agent_report_status`; the reconcile loop reads those statuses,
  and its messages to the Director are rendered into the reconcile prompt's `{{inbox}}`.
- **A mid-run user message is a steer; a message about work not yet started is an amend.** Both
  mechanisms already exist — the door picks which by whether the task has been admitted.

## Failure recovery

- Build failures loop the coding agent through `fix` with the compiler errors templated in.
- A coding agent that can't proceed reports `needs-input`; the Director Agent's `reconcile` decides to
  re-prompt, adjust the contract, or ask the user.
- The host caps retries; exhausted nodes surface to the user with their logs.

## Test scenarios

- A two-prompt-node graph: Director Agent plans, spawns two coding agents, both report `ok`, viewport
  renders - no human input.
- A coding agent picks a `reference-only` library node, writes original source (not a copy), and
  compiles.
- Injecting a build error sends the coding agent through `fix` and it recovers.
- A user chat message to one node's agent re-implements only that node.
