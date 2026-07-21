<p align="center">
  <img src="docs/assets/icon.png" alt="SubjectiveZero" width="128" height="128">
</p>

<h1 align="center">SubjectiveZero</h1>

<p align="center">
  A native-macOS, agentic creative-coding &amp; realtime-VFX harness.<br>
  Describe visual ideas as prompt nodes - agents turn them into live native code.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-beta-orange" alt="Status: beta">
  <a href="https://github.com/sxp-studio/subjective-zero/releases/latest"><img src="https://img.shields.io/github/v/release/sxp-studio/subjective-zero?label=latest&amp;color=blue" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey" alt="macOS 15+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License: AGPL-3.0"></a>
  <a href="https://sxp.studio/apps/subjectivezero"><img src="https://img.shields.io/badge/Discord-join-5865F2?logo=discord&amp;logoColor=white" alt="Discord"></a>
</p>

https://github.com/user-attachments/assets/bbcd7fae-9686-4333-9023-b8c8d8d950a4

## What it is

**SubZ (SubjectiveZero)** is an open-source, **native-macOS** creative-coding and realtime-VFX
harness for the agentic era. You describe visual ideas as **prompt nodes**; orchestrated agents
turn those ideas into isolated, inspectable node implementations that compile, hot-reload, and
render in a live Metal viewport.

It's a harness for making things, not just effects: the graph is a structured sequence of nodes
that can do many things - **not only VFX**. You stay in the loop the whole way, drawing
connections by hand or chatting with the agents building each piece.

SubZ is built on a few deliberate principles:

- macOS-first, **native code everywhere - no WebView**.
- A small but modular codebase (so agents can be scoped to one concern).
- A more permissive graph: a structured sequence of nodes that can do many things, **not just
  VFX**.
