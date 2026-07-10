# Core Loop

This is the product. Every other doc exists to make this loop solid and fast. It describes the
canonical user journey and the system sequence behind it. If a feature doesn't serve this loop,
it's deferred.

## The journey, from the user's seat

1. **Draft.** The user drops a few **prompt nodes** onto the canvas and connects them with
   **flow** connections. A prompt node is just an intent in natural language - e.g. *"Make the
   MacBook camera grayscale."*
2. **Run the Director Agent.** The user clicks *Run* (or messages the Director Agent in chat). The Director Agent
   reads the graph and produces a plan: which nodes are needed, their rough contracts, and the
   order of work.
3. **Watch it take shape.** The Director Agent dispatches a **coding agent per node**. As each agent
   drafts its node's contract, the node's UI fills in - a real **title**, an **SF Symbol**, and
   the granular **typed inputs/outputs** appear, with default-value controls for unconnected
   inputs.
4. **See it run.** Nodes compile and hot-reload; the live result renders in the Metal viewport.
   The user can flip the **display** toggle on any texture output to send it to the viewport.
5. **Iterate.** The user refines by any mix of:
   - **Chatting with the Director Agent** ("make it higher contrast", "add a bloom pass").
   - **Chatting with a single node's coding agent** to tweak just that node.
   - **Drawing/removing connections** manually.
   - **Split/merge** to change the granularity of the graph (below).

## System sequence

Roles: **User**, **SZUI**, **Host** (in SZApp), **Director Agent** & **Coding Agents** (SZAI, via
**MCP**), **SZCore** (state), **SZRuntime** (compile + render).

```
User → SZUI:        draft prompt nodes + flow connections
SZUI → Host:        apply graph edits (commands)
Host → SZCore:      commit transaction (undoable)

User → SZUI:        Run
SZUI → Host:        start Director Agent with current graph
Host → SZAI:        spawn Director Agent (Orchestrator begins; hardcoded Swift in V1)

Director Agent → MCP:     read graph state
Director Agent → MCP:     create/assign nodes; spawn Coding Agent per node (contract + prompt)

loop per Coding Agent:
  CodingAgent → MCP:   query node library (index → card → source, as needed)
  CodingAgent →    :   draft node-contract.json + Node.swift (staged)
  CodingAgent → MCP:   ui_update_node (title, SF Symbol, inputs, outputs)
  Host → SZRuntime:    compile staged source (swiftc), hot-reload module
  CodingAgent → MCP:   report status (ok / needs-input / failed)

Host → SZRuntime:   schedule DAG, execute per frame
SZRuntime → SZUI:   live render in ViewportPanel

Director Agent → MCP:     reconcile results; report plan complete

User → SZUI/chat:   iterate (chat Director Agent or node agent, edit connections, split/merge)
```

The **MCP surface mirrors the UI 1:1** (see [MCP.md](MCP.md)), so this exact sequence can be
driven headlessly for automated, closed-loop testing while agents build.

## Node UI reflow

The "node takes shape" moment is central, so it's worth pinning down. A node's UI is derived
**entirely from its `node-contract.json`** ([GRAPH_AND_NODES.md](GRAPH_AND_NODES.md)):

- **Pre-gen (prompt node):** shows the prompt text and a busy/pending state. No typed ports yet.
- **Drafting:** when a coding agent calls `ui_update_node` with a contract, the editor animates
  in the title, SF Symbol, and one port per declared input/output. Unconnected inputs that have
  a compatible control render that control with a default value (slider, toggle, dropdown, …).
- **Post-gen (generated node):** fully reflects the contract; outputs that are textures show a
  **display** toggle.

Because the UI is a pure function of state, reflow is just a state update + re-render - no
bespoke animation logic per node type.

## Split / merge

A flagship capability for shaping granularity without making effects black-boxy. **V1 is
user-initiated**; the model is designed so the Director Agent could trigger it later with no redesign.

**Split** - turn one node into a pipeline.
- Example: *"Make the MacBook camera grayscale"* → **"MacBook Camera"** → **"Make Grayscale"**.
- The user selects a node and chooses *Split*. The host applies **one atomic graph transaction**:
  it creates the new nodes, rewires flow so the upstream/downstream connections still make sense,
  and writes draft contracts for the pieces.
- Affected nodes are then handed to coding agents to (re)implement against their new contracts.

**Merge** - collapse a pipeline into one node (the reverse).
- Example: **"MacBook Camera"** → **"Make Grayscale"** ⇒ *"Grayscale MacBook camera"*.
- The user selects adjacent nodes and chooses *Merge*. The host applies one atomic transaction
  that removes the constituent nodes, creates the merged node, and rewires external connections;
  a coding agent implements the merged node.

Both are **single transactions** so undo/redo treats a split or merge as one step
([STATE.md](STATE.md)). Because graph mutation is host-owned, agents never restructure the graph
by writing files - they propose or implement, the host commits.

## What this loop intentionally excludes (V1)

- Agent-initiated split/merge (deferred; the model already supports it).
- Provider marketplace / polished setup; cross-platform runtime; deep telemetry; memory agent.
- Anything that doesn't help reach *draft → run → see it render → iterate*.
