# Architecture

The spine doc. It defines the package boundaries, who owns what, and how a single turn of the
[core loop](CORE_LOOP.md) flows through the system.

## Goals

- **Small but modular.** Few packages, clear seams, so an agent (or a human) can work on one
  concern without loading the whole codebase.
- **Native macOS, no WebView.** SwiftUI + AppKit for UI, Metal for rendering.
- **Host-owned everything risky.** Agents reason and write source; the host owns Metal
  resources, graph mutations, the build, and scheduling. Agents never touch the GPU or mutate
  state directly - they go through MCP.
- **Portable state, native code.** `SZCore` is plain serializable model + JSON; the rest is
  macOS-specific.

## Packages

```
                 ┌─────────┐
                 │  SZApp  │   macOS app bundle (window, lifecycle, hosts runtime)
                 └────┬────┘
        ┌─────────────┼─────────────┬──────────────┐
        ▼             ▼             ▼              ▼
   ┌─────────┐   ┌─────────┐   ┌──────────┐   ┌────────┐
   │  SZUI   │   │  SZAI   │   │SZRuntime │   │ (links │
   └────┬────┘   └────┬────┘   └────┬─────┘   │  all)  │
        │             │             │          └────────┘
        └─────────────┴──────┬──────┘
                             ▼
                        ┌─────────┐
                        │ SZCore  │   shared state model + JSON serialization
                        └─────────┘
```

