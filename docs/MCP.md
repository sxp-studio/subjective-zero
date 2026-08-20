# MCP

**Package: SZApp (host).** The MCP server is how agents act on the app, and it is the app's
**command bus** - so it lives in the host, alongside the `HostBridge` router that executes commands
([ARCHITECTURE.md](ARCHITECTURE.md#the-host-seam)), **not** in SZAI. Agents notify status, read state,
request UI updates as contracts draft themselves, query the node library, and trigger host
operations; every command resolves to a `SZCore` transaction or a service call via `HostBridge`.
SZAI only supplies provider sessions and the `Orchestrator`. Critically, the MCP surface has a
**1:1 mapping with key UI interactions**, so the same commands agents use can drive automated,
closed-loop testing while the app (and the agents themselves) are built - because both the UI and
MCP go through the one `HostBridge` path.

Transport: TCP, newline-delimited JSON-RPC on 127.0.0.1 (ports 42100–42199). CLIs that speak
stdio MCP reach it through an `nc` bridge (claude/codex via config, grok via a staged config
file). pi ships no MCP support at all, so the pi provider stages a small extension
(`<workdir>/.subz/mcp-bridge.mjs`, bundled in SZAI's resources) that dials the listener directly
and registers each host tool via `pi.registerTool` — same wire protocol, no extra process.

Arguments: a JSON `null` reads as ABSENT, for every tool, stripped once at the bridge's dispatch —
clients routinely serialize a declared-but-unused optional property as `null`, and no handler should
have to tell that apart from an argument the caller meant to send. (Inside an array a null stands: a
list's shape is the caller's, and the value coercions refuse it.)

## Structure

One main server class (in SZApp); commands are defined in **extension files**, grouped by prefix, so
the surface stays navigable as it grows:

```
MCPServer.swift        // server, registration, dispatch, transport
MCP+UI.swift           // ui_*    - view/manipulate UI the way a user would
MCP+Agent.swift        // agent_* - orchestration, state, build, library
MCP+Debug.swift        // debug_* - diagnostics, logs, test hooks
```

(Names illustrative; the pattern is the point.)

## Command naming

Every command is prefixed by domain:

- **`ui_`** - mirrors a user interaction in the native UI. If a user can do it, there's a `ui_`
  command for it (and vice versa). This is what makes the UI testable headlessly.
- **`agent_`** - orchestration and host operations agents need: read/write state, apply the
  Director Agent's plan, spawn coding agents, stage writes, compile, query the library, report status.
- **`debug_`** - diagnostics and test scaffolding: dump logs, fetch build errors, snapshot state,
  record/replay.

## Representative surface

Illustrative, not exhaustive - grouped to show coverage of the [core loop](CORE_LOOP.md).

**`ui_` (1:1 with the Node Editor / panels)**
- `ui_add_prompt_node`, `ui_remove_node`, `ui_move_node`  // placements snap to the canvas grid while
                                            // snap-to-grid is on (same pref as human drags); the
                                            // response echoes the applied x/y
- `ui_add_source_node`                      // image/video files → source nodes; mirrors dropping them
                                            // on the canvas (same classifier, stagger, and "last node
                                            // takes the render endpoint"). Rejects the whole call on a
                                            // missing or non-media path
- `ui_add_library_node`                     // a built-in library node verbatim (Node.swift + its Card.swift
                                            // when it ships one); a contract declaring `card` lands with it ON
- `binding_learn_start/stop/state`,        // controller nodes (midi.macos, osc-input): arm learn, poll the
  `binding_commit`, `binding_remove`        // moved control ({armed, seen, key, value01}), commit it as a
                                            // mappings row + derived float output (+ data edge with `target`),
                                            // remove by output port — one store transaction each
- `ui_set_node_body`                        // none | preview | custom — a node's body region (the custom
                                            // card = the node's Card.swift; cols/rows/pinned = its footprint)
- `ui_connect`, `ui_disconnect`            // flow or data edges
- `ui_update_node`                          // title, sfSymbol, prompt, summary, permissions → triggers reflow.
                                            // `complexity` (light|standard|heavy) records the Director's grade
                                            // of the node's implementation task — run-scoped routing state the
                                            // dispatch reads, not node data; frozen once a coding turn ran
- `ui_edit_ports`                           // the ONLY way to add/retype/remove ports; omission preserves,
                                            // removal is explicit. Editing a built node's ports marks it
                                            // `needsRebuild` (it keeps rendering its old code until a Coding
                                            // Agent regenerates it) and joins it to any run in flight.
- `ui_set_input_default`                    // value for an unconnected input
- `ui_toggle_display`                       // choose which texture output renders
- `ui_split_node`, `ui_merge_nodes`         // user-initiated; host applies one transaction. Optional
                                            // `instruction` steers HOW ("a blur stage then a sharpen
                                            // stage") — woven into each piece's seed prompt. Pieces are
                                            // STAGED (hidden) while the original keeps rendering, then
                                            // committed — or rolled back, so a failed split never
                                            // destroys the original. Joins an in-flight run; one staged
                                            // op at a time
- `ui_run`, `ui_send_chat`                  // schedule a task / send a chat message to an agent.
                                            // `ui_run` NEVER refuses for being second: a task asked
                                            // for while another runs is queued and starts when the
                                            // work it needs is free (`{status:"queued", position}`)
- `ui_amend_task`, `ui_cancel_task`         // fold words into — or drop — work SCHEDULED and not yet
                                            // started. Merging two asks is an amend plus a cancel.
                                            // Both refuse a task already running: that is a steer,
                                            // sent with ui_send_chat to its agents
- `ui_set_provider`                         // active provider + optional model / reasoning_effort /
                                            // fast_mode (the global default envelope; a provider
                                            // CHANGE resets agent sessions and is refused while
                                            // busy; response echoes the resolved selection plus
                                            // `active_profile` — a routing profile may override
                                            // the selection per graph position)
- `ui_set_routing_profile`                  // activate a saved model-routing profile by name, or
                                            // Off (null/""/omitted). Refused while a run is in
                                            // flight and for an unknown name (the error lists the
                                            // saved names); switches govern NEW conversations only
                                            // — live threads keep the envelope that opened them.
                                            // Echoes {active_profile}
- `ui_routing_profiles`                     // {profiles, active_profile, env_pinned} — the saved
                                            // profiles and which governs (env_pinned = the
                                            // SZ_MODEL_ROUTING launch pin, when it names one)
- `ui_show_panel`, `ui_close_panel`, `ui_move_panel`  // panel layout: reopen / ✕ / header drag & drop
- `ui_clone_panel`, `ui_popout_panel`, `ui_dock_panel`  // viewport clones + pop-out windows (panels addressed by token, e.g. "viewport:2")

**`agent_` (orchestration + host ops)**
- `agent_read_graph`, `agent_read_node`         // a built node that needs a rebuild carries `rebuildReason`
                                            // (contractChanged | intentChanged | sourceMismatch), plus `rebuildDetail`
                                            // when there is evidence to name (the audit's offending lines / the ports
                                            // off the build stamp; an intentChanged node has none - its prompt is it)
- `agent_view_frame` - **real framebuffer readback** of a node's texture output, returned as an inline
  image (base64 PNG) the agent's model actually sees, so it can reason on its VFX result. Pixel-perfect
  but downscaled to fit the token budget (default 768px long edge; `maxSize` overrides). `node` (+
  optional `port`, default: the node's first texture output) reads that node's last-rendered texture off
  the render pool without moving the viewport - never `ui_toggle_display` just to look. Without `node`
  it captures the CURRENT display endpoint (what's on screen).
- `agent_apply_plan`, `agent_spawn_coding_agents`, `agent_await_all`
- `agent_write_node_staged`, `agent_compile_node`   // `card` = an optional Card.swift; a red card blocks the promote
- `agent_library_index`, `agent_library_card`, `agent_library_source`  // 3-tier, see NODE_LIBRARY.md
                                            // (`source` takes `file: "Card.swift"` for a node that ships a card)
  (`index` built M3; `card` + `source` built M4 - `card`/`source` return raw text, `index` returns JSON)
- `agent_report_status`, `agent_report_complete`

**`debug_` (diagnostics + tests)**
- `debug_dump_logs` (build / agent / runtime)
- `debug_get_build_errors`
- `debug_card_mount`                        // a node's custom-card mount: state / warning / backdrop rect /
                                            // bindingSource (contract has mappings:string + lastKey:string)
- `debug_snapshot_state`, `debug_load_state`
- `debug_chat_transcript` - a scope's transcript as JSON, including each message's
  `timestamp`/`duration`/`usage`/`breakdown` where present (the per-turn debug breakdown).
- `debug_turn_timings` - the profiling read path: completed agent turns per scope as
  `{turnID, start, duration, usage, events}` — the same phase data the in-app turn breakdown
  shows (queue wait, first output, tool spans, compile/promote, the CLI's own report), plus the
  latest run rollup on the Director's run-complete narration. Events carry `id`/`parent` (span
  hierarchy — a compile fence nests under its `agent_compile_node` span) and `runID` (groups a
  run's turns across scopes). Collection is `SZTrace` debug fences (`SZTrace.span(...) { }`,
  see `Modules/Sources/SZCore/SZTrace.swift`), gated by `SZ_TRACE` (default: on in DEBUG only).
- `debug_run_summary` - the latest (or a chosen) run's report as text — same output as the
  Profiler's Copy Summary.
- `debug_run_tokens` - the latest (or a chosen) run's per-turn token report as text (in with
  cached share, out with reasoning share, cost) — same output as the Profiler's Copy Tokens.
  Per-turn totals: CLIs report usage once, at turn end.
- `debug_turn_prompt` - the rendered prompt a turn ACTUALLY sent to its CLI, verbatim —
  inspect what an agent was briefed with. Survives relaunches: the newest 40 turns' prompts
  AND tool-result payloads are captured under
  `~/Library/Application Support/SubjectiveZero/debug-turns/<turnID>/` (debug builds only).
  Timing events also carry `addedTokens` — the approximate context weight each action
  (prompt, tool result) added to the turn's "in" count — and, on `provider.report` rows,
  `calls` — the CLI's own count of the model calls inside the turn (reported input ≈ its
  context × `calls`, so the division recovers context-per-call; absent when the CLI reports
  no count).
- `debug_set_paused` - freeze/resume the render clock (mirrors the HUD Pause/Play) so successive
  `agent_view_frame`s render the same instant: the deterministic way to A/B a live input.
- `debug_set_routing` - the headless A/B harness's routing tool: upsert a full routing profile
  (an `SZRoutingProfile` JSON object) and/or switch the active one, through the SAME host
  mutators as AI Settings — persistence and the busy guard apply, and a switch refused mid-run
  comes back as `{refused: <why>}`.
- `debug_routing_state` - the routing world as JSON: active + saved profiles, the raw
  `SZ_MODEL_ROUTING` pin, recorded node grades (uuid → light|standard|heavy), and the resolved
  table as a delivery starting now would bind it — per-position "provider · model · effort ·
  fast" strings per filled slot ({agent: {slot: choice}}) plus the fallback and the resolution's
  fallback notes (read without consuming the once-per-state narration). A pin naming a missing
  profile reads as `{refused: <detail>}`.
- `debug_record_session`, `debug_replay_session` *(deferred - not a V1 gate; see below)*

## V1 scope (functional minimum + verify hooks)

The surface above is the *target*. **V1 implements only the functional minimum**: the commands the
app genuinely needs to run the core loop end to end, plus the `debug_` hooks needed to drive and
verify it headlessly in a closed loop.

- **In V1:** the `ui_`/`agent_` commands exercised by the core loop ([CORE_LOOP.md](CORE_LOOP.md))
  and `agent_view_frame` / `debug_get_build_errors` / `debug_snapshot_state` for verification.
- **Deferred (not a V1 gate):** `debug_record_session` / `debug_replay_session`, and exhaustive
  "every UI affordance has a `ui_` command" completeness. The **1:1 principle stays** - we add `ui_`
  commands as the matching UI affordances land - but it is not a gate to clear up front.

## Ownership & safety

- **State and graph mutations are host-owned.** `ui_*`/`agent_*` commands that change the graph
  produce **commands/transactions** on SZCore ([STATE.md](STATE.md)) - agents never write project
  state files directly. This is what keeps undo/redo and history correct regardless of who acted.
- **GPU/build stay in the runtime.** `agent_compile_node` asks SZRuntime to build staged source;
  agents don't invoke swiftc or touch Metal themselves ([RUNTIME.md](RUNTIME.md)).
- **Permissions per session.** Which MCP commands a session may call is part of its
  `SessionConfig` ([AI_PROVIDERS.md](AI_PROVIDERS.md)).

## Closed-loop testing

Because `ui_*` is a faithful mirror of user interaction, a test harness can:

1. `ui_add_prompt_node` × N, `ui_connect`, `ui_run`,
2. let agents drive (or script `agent_*` directly),
3. assert via `debug_snapshot_state` / `debug_get_build_errors`,
4. confirm a frame rendered (a `debug_` viewport-capture hook).

This is the **closed-loop verification** that makes building the app with agents tractable -
treat it as a first-class part of the surface, not an afterthought.

## Test scenarios

- A scripted `ui_*` sequence builds the grayscale-camera graph with no human and renders a frame.
- `ui_update_node` / `ui_edit_ports` from an agent reflow the node UI identically to a user-equivalent edit.
- `debug_record_session` then `debug_replay_session` reproduces a build deterministically.
