# AGENTS.md — SubZ

Guidelines for any agent or human working in this repo. Covers **how we work here**; the spec covers
**what to build**.

SubZ is a native-macOS (SwiftUI + AppKit + Metal), open-source creative-coding / realtime-VFX
harness, split into 5 SwiftPM packages: `SZApp` · `SZCore` · `SZAI` · `SZRuntime` · `SZUI`.

**The spec is the source of truth — read it before building.** Start with `README.md` and `docs/`,
especially `docs/ARCHITECTURE.md` (incl. the host seam) and `docs/BUILD_SPEC.md`.

## Guidelines

1. **Naming — `SZ` prefix.** Public types use the `SZ` prefix (`SZApp`, `SZCore`, `SZNode`,
   `SZProvider`, …).

2. **License header on new source.** Start every new first-party **app/engine** Swift file with
   `// SPDX-License-Identifier: AGPL-3.0-only` as its first line — this covers `SZApp/` and
   `Modules/Sources/` (and their tests). The app + engine are AGPL-3.0; see `LICENSE` / `NOTICE`.
   **Do not** add this header to **node sources** — `Node.swift` under `NodeLibrary/` or `Samples/`
   (or any node the runtime authors): those fall under the `NOTICE` §7 node exception and must stay
   unencumbered. And never put it above `Package.swift`'s `swift-tools-version` line (must remain line 1).

3. **No legacy / migration (until v1 ships).** No backward-compat shims, deprecations, versioned
   migrations, or "old format" support. The schemas (JSON state, node ABI) are **not frozen** — change
   them in place and update call sites; never maintain a migration path.

4. **Least code, no speculative abstraction.** Build only what the current milestone needs, and
   defer anything the roadmap marks deferred — the behavior-tree engine, per-node live previews,
   MCP record/replay. Don't add third-party dependencies without asking.

5. **Build + verify, small commits.** Every change must `swift build` clean; render-affecting changes
   must be visually or closed-loop checkable. Commit in small, reviewable steps with clear messages.

6. Do not be lazy, do not punt things to a 'v2' unless explicitly agreed upon.

## Definition of done

A step is **done** only when, together:

- it `swift build`s clean (and any relevant test passes);
- its behavior is verified — render-affecting changes visually or closed-loop checked;
- the evidence (commit SHA + how it was verified) is recorded;
- the change is reviewed and signed off at the checkpoint.

Never claim a step done without attached evidence, and never report it complete with acceptance
checks still open.

> Maintainers: the running build log, backlog, roadmap, and release runbook live under `internal/`
> (gitignored, not published).