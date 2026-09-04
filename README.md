<p align="center">
  <img src="docs/assets/icon.png" alt="SubjectiveZero" width="128" height="128">
</p>

<h1 align="center">SubjectiveZero</h1>

<p align="center">
  An agentic node editor for creative-coding &amp; realtime VFX.<br>
  Describe visual ideas as a graph of prompts - agents turn them into live native code - refine and iterate
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-beta-orange" alt="Status: beta">
  <a href="https://github.com/sxp-studio/subjective-zero/releases/latest"><img src="https://img.shields.io/github/v/release/sxp-studio/subjective-zero?label=latest&amp;color=blue" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey" alt="macOS 15+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License: AGPL-3.0"></a>
  <a href="https://discord.gg/Y3JZxpXExs"><img src="https://img.shields.io/badge/Discord-join-5865F2?logo=discord&amp;logoColor=white" alt="Discord"></a>
</p>

https://github.com/user-attachments/assets/bbcd7fae-9686-4333-9023-b8c8d8d950a4

## Intro

**SubZ (SubjectiveZero)** is an open-source creative-coding and realtime-VFX harness for the
agentic era. You describe visual ideas as **prompt nodes**; orchestrated agents turn those ideas
into isolated, inspectable node implementations that compile, hot-reload, and render in realtime.

What it does today:

- **Prompt to graph.** A Director agent splits a sentence into typed nodes and sends a coding
  agent to each, in parallel. Every node is real Swift and Metal you can open and edit. Save,
  and it hot-reloads in about 300 ms.
- **Generative UI.** Nodes draw their own controls before the code exists. Ask for a slider and
  the node builds it with the code. A `Card.swift` next to the node can mount a knob, meter or
  panel.
- **Compile isolation.** A node that fails to build never takes the rest of the graph down.
- **Sound in, beats out.** Microphone or system audio, no virtual driver. Frequency bands for
  levels, an onset detector for kick, snare and hat triggers. Any output drives any parameter.
- **MIDI and OSC.** Press Learn, move a knob, and it binds to the port you pointed at.
- **Record the render.** One press saves a take, framed, with app or system sound.
- **Your agents, your account.** Drives the Claude Code, Codex, Grok, Pi, OpenCode or Muse Code
  CLI you already pay for. No model shipped, no tokens resold.