- Chat with agents directly (the coordinating agent or any node's agent).
- Orchestration driven by behavior trees *(coming soon)*.

Cross-platform is deferred via **portable formats** (state is JSON), not portable code.

> **Built the way it's meant to be used.** SubZ is written by AI coding
> agents kept on a short leash, with a human reviewing every change. It's the same
> human-in-the-loop workflow SubZ puts in your hands. We think that's the point,
> not a caveat.

> **Status: beta.** SubZ is under active development. The app is usable and shipping real
> releases, but interfaces, project formats, and the node ABI can still change between versions.

## The core loop (this is the product)

Everything in SubZ serves one loop:

1. You draft a graph of **prompt nodes** and connect them with **flow** connections.
2. You start the **Director Agent** - the agent that coordinates the project - and it produces a plan.
3. The Director Agent dispatches/messages a **coding agent per node** with an API contract and prompt.
4. As agents make progress, each node's UI takes shape: title, SF Symbol, and the granular
   typed inputs/outputs draft themselves in.
5. The app runs live, and you iterate - manually drawing connections, or chatting with the
   Director Agent and/or individual node agents.

The viewport runs on a native Metal implementation driven by a thin runtime.

## Getting started

SubZ is a native macOS app. It requires **macOS 15 (Sequoia) or later** on Apple Silicon.

### Download the app

Grab the latest signed &amp; notarized build from the
[**Releases**](https://github.com/sxp-studio/subjective-zero/releases/latest) page. SubZ is
distributed as a DMG **outside the App Store**; mount it, drag the app to `/Applications`, and
launch. Updates are delivered in-app via Sparkle (**Check for Updates…**).

### Build from source

A fresh clone builds ad-hoc with **zero signing setup**:

```sh
git clone https://github.com/sxp-studio/subjective-zero.git
cd subjective-zero
open SubjectiveZero/SZApp.xcodeproj   # then run the "SubjectiveZero" scheme in Xcode
```

To build just the Swift packages (no app bundle):

```sh
cd SubjectiveZero/Modules && swift build
```

### Set up an agent provider

To actually drive agents, you need at least one provider CLI **installed and logged in**:

- **Claude Code** - the `claude` CLI
- **Codex** - the `codex` CLI
- **Grok** - the `grok` CLI
- **Pi** - the `pi` CLI
- **opencode** - the `opencode` CLI

SubZ drives these as subprocesses and stores no provider credentials of its own - auth belongs to
each CLI's own interactive login. The in-app **Agent Providers** sheet shows each provider's
status and remedies; see [`docs/APP_SETUP.md`](docs/APP_SETUP.md) for the full setup walkthrough.

## High-Level Architecture

The product ships as an Apple-notarized bundle/DMG distributed **outside the App Store**. Code
is split into independent Swift packages; only `SZApp` is an actual macOS app bundle linking the
others.

### Packages

- **SZApp** - the macOS app bundle. Creates the window, hosts the runtime, runs the MCP command bus, shows the UI panels.
- **SZCore** - shared state model and JSON serialization. Depended on by every other package.
  This is the canonical, portable representation of App / Project / Graph / Node.
- **SZAI** - provider wrapping, agents, and orchestration strategies (behavior trees *coming
  soon*). Provides a consistent interface for the app to call into agent sessions (tools,
  permissions), handles spawn/messaging for human↔agent and agent↔agent, and failure recovery.
- **SZRuntime** - a lightweight rendering engine. Owns the `MTLDevice`, command queue, and
  resource allocation (`MTLTexture`); owns the viewport context (resolution, pixel
  format, drawable) and permissions (camera, mic). Compiles and executes the node graph and
  handles failures.
- **SZUI** - SwiftUI + AppKit panels and surfaces: viewport, node editor, and chat, plus the HUD and settings.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the dependency graph, ownership rules, and
the end-to-end sequence of the core loop.

## Agents

SubZ ships with agent *types* behind a pluggable orchestration seam. Today each type's behavior is
plain Swift; the design goal is to describe it with a behavior tree / state machine, ideally
configurable in an open format like JSON *(coming soon)*.

- **Director Agent** - coordinates the project from a high level: plans, dispatches coding agents,
  reconciles results.
- **Coding Agent** - one per graph node. Receives an API contract + prompt from the Director Agent
  to implement the node; you can then iterate by chatting with it directly.

A key part of the app is the **MCP server**: agents use it to interact with the app - notifying
status, reading state, requesting UI updates as a node's contract drafts itself, and querying
the node library. There's a 1:1 mapping with key UI interactions so the same surface can drive
automated, closed-loop testing while agents build.

Current providers are **Claude Code** (CLI), **Codex** (CLI + Codex.app), **Grok** (CLI),
**Pi** (CLI), and **opencode** (CLI). Claude Code and Codex surface available models and thinking
level from a static capability manifest (neither CLI enumerates models), with a manual override;
Grok, Pi, and opencode enumerate their models from the CLI at runtime. In every case the CLI is used for health and
session control. See [`docs/AI_PROVIDERS.md`](docs/AI_PROVIDERS.md).

## Nodes and the node library

A node is a unit of compute: a `Node.swift` file plus a `node-contract.json` describing typed
inputs/outputs. The Swift spec is deliberately simple to support hot reload - `setup()`,
`teardown()`, and `update()` (per-frame, with the runtime context).

SubZ maintains a **built-in node library** used as a *reference*: agents pick a good node to
learn from (and copy its source only when it would work as-is), or decide none fits. The library
uses a 3-tier "earn the tokens" model - a cheap index, per-node cards, then full source on
demand - so agents stay correct without blowing their context window. See
[`docs/NODE_LIBRARY.md`](docs/NODE_LIBRARY.md).

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) - packages, ownership, the host seam, core-loop spine.
- [`docs/BUILD_SPEC.md`](docs/BUILD_SPEC.md) - concrete build targets: canonical types, node ABI, V1 MCP list, file manifest.
- [`docs/CORE_LOOP.md`](docs/CORE_LOOP.md) - the canonical user journey + system sequence, incl. split/merge.
- [`docs/STATE.md`](docs/STATE.md) - state model, JSON shapes, transactions/undo.
- [`docs/RUNTIME.md`](docs/RUNTIME.md) - Metal ownership, node module shape, scheduling, hot reload.
- [`docs/GRAPH_AND_NODES.md`](docs/GRAPH_AND_NODES.md) - node anatomy, I/O types + UI, connections.
- [`docs/AGENT_ORCHESTRATION.md`](docs/AGENT_ORCHESTRATION.md) - Director Agent + coding agents, behavior trees.
- [`docs/AI_PROVIDERS.md`](docs/AI_PROVIDERS.md) - provider wrapping; capability discovery (static manifest or runtime enumeration, per provider).
- [`docs/MCP.md`](docs/MCP.md) - MCP server design and command surface.
- [`docs/NODE_LIBRARY.md`](docs/NODE_LIBRARY.md) - the built-in library and how agents consume it.
- [`docs/UI.md`](docs/UI.md) - native panels.

## Privacy & telemetry

Release builds send a small set of anonymous usage events so we can see where new
users get stuck and keep the app healthy:

- **Identity**: a random install ID (a UUID minted on first launch). No account,
  no email, no fingerprinting beyond OS version, CPU architecture, and Mac model.
- **Events**: `app_launch`, `app_active_heartbeat`, `agent_provider_default`,
  and the first-run setup funnel — `setup_shown`, `setup_skipped`,
  `setup_completed`, `setup_stuck_relaunch` (each carries at most provider names
  and their readiness, e.g. `claude:ready`).
- **Never sent**: project content, graphs, prompts, chat transcripts, file paths,
  or code.
- **Opting out**: uncheck **"Share anonymous usage data"** on the welcome screen
  (Help ▸ Welcome). The preference persists in
  `~/Library/Application Support/SubjectiveZero/app-state.json`.
- **Source builds**: DEBUG builds print payloads to the console instead of
  sending, and builds without a bundled reporting key send nothing at all.

## License

SubZ is open source under the **AGPL-3.0** ([`LICENSE`](LICENSE)). In plain terms:

- **Free to use, self-host, and build on.** Read the source, run it, fork it,
  write nodes and plugins for it. The full terms live in [`LICENSE`](LICENSE) and
  [`NOTICE`](NOTICE).
- **What you make is yours.** Graphs, nodes, and effects you create in SubZ aren't
  covered by the AGPL (a section 7 exception, spelled out in [`NOTICE`](NOTICE)).
  Use them in client work, commercial productions, live shows, or alongside tools
  like TouchDesigner, under whatever license you want.
- **Using it commercially is fine.** Running SubZ for professional or paid work
  needs no separate license. You'd only need a commercial license to embed SubZ's
  own code in a closed-source product, or to run a modified version as a hosted
  service. For that, reach out at subz@sxp.studio.
- **The name and marks are ours.** "Subjective Zero", "SubZ", "sxp.studio", and
  the logos are trademarks of SXP Studio EURL, and aren't part of the open-source
  license. Forks are welcome, but please give yours its own name and don't imply
  it's built or endorsed by us.

Copyright © 2026 SXP Studio EURL.

## Contributing

SubZ is authored and maintained by [Clem](https://github.com/clemzio), its main
contributor.

Contributions are welcome under the terms in [`CONTRIBUTING.md`](CONTRIBUTING.md).
