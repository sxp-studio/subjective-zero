# SubjectiveZero - Agent Setup Guide

This document is written for an **LLM setup agent** (Claude Code, Codex, or similar) helping a
user install and verify SubjectiveZero and its agent-provider CLIs. It will be published at
`https://sxp.studio/apps/subjectivezero/app-setup.md`; the in-app **Agent Providers ▸ Setup
Guide** button opens that URL. Humans are welcome too - every step is copy-pasteable.

## Safety rules for setup agents

Operate as **guided automation**, not autonomous installation:

- You MAY inspect the system (`which`, `--version`, status commands), download files, verify
  checksums/signatures, and run the non-destructive checks below without asking.
- You MUST ask the user before: installing or upgrading any CLI, replacing the app bundle,
  launching an auth/login flow, editing shell profiles or PATH, deleting files, or granting
  system permissions.
- NEVER ask the user to paste API keys, tokens, or cookies. SubjectiveZero's providers are
  CLI-only - auth belongs to each CLI's own interactive login, and the app stores no provider
  credentials.
- If a verification step fails suspiciously (checksum mismatch, unexpected signer), stop and
  report; do not work around it.

## Install or update the app

Releases are published as a signed + notarized DMG on GitHub. There is no separate manifest:
the latest release *is* the source of truth.

