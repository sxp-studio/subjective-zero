# AI Providers

**Package: SZAI.** SubZ wraps third-party AI coding tools behind a consistent interface so the
rest of the app calls "an agent session" without caring which connection is underneath. This doc covers
the provider model, what we surface per provider, sessions, and health - plus the one genuinely
open question (capability discovery).

## Direct ChatGPT connection

ChatGPT is the default OpenAI connection; there is no separate Codex CLI provider. **Continue with ChatGPT** downloads the pinned OpenAI Codex
app-server package if needed, then opens browser OAuth with PKCE and a loopback callback.
Eligible Plus and Pro users authorize ChatGPT plan usage; identity-only consent cannot run agents.
Users can choose saved accounts, add another, reconnect, sign out, and open ChatGPT's usage settings.

`SZChatGPTAccounts` owns installation identity, per-registration credentials in macOS Keychain,
ID-token verification, refresh-token rotation, and revocation. Credentials never enter project files,
logs, telemetry, or transcripts. Refresh is serialized per session and locked across app processes.
Tests use protected files in their temporary home instead of the user's Keychain.

`SZChatGPTProvider` runs a private app-server connection for each turn, authenticated against
`https://api.openai.com/v1`. It refreshes credentials before starting a turn and resumes local threads
in the selected account's private Codex home. A thread cannot be resumed using another account.
The host's MCP bus and staging/compile/promote path remain the execution boundary. Success requires
`turn/completed` with status `completed`; partial text is not proof of success. Cancellation and
timeouts stop the process tree. Failed turns are not automatically replayed.

Model discovery uses the selected account's `/v1/models` catalog. The picker preserves returned
model capabilities; Fast mode remains unavailable until verified for this integration. Account
changes clear the catalog and probe result. Rate-limit failures lead to **Manage usage**, with no
automatic change of billing source.

The engine is fetched at setup, not bundled in the app. `SZChatGPTEngine` pins version 0.159.0,
architecture-specific official release URLs and SHA-256 hashes. It verifies the archive before
extracting into a temporary directory, then installs atomically under Application Support. The
package includes the code-mode host and runtime resources. Updates to the pin are reviewed with
SubZ releases; the app never downloads a floating latest release. Interrupted setup can be retried.

