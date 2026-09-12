<p align="center">
  <img src="docs/assets/icon.png" alt="SubjectiveZero" width="128" height="128">
</p>

<h1 align="center">SubjectiveZero</h1>

<p align="center">
  The agentic node editor for live visual effects.<br>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-beta-orange" alt="Status: beta">
  <a href="https://github.com/sxp-studio/subjective-zero/releases/latest"><img src="https://img.shields.io/github/v/release/sxp-studio/subjective-zero?label=latest&amp;color=blue" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey" alt="macOS 15+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License: AGPL-3.0"></a>
  <a href="https://discord.gg/Y3JZxpXExs"><img src="https://img.shields.io/badge/Discord-join-5865F2?logo=discord&amp;logoColor=white" alt="Discord"></a>
</p>

https://github.com/user-attachments/assets/db6c58b0-0864-45d5-bf1e-583e37def3c3

SubjectiveZero is a new take on effect creation tools like TouchDesigner and Notch.

The philosophy behind SubjectiveZero is that an idea should cost almost nothing to try.

You start from ideas and descriptions of what you'd like to make, and SubjectiveZero takes care of
building the corresponding node graph for your effect, with a bias for fast iteration and low
friction.

As your project's node graph comes to life, watch the interface adapt to your context, adding
knobs to tweak your feel and visuals before you even think about it. Your node graph can be
restructured at any point, at any degree of complexity that you wish (from high level concepts to
actual code that can hot-reload).

SubjectiveZero is designed with performance in mind: every change reloads into a render that is
already running. The intent is to have a tool you play with rather than operate.

It is free and open source, and it runs on the coding agent subscription you already pay for:
Claude Code, Codex, Grok, Pi, OpenCode or Muse Code. No model shipped, no tokens resold.

**[Download the latest build](https://github.com/sxp-studio/subjective-zero/releases/latest)**, or
read the product page at [sxp.studio](https://sxp.studio/apps/subjectivezero).

## What makes it different

- **From ideas to a graph.** Ask in chat, or wire a prompt node into the graph. What you asked for
  is split into connected nodes with named inputs and outputs, each written by its own agent, all
  at the same time, and you can keep working while they do.
- **The controls are generated too.** Knobs are on your nodes before you think to ask. Ask for
  something more complex and an agent builds a custom card on the node itself: a meter, handles you
  drag on the picture, whatever the effect needs.
- **Deterministic agent workflows.** Every agent turn follows a graph of steps, and a step is
  either code or a markdown prompt. Nothing rearranges itself between runs.
- **Split, merge, rewire.** A node becomes stages you can tune one at a time, or collapses back
  into one, for the cost of asking.
- **Every node is code you own.** Swift and Metal on the Mac, JavaScript in the browser. Change a
  line and save; it reloads without dropping a frame.
- **Native or browser.** The same project targets this Mac or the web, and exports as one `.html`
  file that runs anywhere.

## Made with SubZ

Live visuals for a set, projection on a wall, a reactive piece driven by sound, MIDI or OSC, a
camera effect, or a sketch that ends up as a single web page. See what it looks like in the
[showcase](https://sxp.studio/apps/subjectivezero#showcase), or watch
[thirteen minutes from an empty project to a running effect](https://www.youtube.com/watch?v=DcI1tsPJ8eM).

SubZ is in beta and shipping real releases, but interfaces, the project format and the node ABI
can still change between versions.

## Documentation

**Setting up.**<br>
[`APP_SETUP.md`](docs/APP_SETUP.md) covers the Xcode Command Line Tools and
logging in a provider CLI. It is written to be handed to a coding agent, which will do it for you.

**Building from source:**<br>
Clone, then open `SubjectiveZero/SZApp.xcodeproj` an run the
SubjectiveZero scheme. For the libraries alone: `swift build` in `SubjectiveZero/Modules`.

**In depth documentation:**<br>
| Document | What it covers |
| --- | --- |
| [ARCHITECTURE](docs/ARCHITECTURE.md) | The spine. Package boundaries, who owns what, one turn end to end. |
| [BUILD_SPEC](docs/BUILD_SPEC.md) | The concrete layer under the rest: canonical types, the node ABI, the MCP surface. |
| [CORE_LOOP](docs/CORE_LOOP.md) | The loop every other doc exists to make solid and fast. |
| [STATE](docs/STATE.md) | `SZCore`, the single source of truth: the model and its JSON. |
| [GRAPH_AND_NODES](docs/GRAPH_AND_NODES.md) | What a node is, on disk and at runtime. |
| [RUNTIME](docs/RUNTIME.md) | `SZRuntime`. Metal, GPU resources, compiling and running the graph. |
| [UI](docs/UI.md) | `SZUI`. The native panels, SwiftUI and AppKit. |
| [AGENT_ORCHESTRATION](docs/AGENT_ORCHESTRATION.md) | `SZAI`. How the host drives agents. |
| [AGENT_GRAPHS](docs/AGENT_GRAPHS.md) | How an agent turn is described as a graph of steps you can read. |
| [AUTHORING](docs/AUTHORING.md) | Writing an agent of your own, as a tutorial. |
| [AI_PROVIDERS](docs/AI_PROVIDERS.md) | The provider CLIs behind one interface. |
| [MCP](docs/MCP.md) | How agents act on the app. |
| [NODE_LIBRARY](docs/NODE_LIBRARY.md) | The built-in nodes, and how agents read them. |
| [PRIVACY](docs/PRIVACY.md) | Every anonymous event a release build reports. |

## Contributing

Bug fixes, new nodes and docs can go straight to a PR; for anything larger, open an issue first. Commits are DCO signed-off (`git commit -s`). See
[`CONTRIBUTING.md`](CONTRIBUTING.md) and [`AGENTS.md`](AGENTS.md).

## License and privacy

Release builds report a small set of anonymous events so we can see where new users get stuck.
Project content, prompts, chat, file paths and code are never sent, and you can opt out on the
welcome screen. Every event is listed in [`docs/PRIVACY.md`](docs/PRIVACY.md).

AGPL-3.0 ([`LICENSE`](LICENSE)). What you make with SubZ is yours and is not covered by it, under
a section 7 exception spelled out in [`NOTICE`](NOTICE), so paid professional work needs no
separate licence. Embedding SubZ's own code in a closed-source product or running a modified
version as a hosted service needs a commercial one: subz@sxp.studio. "Subjective Zero", "SubZ",
"sxp.studio" and the logos are trademarks of SXP Studio EURL, so forks are welcome but please give
yours its own name.

Maintained by [Clem](https://github.com/clemzio). Copyright © 2026 SXP Studio EURL.
