# Agent Orchestration

**Package: SZAI.** How the host orchestrates agents, behind the `Orchestrator` seam defined in
`SZCore` ([ARCHITECTURE.md](ARCHITECTURE.md#the-host-seam)). Agents act on the app only through the
host's MCP server ([MCP.md](MCP.md)).

> **Status - the behavior-tree formalism is provisional (V1 uses hardcoded Swift).**
> The declarative **behavior tree / state machine in JSON** described below is the *intended target*,
> but it is the one genuinely **unproven, loosely-defined** part of the design. So **V1 implements
> the orchestration in plain Swift** behind the `Orchestrator` interface (a proven
> `contract-plan → parallel coding → reconcile` strategy). The BT engine is **prototyped before it is
> specced or built**; nothing in the build spec freezes a BT JSON schema yet. Read the JSON trees
> below as **illustrations of intended behavior**, not a committed format.
>
> Orchestration is a **pluggable strategy** behind an `SZOrchestrating` seam (in
> `SZAI/Orchestration/`), **toggled by a debug setting**. V1 ships **two** editable strategies: a
> **procedural, flow-aware** one (deterministic / offline - the baseline + CI path) and an **LLM
> Director** one (plain Swift + LLM calls, fed the flow-drafted graph as context). Both are
> **contract-first** - the Director/host declares + pins each node's typed I/O upfront (reusing the
> M6/M7b `pinnedContracts` machinery) so the graph "comes to life" with visible I/O before the
> coding agents fill the source. The Director may split/merge but it's **gated in Swift** (the
> BT-as-files engine that would make this authorable stays deferred).

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

## Message routing (the run-UX paradigm)

- Every USER send resolves its recipient through **`SZChatRouting.resolveRecipient`** (SZCore) -
  THE one-function routing-policy seam. V1 policy: a message that LEADS with a mention goes to
  that entity's agent (`@<node>` → its Coding Agent DIRECT - no relay turn in the tight
  iterate-on-a-node loop; `@project` / `@all` → the Director Agent); no leading mention → the
  composing tab's agent. Non-leading mentions are REFERENCES, expanded for the recipient
  (`SZMentionExpansion`: inline `@display` + a manifest of uuid + live title; `@all` enumerates
  the node snapshot). A message is never duplicated to multiple Coding Agents - multi-node asks
  lead with `@project` and the Director reroutes via `ui_send_chat`. Swapping the policy (or
  making it data - the future behavior-tree seam) is an edit to that one function.
- **The Director Agent's chat turn IS the decompose turn.** A fresh Director chat is framed by
  `director/chat.md.mustache` (persona + live graph + the shared `director/toolbelt.md.mustache`
  every Director framing injects as `{{toolbelt}}`). When implementation should proceed it calls
  `ui_run { instruction }` - called from its OWN streaming turn the run is QUEUED
  (`SZHost.pendingDirectorRun`) and starts at turn end (starting mid-turn would race the same
  transcript), with `directorAlreadyBriefed` so the agentic strategy skips its decompose turn
  (one Director turn per message-triggered run). The reconcile loop still catches under-shaped
  dispatches.

## Cross-agent messaging

- Director Agent → a node's Coding Agent DURING a run: `ui_send_chat` is recorded
  (`pendingDirectorMessages`, keyed by node) and folded into the node's reconcile retry - never a
  nested turn inside a synchronous MCP handler. The note also lands in the node's transcript as a
  `.director`-role message (and marks the tab unread).
- A coding agent reports back via `agent_report_status`; the reconcile loop reads those statuses.
- **Deferred (seams earned):** the per-scope async mailbox for MID-RUN USER messaging - user
  sends are refused while a run is in flight (the composer disables send with the reason and
  keeps the draft); the mailbox would ride the same recorded-delivery lane when it lands.

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
