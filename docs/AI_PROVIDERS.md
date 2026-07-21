# AI Providers

**Package: SZAI.** SubZ wraps third-party AI coding tools behind a consistent interface so the
rest of the app calls "an agent session" without caring which CLI is underneath. This doc covers
the provider model, what we surface per provider, sessions, and health - plus the one genuinely
open question (capability discovery).

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
    var id: String { get }                       // "claude-code", "codex"
    func healthCheck() async -> ProviderHealth    // installed? authed? version?
    func capabilities() async -> ProviderCapabilities  // models, thinking levels, fast? (see open question)
    func startSession(_ config: SessionConfig) async throws -> SZSession
}
```

## Built-in providers (initial)

- **claude code** - CLI only.
- **codex** - CLI, and CLI driven through Codex.app.
- **grok** - CLI only (x.ai; added 2026-07, verified against grok 0.2.93).
- **pi** - CLI only (pi.dev, `@earendil-works/pi-coding-agent`; added 2026-07, verified against
  pi 0.80.6). A BYOK multi-provider harness — the user connects their own accounts (ChatGPT
  Plus/Pro, Claude Pro/Max, Copilot OAuth, or API keys) and pi routes to them; subz drives only
  the harness. The first provider with a RUNTIME-enumerated model catalog (see Capability
  discovery below).
- **opencode** - CLI only (opencode.ai; added 2026-07, verified against opencode 1.18.4). Also a BYOK
  multi-provider harness (like pi) with a RUNTIME-enumerated catalog — the user authes their own
  backends (`opencode auth login`) and opencode routes to them; subz drives the harness. Distinct
  from pi in sessions: opencode mints its own `ses_…` id, parsed back from the stream (codex-style).

For each, we wrap and surface to the UI:

- **models** available (e.g. Opus, Sonnet, …) - from the static manifest (claude/codex can't
  enumerate models; pi is the runtime-enumerated exception — see Capability discovery below),
- **thinking** level - claude: `--effort {low, medium, high, xhigh, max}`; codex: a `-c`
  reasoning config key (not enumerable, manifest-declared).

> **Shipped (supersedes the two paragraphs below):** the static capability
> manifest IS each provider's Swift constants - `models` (PINNED version ids + display labels,
> `SZProviderModel`: "claude-opus-4-8" → "Opus 4.8", "gpt-5.6-terra" → "GPT-5.6 Terra" - never
> floating aliases, so a version label can't silently re-point; new models ship via app updates, and a
> type-any-model manual override stays deferred) / `defaultModel` /
> `supportedReasoningEfforts` (`[]` = the CLI has no effort concept; claude `--effort`
> low/medium/high/xhigh/max, uniform across its three models - recorded from claude 2.1.206; codex provider default
> low/medium/high/xhigh - recorded from codex-cli 0.144.1's `models_cache.json`, with per-model
> overrides where a model diverges: GPT-5.6 Sol and Terra add max/ultra, GPT-5.6 Luna adds max, and
> Sol alone defaults to `low` instead of `medium`) / `supportsFastMode` (per-model too: the
> provider-level flag says the CLI *can* express fast mode in argv, and
> `supportsFastMode(for: model)` says whether the CLI will *enable* it for that model. claude accepts
> the settings blob for all three models — it swallows any unknown settings key silently — but its own
> `result.fast_mode_state` reads `on` only for Opus 4.8, so Fable 5 and Sonnet 5 declare
> `supportsFastMode: false` and the composer hides the toggle. Note "enabled" ≠ "served fast": whether
> a turn actually runs fast is an account entitlement the response reports per turn as `usage.speed`,
> which reads `standard` while an org's fast-mode spend is disabled — not a model property, and not
> modeled here. codex's five models are unmeasured on this axis, so none overrides and all inherit
> `true`. grok declares NO effort menu and `supportsFastMode: false`: grok 0.2.93's
> `--reasoning-effort` silently accepts any value — even an invalid token, exit 0, no warning, so
> acceptance proves nothing — and measured comparisons (`none` vs `high`, `minimal` vs `xhigh`,
> both models, 2026-07-12) showed no change in thought volume, so the flag is treated as not
> honoured and argv never carries it). Model ids and effort tokens
> are live-verified against the CLI, never inferred: a slug the ChatGPT backend won't serve is
> rejected with a 400 that no in-process test can see, so a model joins the list only once the
> manifest carries it AND a live launch returns clean (GPT-5.6 Sol shipped announced-but-ungated for
> a window, 400ing every turn). grok's two ids (`grok-composer-2.5-fast` — the CLI's own default —
> and `grok-build`) are the CLI's own enumeration: uniquely among our CLIs, `grok models` lists
> them, so re-verification on a CLI update is one command; note `grok-build` is unversioned, and
> there is no versioned alternative to pin. Picking a new model resets that provider's agent
> sessions (a thread is bound to the model that opened it); changing effort or fast mode does not.
> Selection is
> **global** (not per agent role -
> per-role overrides deferred to agent profiles), edited in the chat composer's
> `SZProviderGenerationPickerView`, persisted per provider in app-state.json
> ([STATE.md](STATE.md)), clamped at read by `resolvedGenerationSettings`, and stamped into
> every `SZAgentRunRequest` (runs, Director turns, chats). Fast mode DID land as launch argv -
> claude via an inline `--settings {"fastMode":true}` blob, codex via
> `-c service_tier="fast" -c features.fast_mode=true`.

These choices are set per agent role (Director Agent vs Coding Agent can differ) in settings.

## Sessions

- A session is a long-lived agent process bound to one provider + config.
- The Director Agent and each Coding Agent run as sessions; the `Orchestrator` routes messages to the right
  session and streams responses back (V1 orchestration is hardcoded Swift, not yet a behavior tree -
  see [AGENT_ORCHESTRATION.md](AGENT_ORCHESTRATION.md)).
- Sessions are granted the SubZ **MCP server** as a tool so agents can act on the app. Permissions
  (which MCP commands, filesystem scope) are part of `SessionConfig`.
- Failure recovery: a crashed/stalled session is restarted by the host; in-flight tree state
  decides whether to resume or re-prompt.

## CLI integration (verified 2026-06-13; grok column 2026-07-12; pi column 2026-07-12; opencode column 2026-07-21)

Concrete facts the adapters rely on, from the installed CLIs (claude code 2.1.177, codex-cli
0.137.0, grok 0.2.93, pi 0.80.6, opencode 1.18.4):

| Need | claude code | codex | grok | pi | opencode |
|---|---|---|---|---|---|
| Non-interactive run | `claude -p/--print` | `codex exec` (alias `e`) | `grok -p/--single` | `pi -p --mode json` (prompt is a trailing positional; stdin MUST reach EOF or the CLI hangs with zero output — the runner wires /dev/null) | `opencode run` (prompt trailing positional; `--auto` bypasses permission prompts) |
| Structured / streamed output | `--output-format json\|stream-json`, `--json-schema <s>` | `--json` (JSONL), `--output-schema <file>` | `--output-format json\|streaming-json` (token-level `thought`/`text` chunks; NO tool events) | `--mode json` (JSONL events: session header, message/turn lifecycle, `tool_execution_*`); CAUTION: a FAILED turn still exits 0 — `parse()` reads the last assistant `stopReason` | `--format json` (JSONL: `step_start`/`reasoning`/`tool_use`/`text`/`step_finish`, each carrying `sessionID`); a failed turn exits nonzero AND emits a top-level `error` event |
| Model selection | `--model <alias\|full>` | `-m/--model` or `-c model="…"` (`--oss` for local) | `-m/--model` (enumerable via `grok models`) | `--model <provider/id>` qualified (catalog enumerated at runtime via `--mode rpc` → `get_available_models`) | `-m <provider/model>` qualified (catalog enumerated at runtime via `opencode models --verbose`) |
| Thinking level | `--effort <low\|medium\|high\|xhigh\|max>` | `-c` reasoning config key | `--reasoning-effort` exists but is NOT honoured (measured) - never emitted | `--thinking <minimal\|low\|medium\|high\|xhigh\|max>`, per-model menus derived from the catalog's `thinkingLevelMap`; out-of-menu values silently clamp | `--variant <low\|medium\|high\|xhigh\|max>`, per-model menus from each model's `variants` map (maps to OpenAI's `reasoningEffort`); `none` dropped |
| Attach SubZ MCP server | `--mcp-config <json>` | `codex mcp` / config | `<cwd>/.grok/config.toml`, staged per run by `prepare()` (no per-invocation flag) | no built-in MCP: `prepare()` stages `<cwd>/.subz/mcp-bridge.mjs` (a pi extension speaking the host's TCP protocol), loaded via `--extension` | inline `OPENCODE_CONFIG_CONTENT` env carrying an `mcp.subz` local (nc) server; NO cwd file (opencode roots a session at the git repo and drops a cwd-staged `opencode.json`), no per-invocation flag |
| Sessions | host-minted `--session-id`, `--resume <id>` | id parsed from `thread.started` | host-minted `--session-id`, `--resume <id>` | host-minted `--session-id` (one flag creates AND resumes; header echoes it) | id parsed from any event's `sessionID` (`ses_…`); `-s <id>` resumes |
| Fallback | `--fallback-model <list>` | - | - | - | - |
| Health | `claude --version`, `claude auth status` (JSON, exit 0/1 - verified 2.1.200) | `codex --version`, `codex login status` (exit 0/1 - verified 0.141.0) | `grok --version`, `grok models` (exit 0 in BOTH auth states - output markers decide) | `pi --version`, `pi --list-models --offline` (exit 0 in BOTH auth states - output markers decide; login is TUI-only: `pi` then `/login`) | `opencode --version`, `opencode auth list` (exit 0 in BOTH auth states - "0 credentials" marker decides; login is `opencode auth login`) |

pi's user config (extensions, skills, AGENTS.md/CLAUDE.md) is deliberately NOT silenced — pi
users self-select for a customized harness, and the subz bridge registers additively beside
whatever they run. Known trade-off: a user extension that opens a `ctx.ui` dialog can stall a
headless turn; if that bites in practice, a per-provider isolation toggle is the follow-up.

Sessions are driven through the non-interactive run + structured output path so responses parse
cleanly back into the orchestrator.

## Health & verification (shipped)

Provider health is **three tiers, cheapest first** (`SZProviderHealth.swift` /
`SZProviderProbe.swift`), reported as `SZProviderHealthReport` with the six-status vocabulary
`ready · missingCLI · authNeeded · healthFailed · invalidConfig(reserved) · unsupported`:

1. **install** - `/usr/bin/env <cli> --version`, 5s. env's exit 127 → `missingCLI`.
2. **auth** - the CLI's own status command (`authStatusArgs`): `claude auth status` /
   `codex login status` / `grok models` / `pi --list-models --offline`, 10s. Nonzero exit →
   `authNeeded` - except an unknown-subcommand error (older CLI), which leaves auth unknown and
   defers to the probe. A ZERO exit whose output contains one of the provider's
   `authFailureMarkers` is also `authNeeded`: not every CLI encodes auth in its status command's
   exit code (grok 0.2.93's `grok models` exits 0 logged out and says "You are not
   authenticated"; pi 0.80.6's `--list-models` exits 0 and says "No models available. Use
   /login…"). Token-free, so tiers 1–2 are safe for the launch pass and the setup sheet's 3s
   re-check loop. A ready transition here is also what triggers a dynamic-catalog re-fetch (pi).
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
attempts it headless). Surfaces: the first-run **Agent Providers sheet**, the HUD picker's
dimmed items, run/chat pre-flights ([UI.md](UI.md)), and the headless self-check
`SZApp --verify-agent-providers --json [--probe]` (exit 0 = ≥1 ready, 1 = none, 2 = error;
contract in [APP_SETUP.md](APP_SETUP.md)).

**Testing hook:** `SZ_PATH_OVERRIDE=<dirs>` replaces the entire synthesized search path
(`SZAgentEnvironment.searchPath()`), so a provider-less machine or a shim CLI can be simulated
live for the sheet, the picker, the guards, and the verifier.

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

- Auth is delegated to each underlying tool's own mechanism (its CLI login). SubZ does not store
  provider credentials itself in V1; it reads installed/authenticated state via the adapter.

## Capability discovery - resolved (2026-06-13)

We investigated the real CLIs. **Neither claude code nor codex can enumerate models** (no
`list-models` subcommand; you simply pass a model alias/name). claude's thinking levels *are*
enumerable (`--effort` has a fixed set); codex's reasoning effort is a config key, not
enumerable. So "ask the CLI for capabilities" is a dead end for the thing we cared about most.
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
re-seeds it at launch — the picker serves last-known truth offline — and re-fetches when the
cheap health status transitions to ready (login/install landing is exactly when the catalog
changes) or the snapshot is a day old. Model ids are stored qualified (`openai-codex/gpt-5.5`),
the exact `--model` argv token. Until a first successful fetch, pi serves an EMPTY catalog —
the picker dims and pre-flights refuse, which is the truthful state for a logged-out harness.
Static manifests remain the rule for CLIs that can't enumerate.

**Decision:**

- **`capabilities()` reads a static manifest** (per provider, ideally keyed by detected CLI
  version) - the source of truth for available **models** and **thinking levels**. claude's
  `--effort` set can be hard-coded from the known flag values; everything else is manifest data.
- **The CLI is used for health + session control, not capability discovery** (`doctor`/`auth`/
  `login`; see CLI integration above).
- **A manual override** in settings lets a user type a model name the manifest doesn't list yet
  (both CLIs accept arbitrary `--model`), so we're never blocked by a stale manifest.
- **No probing** - too slow/noisy for what is effectively static data.

This keeps the adapter simple and the settings UI instant, while the manual override absorbs new
models between manifest updates.

## Test scenarios

- Health check correctly reports a not-installed vs installed-but-not-authed vs ready provider.
- Starting a Director Agent session with a chosen model/thinking level and exchanging one message works
  end-to-end.
- A killed session is detected and restarted without losing the project.
