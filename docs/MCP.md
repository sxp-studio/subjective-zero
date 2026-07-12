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
- `ui_connect`, `ui_disconnect`            // flow or data edges
- `ui_update_node`                          // title, sfSymbol, prompt, summary, permissions → triggers reflow
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
- `ui_run`, `ui_send_chat`                  // start Director Agent / send a chat message to an agent
- `ui_set_provider`                         // active provider + optional model / reasoning_effort /
                                            // fast_mode (mirrors the composer picker; a provider
                                            // CHANGE resets agent sessions and is refused while
                                            // busy; response echoes the resolved selection)
- `ui_show_panel`, `ui_close_panel`, `ui_move_panel`  // panel layout: reopen / ✕ / header drag & drop

**`agent_` (orchestration + host ops)**
- `agent_read_graph`, `agent_read_node`
- `agent_view_frame` - **real framebuffer readback** of the render endpoint, returned as an inline
  image (base64 PNG) the agent's model actually sees, so it can reason on its VFX result. Pixel-perfect
  but downscaled to fit the token budget (default 768px long edge; `maxSize` overrides). Captures the
  CURRENT display endpoint (what's on screen) - call `ui_toggle_display` first to retarget the viewport.
- `agent_apply_plan`, `agent_spawn_coding_agents`, `agent_await_all`
- `agent_write_node_staged`, `agent_compile_node`
- `agent_library_index`, `agent_library_card`, `agent_library_source`  // 3-tier, see NODE_LIBRARY.md
  (`index` built M3; `card` + `source` built M4 - `card`/`source` return raw text, `index` returns JSON)
- `agent_report_status`, `agent_report_complete`

**`debug_` (diagnostics + tests)**
- `debug_dump_logs` (build / agent / runtime)
- `debug_get_build_errors`
- `debug_snapshot_state`, `debug_load_state`
- `debug_set_paused` - freeze/resume the render clock (mirrors the HUD Pause/Play) so successive
  `agent_view_frame`s render the same instant: the deterministic way to A/B a live input.
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