1. Fetch the latest release and download only its DMG asset:
   `gh release download --repo sxp-studio/subjective-zero --pattern '*.dmg'`
   (or take `SubjectiveZero-<version>.dmg` from
   <https://github.com/sxp-studio/subjective-zero/releases/latest>).
2. Verify before opening — stop and report if either check fails:
   `codesign --verify --deep --strict --verbose=2 /Volumes/SubjectiveZero/SubjectiveZero.app`
   and `spctl -a -t exec -vv /Volumes/SubjectiveZero/SubjectiveZero.app`. Expect the signer
   `Developer ID Application: SXP Studio` and `source=Notarized Developer ID`.
3. Ask the user, then copy the app to `/Applications` and launch it.

After the first install the app updates itself — **SubjectiveZero ▸ Check for Updates…** reads a
signed Sparkle appcast, so later versions do not need this procedure.

## Provider CLI setup

SubjectiveZero drives agent CLIs as subprocesses. At least one provider must be **ready**
(installed + logged in). Each is optional individually; each card in the in-app Agent Providers
sheet shows the same remedies listed here.

### Claude Code (`claude`)

- Install (pick one; ask first):
  - `curl -fsSL https://claude.ai/install.sh | bash`
  - `brew install --cask claude-code`
  - `npm install -g @anthropic-ai/claude-code`
- Health: `claude --version` (exit 0 = installed).
- Auth status: `claude auth status` - prints JSON (`{"loggedIn": true, "authMethod": "…"}`);
  exit 0 = logged in, exit 1 = not. (Verified on claude 2.1.200.)
- Log in: run `claude auth login` (or plain `claude`, then `/login`) in a **terminal the user
  controls** - the flow is interactive; never attempt it headless.

### Codex (`codex`)

- Install (ask first): `npm install -g @openai/codex`. The CLI bundled inside `Codex.app`
  (`/Applications/Codex.app/Contents/Resources/codex`) also works - the app finds it without a
  PATH edit.
- Health: `codex --version`.
- Auth status: `codex login status` - exit 0 = "Logged in using ChatGPT", exit 1 = "Not logged
  in". (Verified on codex-cli 0.141.0.)
- Log in: run `codex login` interactively (browser flow); ask before launching.

### Grok (`grok`)

- Install (ask first): `curl -fsSL https://x.ai/cli/install.sh | bash` (installs to `~/.local/bin`).
- Health: `grok --version`.
- Auth status: `grok models` - **exit 0 in both states**; the output tells: "You are logged in
  with grok.com." vs "You are not authenticated." (Verified on grok 0.2.93.)
- Log in: run `grok login` interactively (browser flow); ask before launching.
- Caution: a logged-out `grok -p …` does NOT fail - it prints a device-auth sign-in banner and
  polls (it may open a browser). Never use a real prompt to test auth; use `grok models`.

### Pi (`pi`)

- Install (pick one; ask first):
  - `npm install -g --ignore-scripts @earendil-works/pi-coding-agent`
  - `curl -fsSL https://pi.dev/install.sh | sh`
- Health: `pi --version`.
- Auth status: `pi --list-models --offline` - **exit 0 in both states**; the output tells: a
  model table when a provider is connected vs "No models available. Use /login …" when none is.
  (Verified on pi 0.80.6.)
- Log in: pi's login is **TUI-only** - run `pi` interactively, then type `/login` and pick a
  provider (ChatGPT Plus/Pro, Claude Pro/Max, GitHub Copilot via OAuth, or an API key). Never
  attempt it headless.
- pi is a multi-provider harness: which models it serves depends on what the USER connected, so
  the app enumerates them from the CLI at runtime instead of shipping a fixed list (the model
  picker is empty until pi is logged in once).
- Caution: a logged-out `pi -p …` without `--offline` can hang with NO output (it stalls on
  provider auth). Never use a real prompt to test auth; use `pi --list-models --offline`.

### opencode (`opencode`)

- Install (ask first): `curl -fsSL https://opencode.ai/install | bash` (installs to `~/.opencode/bin`).
- Health: `opencode --version`.
- Auth status: `opencode auth list` - **exit 0 in both states**; the output tells: a provider line
  and "1 credentials" (or more) when a backend is authed vs "0 credentials" when none is.
  (Verified on opencode 1.18.4.)
- Log in: run `opencode auth login` interactively (pick a provider; browser/OAuth or API key); ask
  before launching.
- opencode is a multi-provider harness like pi: which models it serves depends on what the USER
  authed, so the app enumerates them from the CLI at runtime (`opencode models --verbose`) instead of shipping
  a fixed list (the model picker is empty until at least one provider is authed).
- Choosing the model: pick it in-app from AI Settings ▸ Agent Providers ▸ the opencode card's **Model** menu, or — if opencode
  is showing as **Failing** in Agent Providers (e.g. its default model's quota is exhausted) — from the
  **Model** menu on the opencode card there (picking one re-tests it on the spot). The app also honors
  a `model` you set in your opencode config (whatever `opencode debug config` reports as the resolved
  top-level `model`), so long as opencode still serves it: that becomes the pre-selected default. Absent
  a configured model, the app sets no default at all — runs pass no model flag and opencode's own
  selection carries them, exactly as if you ran `opencode run` yourself.

### Muse Code (`muse`)

- Install (ask first): `curl -fsSL https://dev.meta.ai/install.sh | bash` (installs to
  `~/.local/bin`; the `muse` command is a launcher script that keeps the real binary updated).
- Health: `muse --version` (prints "Muse Code 0.1.0 (0.1.0-R708.1)").
- Auth status: **none exists** (verified 0.1.0) - there is no token-free status command, so the
  app reports "Installed — auth not checked" and the Test probe is what proves auth. A
  credential-less run fails fast (exit 1, "missing meta credentials…") before any network turn.
- Log in (pick one):
  - `muse auth set --api-key-stdin` with a Meta developer account API key (dev.meta.ai) piped on
    stdin - the key never rides argv; it lands in `~/.config/muse/auth.json`.
  - `muse login` interactively (browser device flow); ask before launching.
- Caution - **metered billing with a data-sharing tier**: Muse Spark is pay-per-token. Per
  Meta's launch coverage (UNVERIFIED here - the portal's own terms are account-gated), a heavily
  discounted "Contributor" tier lets Meta train on session data (prompts, outputs, and whatever
  code the agent reads), and accounts may default to it. What IS verified (0.1.0): the tier is
  not selectable from the CLI - a `…-contributor` model id is refused - so whatever tier your
  account is on applies to every run. If you don't want data sharing, read the data terms in
  your dev.meta.ai portal and verify the account is on the Standard tier before running real
  work through muse; consider a spend cap there while you're at it.
- Caution: `muse` self-updates in the background (launcher + binary, hourly check). The app
  suppresses this for its own spawns (`MUSE_NO_AUTO_UPDATE=1`), so user-driven runs are where
  updates land.

The app resolves CLIs on its own synthesized search path (inherited PATH + nvm/volta/bun/cargo/
`~/.local/bin`/`~/.opencode/bin`/Homebrew/`Codex.app` + system dirs), so a CLI visible in the user's
shell is normally visible to the app even when launched from Finder.

## App-level verification

Run the app's self-check (works headless; no window is created):

```
/Applications/SubjectiveZero.app/Contents/MacOS/SZApp --verify-agent-providers --json
```

- Exit codes: `0` = at least one provider ready · `1` = none ready · `2` = internal error.
- Add `--probe` to also run one tiny real prompt per healthy provider (the "actually replies"
  tier). It spends a few tokens; use it for final confirmation, not repeated polling.
- Output is a single JSON report:

```json
{
  "appVersion": "0.2.1", "appBuild": "42",
  "defaultProviderID": "claude",
  "ok": true,
  "generatedAt": "2026-07-03T19:46:18Z",
  "providers": [
    {
      "providerID": "claude",
      "status": "ready",
      "message": "Installed and logged in (claude.ai).",
      "cliPath": "/Users/x/.local/bin/claude",
      "version": "2.1.200 (Claude Code)",
      "probeVerified": false,
      "diagnostics": [
        { "tier": "install", "attemptedCommand": ["claude", "--version"], "exitCode": 0, "timedOut": false },
        { "tier": "auth", "attemptedCommand": ["claude", "auth", "status"], "exitCode": 0, "timedOut": false }
      ]
    }
  ]
}
```

- `status` is one of: `ready` · `missingCLI` · `authNeeded` · `healthFailed` · `invalidConfig` ·
  `unsupported` (the last two are reserved). Failed tiers add an `outputExcerpt` (last 1500
  chars) to their diagnostic - that excerpt is what you act on.
- `defaultProviderID` is absent until the user confirms a default in the in-app sheet.

Setup is complete when: the app launches, the verifier exits 0, and the user has confirmed a
default provider (first launch presents the Agent Providers sheet automatically; it can be
reopened any time with **⌘,**).

## Failure handling

- `missingCLI` → offer the install command above; ask before running it.
- `authNeeded` → launch the provider's own interactive login (ask first), or point the user at
  the in-app card's "Open Terminal to Log In" button. While the sheet is open the card re-checks
  every few seconds and flips green on its own once login lands.
- `healthFailed` → read the diagnostic's `outputExcerpt` and report it verbatim; do not guess.
  A timeout usually means a hung CLI update or network trouble.
- Never edit the app's files, fabricate credentials, or modify `app-state.json` to force a
  status - statuses are re-derived from the CLIs on every check.

## Testing hook (contributors)

`SZ_PATH_OVERRIDE=<dirs>` replaces the app's entire synthesized search path - a provider-less
machine (`SZ_PATH_OVERRIDE=/usr/bin:/bin`) or a shim CLI directory can be simulated for both the
GUI and the verifier. See `docs/AI_PROVIDERS.md`.
