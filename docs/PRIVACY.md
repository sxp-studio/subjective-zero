# Privacy & telemetry

Release builds of SubZ send a small set of anonymous usage events so we can see where new users
get stuck and keep the app healthy. This page lists exactly what that covers.

- **Identity**: a random install ID (a UUID minted on first launch). No account, no email, no
  fingerprinting beyond OS version, CPU architecture, and Mac model.
- **Events**: `app_launch`, `app_active_heartbeat`, `agent_provider_default`, and the first-run
  setup funnel — `setup_shown`, `setup_skipped`, `setup_completed`, `setup_stuck_relaunch` (each
  carries at most provider names and their readiness, e.g. `claude:ready`), and three
  first-session milestones — `prompt_sent`, `turn_ended`, `node_built` — that record only *that*
  a message was sent / an agent turn finished (and whether it failed or timed out) / a generated
  node compiled, with the provider name, chat scope (director/node/build), node count, and minutes
  since launch. Never the message itself.
- **Never sent**: project content, graphs, prompts, chat transcripts, file paths, or code.
- **Opting out**: uncheck **"Share anonymous usage data"** on the welcome screen
  (Help ▸ Welcome). The preference persists in
  `~/Library/Application Support/SubjectiveZero/app-state.json`.
- **Source builds**: DEBUG builds print payloads to the console instead of sending, and builds
  without a bundled reporting key send nothing at all.