Dependency rule: **everything depends on `SZCore`; nothing depends on `SZApp`.** `SZApp` links
all packages and wires them together. `SZUI`, `SZAI`, and `SZRuntime` do not depend on each
other directly - they coordinate through `SZCore` (the shared **state model + seam protocols**) and
through the **host** (in `SZApp`), which is the only place that knows every concrete type. The host
is the composition root + router **and the run-lifecycle owner**: it wires the pieces, routes
intents into `SZCore` store ops or service calls, and owns the cross-package *procedures* no single
package can - staging→promote (incl. re-pinning each dirty node's typed boundary contract), the
split/merge deferred-commit, run state + post-run surfacing, and chat/agent-session bookkeeping
(see [Host seam](#the-host-seam) below). What it must NOT own: model semantics (SZCore), GPU/compile
(SZRuntime), agent reasoning/prompt content (SZAI), or rendering of state (SZUI).

| Package | Responsibility | Key contents |
|---|---|---|
| **SZApp** | The app bundle and the **host**: composition root that instantiates and injects the others, owns the window/run loop, implements `HostBridge`, and **hosts the MCP server** (the app's command bus). Also the **run-lifecycle owner**: staging→promote (contract pinning), split/merge deferred-commit, run + chat/agent-session state. | `App`, host coordinator (`SZHost` + `SZHost+*.swift` extensions), `MCPServer` + `MCP+*.swift`, window/scene setup, notarization/packaging config |
| **SZCore** | The canonical, portable model + its JSON serialization, **and the seam protocols** every cross-package interaction goes through. No macOS/Metal types. | `App`/`Project`/`Graph`/`Node` models, `node-contract.json` schema, observable `Store` + named edit ops, `SZNodeAgentState`, checkpoint undo (M8) |
| **SZAI** | Provider wrapping, agent runtime, orchestration, sessions, failure recovery. Implements `Orchestrator`; **does not** own the MCP server. | `DirectorAgent`, `CodingAgent`, `Orchestrator` impl (hardcoded Swift in V1, behavior-tree engine later), provider adapters (claude code, codex) |
| **SZRuntime** | Lightweight rendering engine. Owns Metal device/queue/resources, viewport context, permissions. Implements `NodeCompiler`/`Renderer`; compiles, schedules, executes the graph; hot reload. | `MTLDevice` ownership, resource/asset manager, DAG scheduler, swiftc build pipeline, node module loader |
| **SZUI** | Native panels. Binds to the `SZCore` `Store`; emits commands/intents. | ViewportPanel (MTKView in SwiftUI), Node Editor, Chat, HUD, Settings |

## The host seam

This is the spine that lets three sibling packages coordinate without depending on each other. It
is *forced* by the dependency rule: since `SZUI`/`SZAI`/`SZRuntime` may not import each other or
`SZApp`, the only shared vocabulary is `SZCore`. So `SZCore` carries the contracts, and `SZApp`
(the host) is the single place that knows the concrete types and wires them.

> **Boundaries vs. seams - "seams are earned, not scheduled" (build policy).** The clean module
> *boundary* is not created by protocols; it is enforced by the **package graph** - a target can't
> `import` a module it doesn't depend on, and the compiler rejects it. A *seam protocol* (in `SZCore`)
> is a *separate, optional* mechanism for two modules to collaborate across that boundary - but it is
> rarely the only way, because **`SZApp` (the host) imports every sibling concretely and can mediate
> with concrete types**. So a seam protocol is worth its indirection only when (a) there's a genuine
> *second implementation* to swap behind it, or (b) a cross-sibling call the host genuinely *can't*
> mediate with a concrete type or `SZStore`. We therefore **add a seam protocol the moment it is
> earned, not on a milestone schedule** (per [AGENTS.md](../AGENTS.md) guideline 3).
>
> Evidence: **M1 shipped its whole runtime + hot-reload + capture path with *zero* seam protocols.**
> The viewport gets frames from the runtime via a host-injected MetalKit `MTKViewDelegate` (not a
> protocol); the host calls the concrete `SZRuntime` directly. The two real cross-module needs are
> already covered without new protocols: **the package graph** (the boundary) and **`SZStore`** (the
> shared-state seam). The list below is *illustrative of shapes if/when earned* - several may never be
> needed; `SZNodeCompiler`/`SZRenderer` in particular proved unnecessary (the host holds the concrete
> runtime). Only `SZStore` exists today.

**`SZCore` owns the contracts.**

- An `@Observable` **`SZStore`** - the single source of truth and itself a protocol-free seam: UI
  binds to it; the runtime subscribes to it; the host mutates it. *(Exists from M0.)*
- The **named edit ops** (`SZStore+GraphEdits`) - every mutation funnels through the store's single
  `mutate` entry point as one atomic project reassignment, which is what makes observation uniform
  regardless of who acted (user, agent, or host). Undo lands at **M8** as artifact-level checkpoints
  over this same surface ([STATE.md](STATE.md)).
- **Seam protocols (candidates, added only when *earned* - not on a schedule).** Pure Swift, no
  macOS/Metal types. The host mediates most cross-module calls with concrete types, so these may never
  appear; each is added the day a real swap or un-mediatable call shows up:
  - `SZNodeCompiler` / `SZRenderer` - **not needed.** The host holds the concrete `SZRuntime` and calls
    `compile`/`renderFrame`/`captureFrame` directly; the viewport rides a MetalKit delegate. (M1 shipped without them.)
  - `SZHostBridge` - the strongest candidate: SZUI must call *into* the host without importing SZApp.
    Try `SZStore` + a host object injected via the SwiftUI environment first; add a protocol only if routing earns it. *(M3.)*
  - `SZOrchestrator` - justified **only by the M7 swap** (hardcoded Swift ↔ a behavior-tree engine). Add
    it the day the second implementation exists, not before. *(M3 uses the concrete SZAI; protocol earned at M7 if BT survives.)*
  - `SZProviderRegistry` - the host holds concrete SZAI; multi-provider abstraction (`SZProvider`) lives
    *inside* SZAI, not as a SZCore seam. Likely never a cross-module protocol.
- Metal/texture handles are **opaque ids** in `SZCore`; the concrete `MTLTexture` lives in `SZRuntime`.

**`SZApp` is the host: composition root + router + run-lifecycle owner.** It instantiates the
`Store` and the concrete implementations from `SZRuntime` and `SZAI` (orchestration strategies,
providers), injects them, owns the run loop, and **hosts the MCP server**. It implements
`HostBridge`: every `ui_`/`agent_` MCP command and every UI intent lands here and becomes either a
`Store` edit op or a service call. Beyond routing, the host owns the procedures that *span* the
packages - promote a staged node (re-pinning its typed boundary), commit/rollback a split/merge,
drive a run end-to-end (`startRun` → orchestration context → post-run surfacing), and track
per-node agent state (`SZNodeAgentState`) + chat sessions/tabs. That state is transient and
observable, never model truth - the model stays in `SZCore`.

**The MCP server lives in the host, not `SZAI`.** It is the app's **command bus** - a 1:1 mirror of UI
actions - so it belongs with the router that executes those actions. Agents reach the app through it;
`SZAI` only provides provider sessions and the `Orchestrator`. (This makes the MCP surface and the UI
share one execution path, which is what keeps headless agent-driven runs identical to user-driven ones.)

**One command, end to end:**

```
UI edit  ─┐
          ├─▶ Host (HostBridge) ─▶ SZCore: apply a named Store edit op    ─▶ Store notifies
agent MCP ┘                                                                    observers
                                                          ┌──────────────────────┴───────────┐
                                                          ▼                                   ▼
                                              SZUI re-renders (bound to Store)   SZRuntime recompiles/
                                                                                 reschedules affected node
                                                                                          ▼
                                                                                 new frame → ViewportPanel
```

## Ownership rules

These keep the system debuggable and prevent the drift that hurt earlier iterations.

- **The host (SZApp) owns graph mutations.** Adding/removing nodes, rewiring connections, and
  split/merge are applied as atomic store edit ops on `SZCore` state - never by an agent writing
  state files directly.
- **SZRuntime owns all GPU resources.** Nodes receive resources through the runtime context;
  they never create their own device/queue. Output textures live in the runtime's asset manager.
- **The host owns the MCP surface; SZAI owns agent lifecycle + orchestration.** Agents act on the app
  *only* through MCP commands routed by the host's `HostBridge`; there is no privileged back channel.
  SZAI provides provider sessions and the `Orchestrator`, never direct state writes.
- **SZCore owns the truth.** UI renders from state; agents read state via MCP; the runtime
  compiles from state. State changes flow through the store's named edit ops, the single surface
  M8's checkpoint undo snapshots.
- **Generated node source is isolated and inspectable.** Each node is its own `Node.swift` +
  `node-contract.json`; a failed build or agent run never corrupts the live project (staged
  writes, see [STATE.md](STATE.md) and [RUNTIME.md](RUNTIME.md)).

## The core loop, end to end

A single pass, naming who calls what. Full narrative in [CORE_LOOP.md](CORE_LOOP.md).

1. **User drafts** prompt nodes + flow connections in the **Node Editor** (SZUI). Edits become
   transactions on `SZCore` state via the host.
2. **User starts the Director Agent** (SZAI). The host hands it the current graph state.
3. **Director Agent plans** and, through MCP, asks the host to create/assign nodes and spawn a
   **Coding Agent** per node, each with an API contract + prompt.
4. **Coding agents** draft each node's `node-contract.json` and `Node.swift`. As contracts
   update, they call `ui_` MCP commands so the **Node Editor** reflows (title, SF Symbol, typed
   I/O). Library lookups go through MCP into [NODE_LIBRARY.md](NODE_LIBRARY.md).
5. **SZRuntime compiles** staged node source with swiftc, hot-reloads modules, and **schedules**
   the DAG.
6. **ViewportPanel** (SZUI) shows the live Metal render driven by SZRuntime.
7. **User iterates**: chats with the Director Agent or a node's Coding Agent, edits connections, or
   triggers a **user-initiated split/merge** (host applies it as one atomic graph transaction;
   affected nodes get re-implemented).

## Detailed docs

| Concern | Doc | Package(s) |
|---|---|---|
| Concrete build targets (types, ABI, MCP list, file tree) | [BUILD_SPEC.md](BUILD_SPEC.md) | all |
| User journey + sequences | [CORE_LOOP.md](CORE_LOOP.md) | all |
| State, serialization, transactions | [STATE.md](STATE.md) | SZCore |
| Metal, scheduling, hot reload | [RUNTIME.md](RUNTIME.md) | SZRuntime |
| Node anatomy, I/O types, connections | [GRAPH_AND_NODES.md](GRAPH_AND_NODES.md) | SZCore, SZRuntime, SZUI |
| Director Agent + coding agents, behavior trees | [AGENT_ORCHESTRATION.md](AGENT_ORCHESTRATION.md) | SZAI |
| Provider wrapping | [AI_PROVIDERS.md](AI_PROVIDERS.md) | SZAI |
| MCP server + command surface | [MCP.md](MCP.md) | SZApp (host) |
| Built-in library + agent consumption | [NODE_LIBRARY.md](NODE_LIBRARY.md) | SZRuntime, SZAI |
| Native panels | [UI.md](UI.md) | SZUI |