**Learn it in one sitting:** [Creating Live Visual Effects with SubjectiveZero](https://www.youtube.com/watch?v=DcI1tsPJ8eM)
is thirteen minutes from an empty project to a running effect. Product page and download:
[sxp.studio/apps/subjectivezero](https://sxp.studio/apps/subjectivezero).

SubZ is written the way it's meant to be used, by AI coding agents on a short leash with a human
reviewing every change. It's in beta and shipping real releases, but interfaces, the project
format, and the node ABI can still change between versions.

## The Core Loop

Everything in SubZ serves one loop:

1. You draft a graph of **prompt nodes** and connect them with **flow** connections.
2. The director agent will refine your graph and draft a plan for your effect
3. The director agent will spawn a fleet of parallel coding agents to build your nodes
4. As agents make progress, each node's UI takes shape through agent MCP callbacks
5. The app runs live, and you iterate - manually drawing connections, or chatting with agents

## Concepts

**Node**: a unit of compute, a source code `Node.swift` file plus a `node-contract.json` declaring its typed
inputs and outputs. The Swift side is deliberately small (`setup()`, `teardown()`, and a
per-frame `update()`), which is what makes hot reload practical. A project picks where it runs when
it is created: on this Mac, where nodes are Swift compiled against Metal, or in a browser, where
they are `Node.js` modules drawn with three.js and the whole project exports as one `.html` file.

**Agents**: the Director Agent coordinates the project, planning work, dispatching coding agents
and reconciling what comes back. A coding agent owns one node's implementation. You can chat with
either. An agent type is a folder: `agent.json`, the graphs that describe its turns, and the
prompts those turns use, so its behavior is data you can read and rewrite
([AGENT_GRAPHS](docs/AGENT_GRAPHS.md)).

**MCP server**: how agents reach the app, to report status, read state, draft a node's contract
into the UI, and query the node library. It maps closely onto the UI's own interactions,
so the same surface can drive closed-loop testing.

**Node library**: built-in nodes that agents read as reference. An agent picks one to learn
from, or decides none fits; it copies source only when that source would work as-is.

## Getting started

SubZ is a native app:

- **macOS**: 15 (Sequoia) or later, on Apple Silicon or Intel.
- **Windows**: not yet. Depending on interest it will absolutely be considered.

Grab the signed, notarized build from
[Releases](https://github.com/sxp-studio/subjective-zero/releases/latest). It ships as a DMG
outside the App Store, so mount it, drag the app to `/Applications`, and launch. Updates arrive
in-app through Sparkle (**Check for Updates…**).

A fresh clone builds ad-hoc, with no signing setup:

```sh
git clone https://github.com/sxp-studio/subjective-zero.git
cd subjective-zero
open SubjectiveZero/SZApp.xcodeproj   # then run the "SubjectiveZero" scheme
```

Or build just the Swift packages, without the app bundle:

```sh
cd SubjectiveZero/Modules && swift build
```

To actually drive agents you need at least one provider CLI installed and logged in: `claude`,
`codex`, `grok`, `pi`, `opencode`, or `muse`. SubZ runs them as subprocesses and stores no credentials of
its own, so auth stays with each CLI's own login. The in-app Agent Providers sheet shows what's
ready and what isn't; [`docs/APP_SETUP.md`](docs/APP_SETUP.md) has the full walkthrough.

## Codebase

Five Swift packages. Only `SZApp` is an app bundle; it links the others.

- `SZApp`: the macOS app. Window, runtime hosting, the MCP command bus, panel wiring.
- `SZCore`: the state model and its JSON serialization. The portable representation of
  App / Project / Graph / Node, depended on by everything else.
- `SZAI`: providers, agent sessions, and orchestration.
- `SZRuntime`: compiles and executes the graph, and owns the graphics API context and the
  device permissions (camera, mic).
- `SZUI`: the panels. Viewport, node editor, chat, HUD, settings.

Start reading at [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the dependency graph and
ownership rules, then [`docs/BUILD_SPEC.md`](docs/BUILD_SPEC.md) for the canonical types, node
ABI, and MCP surface. The rest of `docs/` goes a level deeper on one area each:
[CORE_LOOP](docs/CORE_LOOP.md), [STATE](docs/STATE.md), [RUNTIME](docs/RUNTIME.md),
[GRAPH_AND_NODES](docs/GRAPH_AND_NODES.md), [AGENT_ORCHESTRATION](docs/AGENT_ORCHESTRATION.md),
[AGENT_GRAPHS](docs/AGENT_GRAPHS.md) (with the [AUTHORING](docs/AUTHORING.md) tutorial),
[AI_PROVIDERS](docs/AI_PROVIDERS.md), [MCP](docs/MCP.md), [NODE_LIBRARY](docs/NODE_LIBRARY.md),
[UI](docs/UI.md).

## Privacy

Release builds report a small set of anonymous events (a random install ID, OS and hardware, app
launch, the first-run setup funnel, and first-session milestones: a prompt was sent, an agent
turn ended, a node compiled) so we can see where new users get stuck. Project content,
prompts, chat, file paths, and code are never sent. To opt out, uncheck "Share anonymous usage
data" on the welcome screen (Help ▸ Welcome). Full detail in [`docs/PRIVACY.md`](docs/PRIVACY.md).

## License

SubZ is open source under the AGPL-3.0 ([`LICENSE`](LICENSE)). Read it, run it, fork it, build on
it, including for paid professional work. What you make with SubZ (graphs, nodes, effects) is
yours and isn't covered by the AGPL, under a section 7 exception spelled out in
[`NOTICE`](NOTICE). You'd only need a commercial license to embed SubZ's own code in a
closed-source product or to run a modified version as a hosted service; for that, reach out at
subz@sxp.studio. "Subjective Zero", "SubZ", "sxp.studio" and the logos are trademarks of SXP
Studio EURL and aren't part of the open-source license, so forks are welcome but please give
yours its own name.

Copyright © 2026 SXP Studio EURL.

## Contributing

SubZ is maintained by [Clem](https://github.com/clemzio). Bug fixes, new nodes, and docs can go
straight to a PR; for a larger feature or anything that changes the UI or core behavior, open an
issue first. Commits are DCO signed-off (`git commit -s`). [`CONTRIBUTING.md`](CONTRIBUTING.md)
covers why and how contributions are licensed, and [`AGENTS.md`](AGENTS.md) covers the codebase
conventions.

Both suites should be green before you open a PR:

```sh
cd SubjectiveZero/Modules && swift build && swift test
cd SubjectiveZero && xcodebuild -project SZApp.xcodeproj -scheme SubjectiveZero -configuration Debug test
```
