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
   **Do not** add this header to **node sources** — `Node.swift` and `Card.swift` under `NodeLibrary/`
   or `Samples/` (or any node the runtime authors): those fall under the `NOTICE` §7 node exception and
   must stay unencumbered. And never put it above `Package.swift`'s `swift-tools-version` line (must remain line 1).

3. **No legacy / migration (until v1 ships).** No backward-compat shims, deprecations, versioned
   migrations, or "old format" support. The schemas (JSON state, node ABI) are **not frozen** — change
   them in place and update call sites; never maintain a migration path.

4. **Comments: short, plain, lower-case.** A file header is at most ~15 lines and says what the
   file is for; a member doc is one or two lines. No shouting — write "every node", not "EVERY
   node" — and no long narrative retelling of a bug. Say the mechanism, not the story: one clause
   of history earns its place only when it stops someone reverting the fix.

5. **Least code, no speculative abstraction.** Build only what the current milestone needs, and
   defer anything the roadmap marks deferred — the behavior-tree engine, MCP record/replay.
   Don't add third-party dependencies without asking.

6. **Build + verify, small commits.** Every change must `swift build` clean; render-affecting changes
   must be visually or closed-loop checkable. Commit in small, reviewable steps with clear messages.

   The suites are two, and a full verify runs both:

   ```sh
   cd SubjectiveZero/Modules && swift build && swift test    # SZCore · SZAI · SZRuntime · SZUI
   cd SubjectiveZero && xcodebuild -project SZApp.xcodeproj \
     -scheme SubjectiveZero -configuration Debug test        # SZAppTests — the host + MCP surface
   ```

   `SZAppTests` is a unit-test bundle hosted by the app, so it can `@testable import SubjectiveZero`
   and pin what lives inside the app target (the MCP tool surface, argument coercions, host helpers).
   It is test-only: nothing depends on it, so a `build` — Release included — never produces it.

7. Do not be lazy, do not punt things to a 'v2' unless explicitly agreed upon.

## Worktrees & landing

Implementation work happens in a **git worktree inside the repo**, under `.claude/worktrees/`:

```sh
git worktree add .claude/worktrees/<name> -b <branch> main
```

Never create a new sibling directory at the parent level for a worktree or checkout.

**Landing on `main`:**

1. Rebase the branch on `main`.
2. Run the full verify from guideline 6 — **both** suites green (`swift test` from
   `SubjectiveZero/Modules`, and the `SubjectiveZero` scheme's `xcodebuild … test` for `SZAppTests`).
3. Fast-forward-only merge to `main` (`git merge --ff-only <branch>`), then push.
4. Commits are DCO-signed-off as "Clem" (`git commit -s`). No AI-attribution trailers
   (no `Co-Authored-By` / "Generated with" lines).

**Branch hygiene:** after the merge, remove the worktree and delete the branch. Work that parks
instead of landing gets an explicit note (why, and where it resumes). History that must stay
reachable past a branch delete gets an `archive/*` tag before the delete.

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