References: [registration](https://developers.openai.com/siwc/token-sharing-open-source/sign-in),
[app-server](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server),
[limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations),
[OpenAI engine release](https://github.com/openai/codex/releases/tag/rust-v0.159.0).
The sign-in button follows OpenAI's [approved branding](https://developers.openai.com/siwc/website).
Its white logo is rendered from the official
[`chatgpt-logo-white.svg`](https://developers.openai.com/assets/siwc/sign-in-buttons/chatgpt-logo-white.svg).

## Provider model

A **provider** is an adapter that knows how to:

- discover whether its tool is installed and authenticated,
- start a **session** (a running agent process) with a chosen model, thinking level, and options,
- send messages to the session and stream responses back,
- expose the tools/permissions the session is allowed to use (notably the SubZ MCP server),
- tear down / recover the session on failure.

Adapters conform to one protocol so [AGENT_ORCHESTRATION.md](AGENT_ORCHESTRATION.md) and
[MCP.md](MCP.md) are provider-agnostic.

```swift
// Illustrative.
protocol SZProvider {
    var id: String { get }                       // "chatgpt", "claude"
    func healthCheck() async -> ProviderHealth    // installed? authed? version?
    func capabilities() async -> ProviderCapabilities  // models, thinking levels, fast? (see open question)
    func startSession(_ config: SessionConfig) async throws -> SZSession
}
```

## Built-in providers (initial)

- **claude code** - CLI only.
- **ChatGPT** - direct sign-in; SubZ manages the downloaded OpenAI harness.
- **grok** - CLI only (x.ai; added 2026-07, verified against grok 0.2.93).
- **pi** - CLI only (pi.dev, `@earendil-works/pi-coding-agent`; added 2026-07, verified against
  pi 0.80.6). A BYOK multi-provider harness — the user connects their own accounts (ChatGPT
  Plus/Pro, Claude Pro/Max, Copilot OAuth, or API keys) and pi routes to them; subz drives only
  the harness. The first provider with a RUNTIME-enumerated model catalog (see Capability
  discovery below).
- **opencode** - CLI only (opencode.ai; added 2026-07, verified against opencode 1.18.4). Also a BYOK
  multi-provider harness (like pi) with a RUNTIME-enumerated catalog — the user authes their own
  backends (`opencode auth login`) and opencode routes to them; subz drives the harness. Distinct
  from pi in sessions: opencode mints its own `ses_…` id, parsed back from the stream .
  Catalog default (`SZOpenCodeProvider.catalogSnapshot`): the user's own configured `model` (read
  token-free from `opencode debug config`) when opencode still serves it — otherwise NONE: runs omit
  `-m` and opencode's own selection carries the run. The app never guesses a default from the
  catalog; two generations of guessing broke on account facts only opencode's backends know (a
  quota-exhausted "zen" freebie, then an API-key-only model on a ChatGPT-OAuth account). A failing
  provider's model is re-pickable from its Agent Providers card, and Test probes the *resolved*
  model, not the provider default.
- **muse** - CLI only (Meta's Muse Code, `muse`; added 2026-08, verified against 0.1.0-R708.1 —
  the beta released 2026-08-05, whose portal docs are account-gated, so every CLI-integration fact
  is live-measured; model list re-measured against 1.0.1-R2006.1 on 2026-09-03). Static manifest
  (`muse-spark-1.3` default, `muse-spark-1.3-contributor`, `muse-spark-1.2`; each id read back from
  a live run's `run.model.configured` event; no enumeration command exists). Auth is `muse auth set
  --api-key-stdin` (Meta developer account API key) or the `muse login` device flow. Distinct in
  its MCP attachment: a per-scope STAGED CONFIG HOME (`XDG_CONFIG_HOME` → a throwaway dot-dir in
  the agent's working directory, with settings.json naming an nc bridge script and an auth.json
  symlink into the user's real store) — no per-invocation MCP flag. CAUTION for users: the model
  is metered, and the data-sharing "Contributor" tier is a model id: on 1.0.1 a run without
  `--model` configures `muse-spark-1.3-contributor` (measured on one account, 2026-09-03), so the
  app always passes an explicit `--model`, defaults to the standard id, and lists the Contributor
  id under its own name; see APP_SETUP.md.

The provider exposes its models, reasoning choices, and supported options through `SZProvider`.
`SZCLIProvider` supplies subprocess launch and parsing for installed coding tools. ChatGPT supplies
its own authenticated app-server transport through the same `run` and health requirements.

### The capability manifest

ChatGPT fetches visible models and their display names and reasoning options from the signed-in
account's `/v1/models` response. No bundled OpenAI model list or Codex CLI discovery is used.
The first returned visible model is the default. Models are cleared on account changes and fetched
again; an unavailable catalog blocks model selection rather than inventing an entitlement.
Fast mode is currently unavailable for this connection.

Claude and Muse use measured static manifests. Grok, Pi, and OpenCode discover models through
their own authenticated tools. The setup screen's connection test verifies a real model response;
metadata alone does not prove inference access. Model capabilities clamp saved generation choices.

Picking a new model resets that provider's agent sessions (a thread is bound to the model
that opened it); changing effort or fast mode does not. The **default envelope is global**:
one active provider plus its generation choices, edited in AI Settings, persisted per
provider in app-state.json ([STATE.md](STATE.md)), clamped at read by
`resolvedGenerationSettings`, and stamped into every `SZAgentRunRequest`.

## Model routing

The agent graphs declare **model slots** — the kinds of model work each agent needs, every
slot with the pack author's own description (`slots` in graph.json, [AGENT_GRAPHS.md](AGENT_GRAPHS.md)).
Named **routing profiles** fill them: `(agent, slot) → envelope`
(`{providerID, model?, reasoningEffort?, fastMode?}` — `SZRoutingProfile`, edited in the AI
Settings sheet's Routing pane, [UI.md](UI.md)). Slots are the packs' own stable vocabulary,
so a profile survives every node rename and rewire; the built-ins declare planner /
assistant / sorter (director), builder-default / builder-light / builder-heavy / editor /
assistant / sorter (coding, with `grades` mapping the Director's light / standard / heavy task
grades to the builder slots — `editor`, the lane a user's change request to a built node takes,
is chosen by the graph rather than by a grade), and assistant (debug). The forward-looking selection lives in AI
Settings, and the backward-looking truth is the
**per-turn receipt** each finished reply carries in the transcript — the envelope the turn
*actually* ran, with the routing rule that chose it (`via`). Semantics:

- **Resolution ladder**, most specific first: session pin > the dispatched task's grade
  (resolved through the pack's `grades` map: the grade's slot, else the standard one) > the
  call's slot as the profile fills it > default. Step asks resolve their node's `ask` slot
  (else the graph's `asks`) the same way. Anything unfilled falls one rung — coarser, never
  wrong ([AGENT_ORCHESTRATION.md](AGENT_ORCHESTRATION.md#model-routing)).
- **Session affinity**: a live thread keeps the envelope that opened it; activating, editing, or
  deleting a profile governs NEW conversations only — nothing moves under a running session, and
  a profile switch is refused outright while a run is in flight. A thread leaves its envelope on
  Clear Chat, on changing the default model, on switching or disabling a provider, on a build's
  receipt (the Director) or an edit (a node); turning routing off moves live threads to the
  default model. A session file from before routing carries no envelope, so under a route to
  another provider it cold-starts once.
- **`SZ_MODEL_ROUTING`** (launch env): `=0` kills routing for the session; `=<name>` pins that
  profile; an unknown name REFUSES the delivery rather than guessing (the SZ_AGENT_PACKS rule).
  Unset or `=1`: app-state governs. With no active profile the router is the identity —
  byte-identical to the pre-routing app.
- **Never-guess fallback, narrated**: an envelope naming an unknown or unready provider drops its
  rung with a sentence the user reads; an off-catalog model runs the provider's clamp with a
  sentence naming what was asked and what runs instead. Never a silent substitution, and each
  sentence is said once per profile state.

## Sessions

- A session is a long-lived agent process bound to one provider + config.
- The Director Agent and each Coding Agent run as sessions; the `Orchestrator` routes messages to the right
  session and streams responses back (V1 orchestration is hardcoded Swift, not yet a behavior tree -
  see [AGENT_ORCHESTRATION.md](AGENT_ORCHESTRATION.md)).
- Sessions are granted the SubZ **MCP server** as a tool so agents can act on the app. Permissions
  (which MCP commands, filesystem scope) are part of `SessionConfig`.
- Failure recovery: a crashed/stalled session is restarted by the host; in-flight tree state
  decides whether to resume or re-prompt.

## CLI integration (verified 2026-06-13; grok column 2026-07-12; pi column 2026-07-12; opencode column 2026-07-21; muse column 2026-08-07; model rows 2026-09-03)

Concrete facts the adapters rely on, from the installed CLIs (claude code 2.1.177, grok 0.2.93, pi 0.80.6, opencode 1.18.4, muse 0.1.0-R708.1; model selection re-verified
on claude 2.1.259, muse 1.0.1-R2006.1):

| Need | claude code | grok | pi | opencode | muse |
|---|---|---|---|---|---|
| Non-interactive run | `claude -p/--print` | `grok -p/--single` | `pi -p --mode json` (prompt is a trailing positional; stdin MUST reach EOF or the CLI hangs with zero output — the runner wires /dev/null) | `opencode run` (prompt trailing positional; `--auto` bypasses permission prompts) | `muse exec` (prompt trailing positional; `--disable-approval` bypasses approvals, sandbox stays on; `--no-foreign-personal-context` keeps other CLIs' imported skills out) |
| Structured / streamed output | `--output-format json\|stream-json`, `--json-schema <s>` | `--output-format json\|streaming-json` (token-level `thought`/`text` chunks; NO tool events) | `--mode json` (JSONL events: session header, message/turn lifecycle, `tool_execution_*`); CAUTION: a FAILED turn still exits 0 — `parse()` reads the last assistant `stopReason` | `--format json` (JSONL: `step_start`/`reasoning`/`tool_use`/`text`/`step_finish`, each carrying `sessionID`); a failed turn exits nonzero AND emits a top-level `error` event | `--json` (the session EVENT LOG as JSONL envelopes: `run_output_delta` chunks, `task_lifecycle` per task with task_kind `tool.{name}`, final `run_terminal` with the authoritative text); reasoning is encrypted, per-turn usage rides only the durable log (`muse export`) |
| Model selection | `--model <alias\|full>` | `-m/--model` (enumerable via `grok models`) | `--model <provider/id>` qualified (catalog enumerated at runtime via `--mode rpc` → `get_available_models`) | `-m <provider/model>` qualified (catalog enumerated at runtime via `opencode models --verbose`) | `--model <id>` (no enumeration command; static ids `muse-spark-1.3` / `-1.3-contributor` / `-1.2`, each read back from `run.model.configured`; always passed explicitly because the CLI's own no-flag default is the Contributor tier) |
| Thinking level | `--effort <low\|medium\|high\|xhigh\|max>` | `--reasoning-effort` exists but is NOT honoured (measured) - never emitted | `--thinking <minimal\|low\|medium\|high\|xhigh\|max>`, per-model menus derived from the catalog's `thinkingLevelMap`; out-of-menu values silently clamp | `--variant <low\|medium\|high\|xhigh\|max>`, per-model menus from each model's `variants` map (maps to OpenAI's `reasoningEffort`); `none` dropped | `--reasoning-effort <minimal\|low\|medium\|high\|xhigh\|ultra>` (recorded from the CLI's own rejection of `none`, which is echo-provider-only; default high) |
| Attach SubZ MCP server | `--mcp-config <json>` | `<cwd>/.grok/config.toml`, staged per run by `prepare()` (no per-invocation flag) | no built-in MCP: `prepare()` stages `<cwd>/.subz/mcp-bridge.mjs` (a pi extension speaking the host's TCP protocol), loaded via `--extension` | inline `OPENCODE_CONFIG_CONTENT` env carrying an `mcp.subz` local (nc) server; NO cwd file (opencode roots a session at the git repo and drops a cwd-staged `opencode.json`), no per-invocation flag | staged config HOME: `prepare()` writes a throwaway `XDG_CONFIG_HOME` (settings.json `mcp_servers.subz` stdio → an nc bridge script, `command` is a bare path with no args field; auth.json symlinks to the user's real store — the binary ignores `MUSE_AUTH_PATH`), no per-invocation flag |
| Sessions | host-minted `--session-id`, `--resume <id>` | host-minted `--session-id`, `--resume <id>` | host-minted `--session-id` (one flag creates AND resumes; header echoes it) | id parsed from any event's `sessionID` (`ses_…`); `-s <id>` resumes | host-minted `--session-id` (one flag creates AND resumes — the second exec appends at sequence 2; `muse resume` is the interactive TUI, not a headless lane) |
| Fallback | `--fallback-model <list>` | - | - | - | - |
| Health | `claude --version`, `claude auth status` (JSON, exit 0/1 - verified 2.1.200) | `grok --version`, `grok models` (exit 0 in BOTH auth states - output markers decide) | `pi --version`, `pi --list-models --offline` (exit 0 in BOTH auth states - output markers decide; login is TUI-only: `pi` then `/login`) | `opencode --version`, `opencode auth list` (exit 0 in BOTH auth states - "0 credentials" marker decides; login is `opencode auth login`) | `muse --version` only — NO token-free auth status command exists (empty `authStatusArgs`, the seam's "auth not checked" lane); the probe's marker ("missing meta credentials", exit 1, fails fast pre-network) is the sole auth detector |

pi's user config (extensions, skills, AGENTS.md/CLAUDE.md) is deliberately NOT silenced — pi
users self-select for a customized harness, and the subz bridge registers additively beside
whatever they run. Known trade-off: a user extension that opens a `ctx.ui` dialog can stall a
headless turn; if that bites in practice, a per-provider isolation toggle is the follow-up.

Sessions are driven through the non-interactive run + structured output path so responses parse
cleanly back into the orchestrator.

## Health & verification

Provider health is **three tiers, cheapest first** (`SZProviderHealth.swift` /
`SZProviderProbe.swift`), reported as `SZProviderHealthReport` with the six-status vocabulary
`ready · missingCLI · authNeeded · healthFailed · invalidConfig(reserved) · unsupported`:

1. **install** - `/usr/bin/env <cli> --version`, 5s. env's exit 127 → `missingCLI`.
2. **auth** - the CLI's own status command (`authStatusArgs`): `claude auth status` /
   `grok models` / `pi --list-models --offline`, 10s. Nonzero exit →
   `authNeeded` - except an unknown-subcommand error (older CLI), which leaves auth unknown and
   defers to the probe. A ZERO exit whose output contains one of the provider's
   `authFailureMarkers` is also `authNeeded`: not every CLI encodes auth in its status command's
   exit code (grok 0.2.93's `grok models` exits 0 logged out and says "You are not
   authenticated"; pi 0.80.6's `--list-models` exits 0 and says "No models available. Use
   /login…"). Token-free, so tiers 1–2 are safe for the launch pass and the setup sheet's 3s
   re-check loop. A ready transition here is also what triggers a dynamic-catalog re-fetch (pi).
   EMPTY `authStatusArgs` is the documented lane for a CLI with no token-free status command
   (muse 0.1.0 — every auth-revealing invocation is a paid turn): the cheap pass reports
   "Installed — auth not checked" and the probe is the arbiter.
3. **probe** - `healthProbe()`: one real one-shot prompt through the provider's own
   `prepare()`/`launch()`/`parse()` path (default model, no MCP, temp cwd). The only token-costing
   tier; it runs once per provider during first-run setup, on the per-card Test button, and under
   the verifier's `--probe` flag - never on a timer. Logged-out run output is classified via each
   provider's recorded `authFailureMarkers`, and the markers OUTRANK a timeout: a logged-out
   `grok -p` never exits (it prints a device-auth banner and polls for a browser login until
   killed), so the killed run's output showing the login wall reads `authNeeded`, not
   `healthFailed`.

Each provider also vends its remedies as data: `installCommand` (copy-paste) and `loginCommand`
(what the setup sheet's Terminal launcher runs - auth is interactive by design; the app never
attempts it headless). Surfaces: the first-run **Agent Providers sheet**, the AI Settings cards and their
dimmed model menus, run/chat pre-flights ([UI.md](UI.md)), and the headless self-check
`SZApp --verify-agent-providers --json [--probe]` (exit 0 = ≥1 ready, 1 = none, 2 = error;
contract in [APP_SETUP.md](APP_SETUP.md)).

**Testing hook:** `SZ_PATH_OVERRIDE=<dirs>` replaces the entire synthesized search path
(`SZAgentEnvironment.searchPath()`), so a provider-less machine or a shim CLI can be simulated
live for the sheet, the cards, the guards, and the verifier.

**Mid-turn failure surface.** The pre-flights only cover a turn's START; a CLI
that dies mid-turn comes back as a bare non-zero exit, not a thrown error. Every turn funnels
through `deliver`, and each of its callers classifies a failed turn via
`SZHost.providerFailureDetail`: re-run the cheap tiers, and if the turn's provider is no longer
`ready`, land an actionable "stopped working mid-turn - <reason>" line in that scope's
transcript, open the Agent Providers sheet, and (on the run path) put the same detail on the
node's red error pill. A signal death on a still-healthy provider (`SZProcessResult.
uncaughtSignal` - `terminationReason` is captured, so a kill/crash is distinguishable from
`exit(9)`) gets honest killed-or-crashed copy but no sheet: pointing a one-off kill at setup
would be wrong advice. Ordinary agent failures keep their existing copy. Related substrate
guarantee: stop/cancel/timeout kills the CLI's whole descendant tree (`signalProcessTree` -
codex's wrapper spawns the vendor binary as a grandchild, which used to leak).

## Auth & secrets

- CLI providers delegate authentication to their own login mechanisms. The direct ChatGPT
  connection stores its OAuth credentials in macOS Keychain as described above.

## Capability discovery - resolved (2026-06-13)

**claude and muse cannot enumerate models** (no list subcommand; you pass a model alias or
name), so their lists are static. claude's thinking levels *are* enumerable (`--effort` has a
fixed set). Grok, Pi, and OpenCode enumerate through their own CLIs (see below).
(grok, added later, is the exception that proves the manifest right: `grok models` DOES
enumerate, which makes re-verifying its manifest one command - but the manifest stays static,
and the CLI's own docs/flags still can't be trusted for capabilities: its effort flag parses
everywhere and acts nowhere.)

**pi carve-out (2026-07-12): the first runtime-enumerated catalog.** A static manifest cannot
work for pi at all — it is a BYOK multi-provider harness, so the served models depend on which
accounts each USER connected, not on the CLI version. And unlike the older CLIs, pi's own
catalog IS trustworthy capability data: `pi --mode rpc` → `get_available_models` returns
per-model metadata (`thinkingLevelMap`, modalities, context window) measured by the CLI itself,
which satisfies the never-infer rule at runtime. So `SZPiProvider` fetches its catalog from the
CLI (token-free), the host caches it in `provider-catalogs.json` (Application Support) and
re-seeds it at launch — the model menus serve last-known truth offline — and re-fetches when the
cheap health status transitions to ready (login/install landing is exactly when the catalog
changes) or the snapshot is a day old. Model ids are stored qualified (`openai-codex/gpt-5.5`),
the exact `--model` argv token. Until a first successful fetch, pi serves an EMPTY catalog —
the model menus dim and pre-flights refuse, which is the truthful state for a logged-out harness.
Static manifests remain the rule for CLIs that can't enumerate.

**ChatGPT:** the authenticated `/v1/models` catalog is the source of truth, as described above.
It is intentionally not seeded from the engine's model list or from another account's saved catalog.

## Test scenarios

- Health check correctly reports a not-installed vs installed-but-not-authed vs ready provider.
- Starting a Director Agent session with a chosen model/thinking level and exchanging one message works
  end-to-end.
- A killed session is detected and restarted without losing the project.

## ChatGPT verification checkpoint — 2026-09-29

Implementation: `592bc0ec` on `feat/chatgpt-sign-in`. The separate test-helper fix is `6735444a`:
two run-badge test helpers recursively called themselves instead of the production style mapper.

Verified on macOS arm64:

- `swift build` and the full `swift test` run from `SubjectiveZero/Modules` passed.
- `xcodebuild -project SZApp.xcodeproj -scheme SubjectiveZero -configuration Debug test`
  from `SubjectiveZero` passed (416 host tests).
- Real browser authorization returned to SubZ. The connected account supplied the model catalog
  and completed a real inference probe with no Codex, npm, or Node.js on the app's search path.
- A live coding turn used SubZ MCP tools, generated a WebGL gradient, and passed the normal
  compile/promote flow. A viewport readback showed the resulting blue-to-magenta gradient.
- Native view previews checked the branded button, connected account dropdown, and first-use sheet.
  Run `SZ_CONNECTION_PREVIEWS=/tmp/subz-previews swift test --filter renderChatGPTConnectionPreviews`
  from `SubjectiveZero/Modules` to reproduce the card and welcome renders.
- OAuth validation, refresh serialization, archive integrity rejection, direct-provider dispatch,
  account model discovery, and failed/resumed transport behavior have regression coverage.

The Intel archive is pinned to its official checksum but has not been executed on this arm64 Mac.
The worktree stays at `.claude/worktrees/chatgpt-sign-in` pending the user's fresh-onboarding
sign-off; this branch has not been merged into main. The isolated test home and its credentials
were reset for that review, and the fresh onboarding uses normal Keychain storage. The earlier
live integration tests used `SZ_CHATGPT_TEST_FILE_CREDENTIALS=1` (Debug only).

Independent code review requested four fixes, now in `874f8869`:

- Keep model selection and Test available after a failed connection probe.
- Invalidate account catalog cooldowns and discard stale in-flight results when switching accounts.
- Renew credentials before a run when the remaining lifetime cannot cover its timeout plus margin.
- Distinguish same-email registrations with stable suffixes while leaving unique emails uncluttered.

The reviewer rechecked and approved the fixes with no remaining actionable findings. Verification
on the reviewed code passed: `swift build`, all 1,406 package tests, the Xcode app build, and all
418 app-hosted tests. New regressions cover near-expiry renewal, insufficient renewed lifetime,
duplicate account labels, rapid account switches and stale catalog completions, and probe recovery.
A native failed-connection preview verifies that the model picker and Test button remain visible.
Merge remains gated on the user's onboarding approval.

### Provider controls follow-up

Implementation: `fbc73a96`. Provider cards expose default reasoning effort and Fast when the
selected model advertises them. ChatGPT maps `additional_speed_tiers` from the authenticated
catalog; runs and connection probes pass the selected speed to the managed harness. Each run
explicitly sets Fast or default so resuming a conversation cannot retain a previous Fast setting.
Changing a setup default rechecks the connection; a no-op preserves a held failed probe.

The routing enable row uses one SwiftUI button for its label and switch indicator. Fresh-profile
creation and off/on restoration pass host tests. The reported live click failure still needs the
user's confirmation in the rebuilt app; it was not reproduced in an isolated native control test.

Verification: all 1,406 package tests passed, followed by all 328 UI tests after the final indicator
adjustment. The final app build and all 420 app-hosted tests passed. Native previews checked the
connected provider controls and routing row. A local HTTP capture using the downloaded 0.159.0
harness confirmed Fast sends the Responses `priority` tier and switching to default while resuming
the same thread omits it; this check made no live inference request. Independent review approved
the final implementation with no remaining actionable findings.

The updated isolated test app was relaunched with its account and settings preserved. Work remains
on `feat/chatgpt-sign-in` in `.claude/worktrees/chatgpt-sign-in`, pending the user's onboarding and
routing acceptance before merging to main.
