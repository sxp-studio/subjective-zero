// SPDX-License-Identifier: AGPL-3.0-only
// The `ui_*` MCP surface — user-equivalent graph edits (docs/MCP.md). These mirror what a user does
// in the Node Editor; both land here so headless agent runs and user actions share one path. The edits
// are thin arg-parsers over the named `SZStore` graph-edit ops (SZStore+GraphEdits.swift) — the SAME
// ops the SwiftUI editor calls, so user and agent edits ride one tested mutation path. The
// `ui_run` entry point routes to the host orchestrator. (TODO: route the edits through the
// Command/undo engine once undo/checkpoints ship.)
import Foundation
import SZAI
import SZCore
import SZUI   // SZNodeLayout.gridPitch/snapped — agent placement lands on the same grid as human input

extension SZHostBridge {
    nonisolated static var uiToolDefinitions: [[String: Any]] {
        [
            tool("ui_add_prompt_node", "Add a prompt node; returns its id and placed x/y (while snap-to-grid is on, the card's edges snap to the \(Int(SZNodeLayout.gridPitch))pt canvas grid — the echoed x/y center is the applied truth).",
                 properties: [
                    "prompt": ["type": "string", "description": "the node's logic prompt"],
                    "x": ["type": "number"], "y": ["type": "number"],
                 ]),
            tool("ui_add_source_node", "Add media SOURCE nodes reading files from disk — mirrors dragging them onto the canvas. Images become an `image-file` node, videos a `video-file` node, both with `path` pre-set; audio and other types are rejected. Cards stagger down-right and the LAST takes the viewport, as a drop does. Rejects the whole call if any path is missing or isn't an image/video, so you never get a half-built graph.",
                 properties: [
                    "paths": ["type": "array", "items": ["type": "string"],
                              "description": "absolute paths to image/video files (≥1)"],
                    "x": ["type": "number"], "y": ["type": "number"],
                 ]),
            tool("ui_add_library_node", "Add a built-in library node verbatim (see agent_library_index for ids, e.g. `corner-pin`, `checkerboard`) — mirrors placing one from the palette. Copies its Node.swift (and Card.swift, when the node ships a custom card — a card that draws over the node's output lands ON, others wait in the context menu) into the project, compiles, and returns the new node id.",
                 properties: [
                    "library": ["type": "string", "description": "the NodeLibrary id"],
                    "x": ["type": "number"], "y": ["type": "number"],
                 ]),
            tool("ui_connect", "Connect one node's output port to another's input port; returns the connection id. A data input holds at most one incoming connection — connecting to an occupied data input replaces the existing connection. Repeating an existing connection returns its id unchanged. Data edges must keep the graph acyclic: a data connection that would close a cycle is refused with {status: \"refused\", reason} naming the path — rewire or drop an edge instead. A flow (intent) edge is refused the same way when it would run in a circle, counting the arrows already drawn, since only one edge of a ring could ever be laid; nothing about ports refuses an arrow. A flow edge given an explicit fromPort/toPort naming a declared data port is PINNED to that slot (the user-drop-on-a-blue-dot semantics) — omit the ports for plain node-to-node intent.",
                 properties: [
                    "from": ["type": "string"], "fromPort": ["type": "string"],
                    "to": ["type": "string"], "toPort": ["type": "string"],
                    "kind": ["type": "string", "enum": ["data", "flow"]],
                 ]),
            tool("ui_disconnect", "Remove a connection by id.",
                 properties: ["connection": ["type": "string"]]),
            tool("ui_update_node", "Update a node's title / sfSymbol / prompt / summary (reflows its UI). While briefing, `complexity` (light | standard | heavy) is your one-word read of the implementation task — it may pick the model that implements it. Assess the task, not the node's importance; an unassessed node runs on the standard route.",
                 properties: [
                    "node": ["type": "string"],
                    "title": ["type": "string"], "sfSymbol": ["type": "string"],
                    "prompt": ["type": "string"], "summary": ["type": "string"],
                    "complexity": ["type": "string", "enum": ["light", "standard", "heavy"],
                                   "description": "your one-word read of the implementation task"],
                    "permissions": ["type": "array", "items": ["type": "string"],
                                    "description": "entitlements the node needs (camera, microphone)"],
                 ]),
            tool("ui_edit_ports", "Change a node's typed I/O. The ONLY way to add, retype, or remove a port — `ui_update_node` cannot touch the port surface. Omitted ports are left alone; removal is explicit, so you can never drop a control by forgetting to re-send it. `upsert` matches by name: re-sending a port rewrites its declaration (that is how you retype it, or move a slider's range) and keeps the value the port already holds, along with any control hint you leave out. `ui_set_input_default` is the only way to change a value. A retype, or withdrawing an `enum` option that is in use, drops the value and the reply lists it in `droppedValues`. Editing the surface of an already-implemented node marks it for rebuild (`needsRebuild`) and joins it to any run in flight — it keeps rendering its old build until its Coding Agent regenerates it. Data edges and the render endpoint that name a removed or retyped port are dropped.",
                 properties: [
                    "node": ["type": "string"],
                    "inputs": ["type": "object", "description": "{ upsert: [Port], remove: [String] }"],
                    "outputs": ["type": "object", "description": "{ upsert: [Port], remove: [String] }"],
                 ]),
            tool("ui_move_node", "Move a node to a new canvas position; returns the applied x/y (while snap-to-grid is on, the card's edges snap to the \(Int(SZNodeLayout.gridPitch))pt canvas grid — the echoed x/y center is the applied truth).",
                 properties: [
                    "node": ["type": "string"],
                    "x": ["type": "number"], "y": ["type": "number"],
                 ]),
            tool("ui_remove_node", "Remove a node (and its connections) by id.",
                 properties: ["node": ["type": "string"]]),
            tool("ui_split_node", "Split a node into a linear pipeline of `pieces` prompt stages (default 2), reconciling contracts + wiring: external inputs feed the first stage, the last feeds external outputs (+ the render endpoint), stages are texture-connected between. The original node's source is fed to the stage agents to divide. Returns the new piece ids (first→last). Mirrors the editor's right-click Split. By default (`run`) the stages are staged hidden, implemented, then swapped in when the run commits — or rolled back if a stage fails. Pass `run:false` to apply the split immediately and leave drafts.",
                 properties: [
                    "node": ["type": "string"],
                    "pieces": ["type": "number", "description": "stage count (≥2, default 2)"],
                    "run": ["type": "boolean", "description": "auto-implement the stages (default true)"],
                    "instruction": ["type": "string", "description": "optional steer for HOW to divide it (\"a blur stage then a sharpen stage\") — pass the user's words; guidance for the stage agents, not the stages' prompt text"],
                 ]),
            tool("ui_merge_nodes", "Merge an adjacent, data-connected linear chain of nodes into one prompt node, reconciling external connections + the render endpoint (internal edges dropped). The constituents' sources are fed to the merge agent to fuse. Returns the merged node id. Mirrors the editor's Merge Selected. By default (`run`) the merged node is staged hidden, implemented, then swapped in when the run commits — or rolled back if it fails. Pass `run:false` to apply the merge immediately and leave a draft.",
                 properties: [
                    "nodes": ["type": "array", "items": ["type": "string"],
                              "description": "node ids forming a connected linear data chain (≥2)"],
                    "run": ["type": "boolean", "description": "auto-implement the merged node (default true)"],
                    "instruction": ["type": "string", "description": "optional steer for HOW to fuse them (\"favour performance\") — pass the user's words; guidance, not the merged node's prompt text"],
                 ]),
            tool("ui_tidy_graph", "Auto-layout the whole graph into clean left-to-right dependency columns (upstream nodes left of downstream), mirroring Graph ▸ Tidy Graph. Preserves the graph's overall midpoint. Takes no arguments; returns the applied `[node, x, y]` centers (empty if the graph has no nodes).",
                 properties: [:]),
            tool("ui_set_provider", "Set the active provider (and optionally its model / reasoning effort / fast mode) for new agent sessions (runs + a fresh Director Agent chat). The command-bus mirror of AI Settings > Providers (the global default envelope). NOTE: changing the provider resets all agent sessions (transcripts survive; each next message rebuilds context from its transcript) and is refused while a run or chat turn is in flight. The options apply to the provider being set and must be values it supports. Returns the resolved selection, plus `active_profile`: an active routing profile may still override this selection per graph position.",
                 properties: [
                    "provider": ["type": "string",
                                 "enum": SZProviderRegistry.shared.providers.map(\.id)],
                    "model": ["type": "string", "description": "one of the provider's models (omit = keep/default)"],
                    "reasoning_effort": ["type": "string", "description": "one of the provider's supported efforts (omit = keep/default; unsupported on claude)"],
                    "fast_mode": ["type": "boolean", "description": "toggle the provider's fast tier (omit = keep/default)"],
                 ], agentCallable: false),   // user-level setting; resets all sessions — not an agent action
            tool("ui_set_routing_profile", "Activate a saved model-routing profile by name, or turn routing off (omit `profile`, or send \"\"). A profile fills the agent graphs' declared model slots (each agent's kinds of work — planning, building by task grade, chat, message sorting) with provider/model choices, overriding the default selection per slot. Switches govern NEW conversations only: a live thread keeps the envelope that opened it. Refused while a run is in flight, and for a name that isn't a saved profile (the error lists the saved names). Echoes {active_profile}.",
                 properties: [
                    "profile": ["type": "string", "description": "a saved profile name; null/\"\"/omitted = Off"],
                 ]),
            tool("ui_routing_profiles", "The saved model-routing profiles: {profiles: [names], active_profile, env_pinned}. `env_pinned` is the profile SZ_MODEL_ROUTING pinned at launch (null when the variable is unset or is only the 0/1 switch); while pinned, the pin — not `active_profile` — governs new work."),
            tool("ui_run", "Schedule an implementation run over the current graph — a Coding Agent per pending node, with the active provider. `instruction` (optional) steers the run. Only a conversation turn may start work: a turn that is itself part of a run is refused, because that run already dispatches its own agents. To change work that is under way, message the node's agent with `ui_send_chat` instead. The task is scheduled, never started inline: it begins once your turn ends and once the nodes it needs are free, so finish your reply rather than waiting on it.",
                 properties: [
                    "instruction": ["type": "string", "description": "optional free-text steer for the run"],
                    "nodes": ["type": "array", "items": ["type": "string"],
                              "description": "optional node ids to SCOPE this task to. Naming them is what lets it run ALONGSIDE another task over different nodes; omit to take every pending node not already being built."],
                 ]),
            tool("ui_amend_task", "Fold more words into a SCHEDULED task that has not started yet — what a follow-up like \"actually blue, not red\" does to an ask still waiting its turn. `task_id` comes from the task list in your brief. The words are APPENDED (the task keeps what was already asked), because a later message usually refines an earlier one rather than replacing it. Returns {amended: true}, or {amended: false, reason} if the task already started (message its agents instead — that is a steer, not an amend) or no longer exists.",
                 properties: [
                    "task_id": ["type": "string", "description": "the scheduled task's id"],
                    "instruction": ["type": "string", "description": "the words to fold in"],
                 ]),
            tool("ui_cancel_task", "Drop a SCHEDULED task that has not started yet — how two asks become one (amend the survivor, then cancel the other) and how a request the user withdrew stops before it spends anything. Returns {cancelled: true}, or {cancelled: false, reason} if it already started or no longer exists.",
                 properties: ["task_id": ["type": "string", "description": "the scheduled task's id"]]),
            tool("ui_stop", "Stop in-flight work (mirrors the HUD Stop button). Without arguments it stops EVERY live run and leaves the scheduled queue standing. Pass `run` — a thread id from the RUNS list — to interrupt just that agent graph, leaving the others building. Returns {status: \"stopped\"} , or {status: \"not_running\"} if nothing matched.",
                 properties: ["run": ["type": "string", "description": "thread id of ONE run to interrupt; omit to stop all"]],
                 agentCallable: false),   // a Director calling it would cancel its own run
            tool("ui_send_chat", "Send a chat message to an agent. `scope` is a node id (chat that node's Coding Agent) or \"director\" (the Director Agent). Every accepted message returns a `message_id`; `status` is \"queued\" (enqueued — delivers as a real turn when the recipient is free; poll ui_message_status if you need the outcome), \"recorded\" (a mid-run steer, folded into the recipient's next prompt), or \"rejected\" (pre-flight refusal — the message will NOT deliver; `detail` says why). A fresh Director Agent chat uses the active provider; resuming continues on the session's own CLI.",
                 properties: [
                    "scope": ["type": "string", "description": "a node uuid, or \"director\" (default)"],
                    "message": ["type": "string"],
                 ]),
            tool("ui_message_status", "Delivery state of a message you sent (`message_id` from ui_send_chat): {state: queued|delivering|processed|failed, reason?}. `failed` carries the reason. Unknown ids (e.g. from before an app restart) return {state: \"unknown\"}. Poll between your own steps — the send never blocks.",
                 properties: ["message_id": ["type": "string"]]),
            tool("ui_set_input_default", "Set an unconnected input's default value (mirrors its slider/toggle/dropdown) — changes the live render. `value` is coerced to the port's declared type (number, bool, or array of numbers); numbers may be sent as JSON numbers or numeric strings (\"14\", \"[0.1, 0.2, 0.3, 1]\"). A slider port's value is clamped to its `ui.min/max` and snapped to `ui.step`, exactly as dragging the slider would; the returned `value` is the APPLIED one, which may differ from what you asked for. Setting a FILE port copies the file into the project shortly after this returns, so the port's value then changes to a project path — expected, not a failure, don't retry. A file that can't be read comes back as `warning`.",
                 properties: [
                    "node": ["type": "string"], "port": ["type": "string"],
                    "value": ["type": ["number", "boolean", "array", "string"],
                              "items": ["type": "number"],
                              "description": "number, bool, or array of numbers (per the port type); numeric strings are accepted"],
                 ]),
            tool("ui_toggle_display", "Toggle a node's texture output as the viewport render endpoint (mirrors clicking the node card's monitor icon) — switches the live viewport to that output. Pointing at the current endpoint clears it. `port` must be a `texture` output.",
                 properties: ["node": ["type": "string"], "port": ["type": "string"]]),
            tool("ui_set_node_body", "Set a generated node card's body region (between header and rows). `mode`: \"none\" (compact card), \"preview\" (a live thumbnail of a texture output — `port` picks which, defaulting to the display-marked/first texture output), or \"custom\" (the node's own Card.swift, mounted as its body — the node folder must hold one; `cols`/`rows` set the footprint in grid cells, `pinned` stops auto-size). An unset body auto-previews a texture node; an explicit value pins the choice. `plugs: false` folds the card's port rows away (labels, controls and dots) so the body IS the card — the ports stay wired and connectable, and their edges land stacked on the body's edge. Geometry-affecting and persisted; echoes the applied body.",
                 properties: [
                    "node": ["type": "string"],
                    "mode": ["type": "string", "enum": ["none", "preview", "custom"]],
                    "port": ["type": "string", "description": "preview only: which texture output to show"],
                    "cols": ["type": "integer", "description": "custom only: card width in grid cells (6…24)"],
                    "rows": ["type": "integer", "description": "custom only: card body height in grid cells (2…24)"],
                    "pinned": ["type": "boolean", "description": "custom only: pin the size against auto-measure"],
                    "plugs": ["type": "boolean", "description": "false folds the port rows away (needs a preview or custom body to show instead)"],
                 ]),
            // The chat-tab and panel tools below are view/window navigation — no graph or render
            // effect — so they are withheld from agents (`agentCallable: false`); only the human
            // (and the `.full` test bus) drives the workspace layout.
            tool("ui_show_panel", "Show a top-level panel (mirrors its View-menu toggle) — reopens at its remembered spot; a popped-out panel docks back instead. Returns the resulting layout tree.",
                 properties: ["panel": Self.panelProperty], agentCallable: false),
            tool("ui_close_panel", "Close a top-level panel (mirrors its header ✕) — its split collapses and its spot is remembered; a popped-out panel's window closes and its record is dropped. Returns {closed:true, layout, popped_out_panels}. The last panel can't be closed, and a panel that isn't open can't either: both return {closed:false, reason, layout, popped_out_panels}.",
                 properties: ["panel": Self.panelProperty], agentCallable: false),
            tool("ui_move_panel", "Move a panel (mirrors dragging its header): with `onto`, an edge `zone` splits that panel with `panel` on that side and \"center\" swaps the two. Without `onto`, `panel` is pinned to that side of the WHOLE window, spanning it with everything else beside it. Returns the resulting layout tree.",
                 properties: [
                    "panel": Self.panelProperty,
                    "onto": Self.panelProperty,
                    "zone": ["type": "string", "enum": ["left", "right", "top", "bottom", "center"]],
                 ], agentCallable: false),
            tool("ui_clone_panel", "Clone a panel into a new tile beside it (a 50/50 split; mirrors the header's clone button — only the viewport is cloneable, up to \(SZPanelKind.viewport.maxInstances) tiles). Returns {cloned:true, id, layout, popped_out_panels} — `id` is the new tile's token (e.g. \"viewport:2\") — or {cloned:false, reason, layout, popped_out_panels}.",
                 properties: ["panel": Self.panelProperty], agentCallable: false),
            tool("ui_popout_panel", "Move a panel into its own floating window (mirrors the header's pop-out button — viewports only; the last tile can't pop out). Optional x/y/width/height place the window (AppKit screen coordinates, bottom-left origin); omitted, it opens exactly over its tile. Returns {popped_out:true, frame, layout, popped_out_panels} or {popped_out:false, reason, layout, popped_out_panels}.",
                 properties: [
                    "panel": Self.panelProperty,
                    "x": ["type": "number"], "y": ["type": "number"],
                    "width": ["type": "number"], "height": ["type": "number"],
                 ], agentCallable: false),
            tool("ui_dock_panel", "Dock a popped-out panel back into the main window as a tile. With `onto` + `zone` it lands on that edge of the target (the drag-to-dock path; edge zones only — a detached panel has nothing to swap with); omitted, it returns to its remembered spot (the dock-back button). Returns {docked:true, layout, popped_out_panels} or {docked:false, reason, layout, popped_out_panels}.",
                 properties: [
                    "panel": Self.panelProperty,
                    "onto": Self.panelProperty,
                    "zone": ["type": "string", "enum": ["left", "right", "top", "bottom"]],
                 ], agentCallable: false),
        ]
    }

    /// Every addressable tile token: bare kind strings for primaries, ":ordinal" for clones —
    /// "viewport:2" is exactly the tile titled "Viewport 2" (one vocabulary for users, agents, disk).
    private nonisolated static var panelTokens: [String] {
        SZPanelKind.allCases.flatMap { kind in
            (0..<kind.maxInstances).map { SZPanelID(kind, instance: $0).token }
        }
    }

    private nonisolated static var panelProperty: [String: Any] {
        ["type": "string", "enum": panelTokens,
         "description": "a panel — clones are instance-qualified (\"viewport:2\" = the tile titled Viewport 2)"]
    }

    func handleUITool(name: String, arguments: [String: Any]) throws -> String? {
        switch name {
        case "ui_add_prompt_node": return try uiAddPromptNode(arguments)
        case "ui_add_source_node": return try uiAddSourceNode(arguments)
        case "ui_add_library_node": return try uiAddLibraryNode(arguments)
        case "ui_connect":         return try uiConnect(arguments)
        case "ui_disconnect":      return try uiDisconnect(arguments)
        case "ui_update_node":     return try uiUpdateNode(arguments)
        case "ui_edit_ports":      return try uiEditPorts(arguments)
        case "ui_move_node":       return try uiMoveNode(arguments)
        case "ui_remove_node":     return try uiRemoveNode(arguments)
        case "ui_split_node":      return try uiSplitNode(arguments)
        case "ui_merge_nodes":     return try uiMergeNodes(arguments)
        case "ui_tidy_graph":      return try uiTidyGraph(arguments)
        case "ui_set_provider":    return try uiSetProvider(arguments)
        case "ui_set_routing_profile": return try uiSetRoutingProfile(arguments)
        case "ui_routing_profiles": return uiRoutingProfiles()
        case "ui_run":             return uiRun(arguments)
        case "ui_amend_task":      return try uiAmendTask(arguments)
        case "ui_cancel_task":     return try uiCancelTask(arguments)
        case "ui_stop":            return try uiStop(arguments)
        case "ui_send_chat":       return try uiSendChat(arguments)
        case "ui_message_status":  return try uiMessageStatus(arguments)
        case "ui_set_input_default": return try uiSetInputDefault(arguments)
        case "ui_toggle_display":  return try uiToggleDisplay(arguments)
        case "ui_set_node_body":   return try uiSetNodeBody(arguments)
        case "ui_show_panel":      return try uiShowPanel(arguments)
        case "ui_close_panel":     return try uiClosePanel(arguments)
        case "ui_move_panel":      return try uiMovePanel(arguments)
        case "ui_clone_panel":     return try uiClonePanel(arguments)
        case "ui_popout_panel":    return try uiPopoutPanel(arguments)
        case "ui_dock_panel":      return try uiDockPanel(arguments)
        default: return nil
        }
    }

    /// Agent placements ride the same snap-to-grid pref as human drags (Graph ▸ Snap to Grid) — the
    /// grid is the canvas's shared spatial vocabulary, so both input paths land on one lattice. The
    /// anchor is the card's top-left edge (SZNodeLayout.snappedCenter), so the returned center can sit
    /// on half-cells — the handlers return the APPLIED x/y so the agent's world model tracks the truth.
    private func placedPosition(x: Double, y: Double, cardSize: CGSize) -> SZPoint {
        guard host.snapToGrid else { return SZPoint(x: x, y: y) }
        let snapped = SZNodeLayout.snappedCenter(CGPoint(x: x, y: y), size: cardSize)
        return SZPoint(x: snapped.x, y: snapped.y)
    }

    private func uiAddPromptNode(_ arguments: [String: Any]) throws -> String {
        let position = placedPosition(
            x: arguments.double("x") ?? 240, y: arguments.double("y") ?? 240,
            cardSize: CGSize(width: SZNodeLayout.width, height: SZNodeLayout.promptHeight))
        guard let id = host.store.addPromptNode(prompt: arguments.string("prompt"), position: position) else {
            throw SZMCPError.message("no project loaded")
        }
        host.noteRunCreatedWork([id])   // a node the fleet's own tooling adds mid-run joins the work set
        host.noteNodeAdded(id, origin: .agent)
        return SZJSONRPC.encode(["id": id.uuidString, "x": position.x, "y": position.y])
    }

    /// Add media source nodes from files on disk — the `ui_*` mirror of dropping files on the canvas.
    /// Shares the drop's classifier + stagger (`SZMediaSource`) and its placement path
    /// (`host.createMediaNodes`), so a human drag and an agent call produce the same graph.
    ///
    /// Two things the drop gets for free and this must do itself: a dropped file always EXISTS (the
    /// classifier reads the extension, never disk), and a stray type just bounces off the canvas. An agent
    /// hands us strings, so every path is validated BEFORE anything is created — a rejected call leaves the
    /// graph untouched rather than half-built.
    private func uiAddSourceNode(_ arguments: [String: Any]) throws -> String {
        let paths = arguments.stringList("paths")
        guard !paths.isEmpty else { throw SZMCPError.message("ui_add_source_node needs `paths`: ≥1 file path") }

        let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw SZMCPError.message("no such file: \(url.path)")
            }
            guard SZMediaSource.libraryID(for: url) != nil else {
                throw SZMCPError.message(
                    "not an image or video: \(url.lastPathComponent) — no library node reads this file type")
            }
        }

        let origin = placedPosition(
            x: arguments.double("x") ?? 240, y: arguments.double("y") ?? 240,
            cardSize: CGSize(width: SZNodeLayout.width, height: SZNodeLayout.promptHeight))
        let specs = SZMediaSource.specs(for: urls, origin: origin)
        let created = host.createMediaNodes(specs, origin: .agent)
        guard created.count == specs.count else {   // a disk/compile failure part-way; the rest did land
            throw SZMCPError.message(
                "created \(created.count) of \(specs.count) source nodes — read the graph to see which")
        }

        host.noteRunCreatedWork(Set(created))   // added by the run's own tooling, so it joins its work set
        let nodes = zip(created, specs).map { id, spec -> [String: Any] in
            ["id": id.uuidString, "library": spec.libraryID, "x": spec.position.x, "y": spec.position.y]
        }
        let endpoint = host.store.project?.graph.renderEndpoint
        return SZJSONRPC.encode([
            "nodes": nodes,
            "endpoint": endpoint.map { ["node": $0.node.uuidString, "port": $0.port] } as Any,
        ])
    }

    /// Fence pre-check for the agent surface (SZHost+Fence.swift): throws the refusal naming the
    /// holder ("node 'Blur' is held by chat turn 'Blur'…") so an agent learns the real reason,
    /// instead of the host funnel's silent `false`. The funnels still guard (belt-and-braces).
    private func requireUnfenced(_ nodes: [SZNodeID]) throws {
        if let denial = host.fenceDenial(nodes: nodes, origin: .agent) {
            throw SZMCPError.message(denial)
        }
    }

    private func uiConnect(_ arguments: [String: Any]) throws -> String {
        guard let from = arguments.uuid("from"), let to = arguments.uuid("to") else {
            throw SZMCPError.message("ui_connect needs `from` and `to` node ids")
        }
        // Reject an unknown `kind` outright rather than silently coercing it to `.data`.
        let kindRaw = arguments.string("kind") ?? "data"
        guard let kind = SZConnectionKind(rawValue: kindRaw) else {
            throw SZMCPError.message("invalid kind '\(kindRaw)' — expected \"data\" or \"flow\"")
        }
        // Mid-run, refuse an edge onto a `.prompt` node that ISN'T the fleet's work — i.e. a node the user
        // added on the canvas during this run. It's theirs; the fleet must not wire it (a stray edge would
        // also mutate a real work node's derived port set). Generated endpoints and work-set nodes pass.
        if host.isRunning {
            for endpoint in [from, to] {
                if let node = host.store.project?.graph.node(id: endpoint),
                   node.kind == .prompt, !host.runWorkSet.contains(endpoint) {
                    throw SZMCPError.message("node \(endpoint) is not part of this run's work (a user draft) — cannot connect to it")
                }
            }
        }
        // Validate exactly as the canvas drag does — self-loop, output↔input side, kind match, port
        // existence, and (for data) equal port types — via SZGraphCanvasModel.canConnect. The MCP path was
        // the one connection caller that skipped it (store.connect trusts its callers by design).
        guard let graph = host.store.project?.graph else { throw SZMCPError.message("no project loaded") }
        guard let fromNode = graph.node(id: from) else { throw SZMCPError.message("no node \(from)") }
        guard let toNode = graph.node(id: to) else { throw SZMCPError.message("no node \(to)") }
        let fromPort = arguments.string("fromPort") ?? "output"
        let toPort = arguments.string("toPort") ?? "input"
        // Resolve each endpoint to a real socket. Flow sockets are portless (match on side+kind); data
        // sockets must name an existing contract port. A missing socket = an invalid/unknown port.
        // `connectableSockets`, not `sockets`: the latter is what the CANVAS DRAWS, and a prompt card
        // draws no data dots until it's implemented. The Director's whole flow is to set a contract on a
        // draft node and then wire it — those ports exist the moment the contract lands.
        func resolveSocket(on node: SZNode, side: SZSocketSide, port: String) throws -> SZSocket {
            let match = SZGraphCanvasModel.connectableSockets(
                of: node, previewsEnabled: host.livePreviews).first {
                $0.side == side && $0.kind == kind && (kind == .flow || $0.port == port)
            }
            guard let socket = match else {
                throw SZMCPError.message("node \(node.id) has no \(kindRaw) \(side == .output ? "output" : "input") port '\(port)' — call agent_read_node to see its ports")
            }
            return socket
        }
        let src = try resolveSocket(on: fromNode, side: .output, port: fromPort)
        let dst = try resolveSocket(on: toNode, side: .input, port: toPort)
        // A cycle-closing data edge gets a structured refusal naming the path — a rule refusal the
        // agent should read and adapt to (cf. ui_run's `refused`), not a transport error. Checked
        // before `canConnect` (which also refuses cycles) so the reason isn't misreported as a type
        // mismatch. Judged as if the occupied target input's edge were already swapped out.
        if kind == .data {
            var probe = graph
            probe.connections.removeAll { $0.kind == .data && $0.to == SZPortRef(node: to, port: toPort) }
            if let path = probe.wouldCloseCycle(from: from, to: to) {
                let titles = path.map { graph.node(id: $0)?.title ?? $0.uuidString }.joined(separator: " → ")
                return SZJSONRPC.encode(["status": "refused",
                                         "reason": "would close a data cycle: \(titles)"])
            }
        }
        guard SZGraphCanvasModel.canConnect(src, dst, in: graph) else {
            if from == to { throw SZMCPError.message("cannot connect node \(from) to itself") }
            // An arrow is only ever refused for ringing; a data edge for its port types (its own cycle
            // case was answered above). Naming the wrong one sends the caller after the wrong fix.
            if kind == .flow, let path = graph.wouldCloseIntentCycle(from: from, to: to) {
                return SZJSONRPC.encode(["status": "refused",
                                         "reason": "the arrows would run in a circle: \(host.cyclePathDescription(path))"])
            }
            throw SZMCPError.message("incompatible \(kindRaw) connection \(fromNode.title):\(fromPort) → \(toNode.title):\(toPort) (port types differ)")
        }
        try requireUnfenced([from, to])
        // A flow ref is the plain node-to-node marker unless the caller explicitly named a declared
        // data port — then the flow edge is PINNED to that slot (`SZConnection.pinnedPort`), like a
        // canvas drop on a blue dot. The "output"/"input" defaults never pin.
        func ref(_ node: SZNode, side: SZSocketSide, port: String, explicit: Bool) -> SZPortRef {
            guard kind == .flow else { return SZPortRef(node: node.id, port: port) }
            let pins = explicit && SZGraphCanvasModel.portType(of: node, side: side, port: port) != nil
            return pins ? SZPortRef(node: node.id, port: port) : .flow(node: node.id)
        }
        // Through the host (not bare store.connect) so the new edge persists + reloads the runtime.
        let connection = host.addConnection(
            from: ref(fromNode, side: .output, port: fromPort, explicit: arguments.string("fromPort") != nil),
            to: ref(toNode, side: .input, port: toPort, explicit: arguments.string("toPort") != nil),
            kind: kind,
            origin: .agent
        )
        guard let connection else { throw SZMCPError.message("no project loaded") }
        return SZJSONRPC.encode(["id": connection.uuidString])
    }

    private func uiStop(_ arguments: [String: Any]) throws -> String {
        // ONE graph, addressed by the thread the RUNS list shows — the others keep building.
        // An id that does not PARSE is an error, never "no id": treating a truncated or misspelled
        // thread as an absent one turns "stop this build" into "stop every build", which is the
        // one mistake this tool must not make silently.
        if let raw = arguments.string("run") {
            guard let thread = UUID(uuidString: raw) else {
                throw SZMCPError.message("ui_stop: `run` must be a full thread uuid (got \(raw))")
            }
            return SZJSONRPC.encode(host.cancelRun(thread: thread)
                ? ["status": "stopped", "run": thread.uuidString]
                : ["status": "not_running", "reason": "no live run leads that thread"])
        }
        guard host.isRunning else { return SZJSONRPC.encode(["status": "not_running"]) }
        host.cancelRun()   // every live run + its coding agents; the scheduled queue stands
        return SZJSONRPC.encode(["status": "stopped"])
    }

    private func uiDisconnect(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments.uuid("connection") else { throw SZMCPError.message("ui_disconnect needs `connection` id") }
        try requireUnfenced(host.connectionEndpoints(id))
        // Through the host (not bare store.disconnect) so the removal persists + reloads the runtime.
        return SZJSONRPC.encode(["removed": host.deleteConnection(id: id, origin: .agent)])
    }

    private func uiUpdateNode(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments.uuid("node") else { throw SZMCPError.message("ui_update_node needs `node` id") }
        // Presentation + identity only. The port surface is `ui_edit_ports`' business: a whole-contract PUT here
        // silently dropped every port the caller failed to re-send.
        //
        // Reject the old shape loudly. A caller still sending `contract` (an agent whose session predates the
        // split, a stale prompt) would otherwise get `{updated: true}` for ports that were never written, and
        // only discover it when the run finds nothing to build.
        if arguments["contract"] != nil || arguments["inputs"] != nil || arguments["outputs"] != nil {
            throw SZMCPError.message(
                "ui_update_node no longer accepts `contract`/`inputs`/`outputs` — it cannot change a node's "
                + "ports. Use ui_edit_ports { node, inputs: { upsert: [...], remove: [...] }, outputs: {...} }, "
                + "which preserves the ports you don't mention.")
        }
        let permissions = try (arguments["permissions"] as? [String]).map { raw -> [SZEntitlement] in
            try raw.map {
                guard let e = SZEntitlement(rawValue: $0) else {
                    throw SZMCPError.message("unknown permission \"\($0)\" — expected camera or microphone")
                }
                return e
            }
        }
        // Validate the grade word up front, but record only after the mutation is accepted
        // below — a refused tool call must leave no side effect standing.
        let complexity = try arguments.string("complexity").map { word in
            guard SZRoutingProfile.grades.contains(word) else {
                throw SZMCPError.message(
                    "unknown complexity \"\(word)\" — expected light, standard, or heavy")
            }
            return word
        }
        // `requireUnfenced` first only for its richer refusal message (it names the holder and throws);
        // `updateNodeContent` is the authoritative gate and re-checks. The funnel also carries the
        // raised-rebuild join and the persist, shared with the editor's inline prompt commit.
        try requireUnfenced([id])
        let updated = host.updateNodeContent(
            id: id,
            title: arguments.string("title"),
            sfSymbol: arguments.string("sfSymbol"),
            prompt: arguments.string("prompt"),
            summary: arguments.string("summary"),
            permissions: permissions,
            origin: .agent
        )
        // nil = the fence refused. `requireUnfenced` above applies the identical predicate in the same
        // MainActor turn, so it always throws the richer message first — but they are kept distinct here
        // so that deleting the pre-check can never degrade into telling an agent the node doesn't exist.
        guard let result = updated else {
            throw SZMCPError.message(host.fenceDenial(nodes: [id], origin: .agent) ?? "node \(id) is locked")
        }
        guard result.found else { throw SZMCPError.message("no node \(id)") }
        // The grade never rides the node mutation — it is run-scoped host state, not node data
        // (persisting an orchestration hint onto the artifact graph is the P02 mistake).
        if let complexity { host.recordNodeGrade(id, complexity) }
        // A blank prompt node that `startRun` kept OUT of the work set becomes real work the instant the
        // Director gives it a prompt — join it to the run so the fleet builds it this pass, exactly as
        // `ui_edit_ports` and `ui_add_prompt_node` do. `result.raisedRebuild` covers only `.generated`
        // nodes, so without this a Director authoring a previously-excluded blank node during a run leaves
        // it authored-but-undispatched. Skip if already in the set — `noteRunCreatedWork` asserts a fresh,
        // uncontended claim.
        if !host.runWorkSet.contains(id),
           let node = host.store.project?.graph.node(id: id), node.kind == .prompt,
           node.prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            host.noteRunCreatedWork([id])
        }
        // Report the node's STATE, not what this call changed (same terms as `ui_edit_ports`): a node
        // already awaiting a rebuild is still awaiting one.
        let stillNeedsRebuild = host.store.project?.graph.node(id: id)?.needsRebuild ?? result.raisedRebuild
        return SZJSONRPC.encode(["updated": true, "needsRebuild": stillNeedsRebuild])
    }

    /// The single path that mutates a node's typed I/O. Applies the delta, prunes what it invalidated, and —
    /// when the surface actually moved on a node that already has a build — marks it for rebuild and joins it
    /// to any run in flight, exactly as `ui_add_prompt_node` does for a node the fleet creates mid-run.
    /// Otherwise a Director port-edit during a run would raise work no one is scoped to pick up.
    private func uiEditPorts(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments.uuid("node") else { throw SZMCPError.message("ui_edit_ports needs `node` id") }

        func ports(_ side: String) throws -> (upsert: [SZPort], remove: [String]) {
            guard let obj = arguments.object(side) else { return ([], []) }
            let upsert = try (obj["upsert"] as? [[String: Any]] ?? []).map { raw -> SZPort in
                let data = try JSONSerialization.data(withJSONObject: raw)
                return try JSONDecoder().decode(SZPort.self, from: data)
            }
            return (upsert, obj["remove"] as? [String] ?? [])
        }
        // A file-port default declared here stays exactly as written, absolute path and all: this tool
        // declares a port SURFACE, and an agent that means to set a VALUE has `ui_set_input_default`,
        // which brings the file into the project. Deliberate, not an omission.
        let inputs = try ports("inputs"), outputs = try ports("outputs")
        let edit = SZStore.SZPortEdit(upsertInputs: inputs.upsert, removeInputs: inputs.remove,
                                      upsertOutputs: outputs.upsert, removeOutputs: outputs.remove)
        guard !edit.isEmpty else { throw SZMCPError.message("ui_edit_ports needs at least one upsert or remove") }

        try requireUnfenced([id])
        let result = host.store.editPorts(node: id, edit)
        guard result.found else { throw SZMCPError.message("no node \(id)") }
        host.noteMutation("edited ports", [host.mutationTitle(id)], origin: .agent)
        // The surface moving off the build stamp reads `.contractChanged`; only reading the live source can tell
        // whether the code is merely behind the new contract or now names ports that don't exist (dropping a
        // port the code reads leaves those reads resolving to nil every frame — a fault, not an unfinished
        // feature). Re-audit either way, so a fault a previous edit opened clears when this one closes it.
        host.classifyRebuild(node: id)
        if result.raisedRebuild { host.noteRunCreatedWork([id]) }
        // Through the host (not a bare store edit) so the new contract + the rebuild flag reach disk and the
        // runtime — otherwise a crash before the next run loses both. Safe because `kind` is untouched: a
        // reload re-renders the node rather than dropping it from `renderableSubgraph`.
        host.persistGraphEditAndReload(action: "edit ports")
        // After the reload, whose reconcile deliberately keeps a live override: any value this edit moved has
        // to be pushed, or the node keeps rendering the one the card no longer shows.
        host.applyPortValueChanges(node: id, result.changedValues)

        // Report the node's STATE, not what this call changed: a node that was already awaiting a rebuild is
        // still awaiting one, and answering `needsRebuild: false` because *this* edit didn't raise the flag
        // would tell the Director its node is current when it is not.
        let stillNeedsRebuild = host.store.project?.graph.node(id: id)?.needsRebuild ?? result.raisedRebuild
        var response: [String: Any] = ["updated": true, "needsRebuild": stillNeedsRebuild,
                                       "raisedRebuild": result.raisedRebuild]
        if !result.droppedConnections.isEmpty {
            response["droppedConnections"] = result.droppedConnections.map(\.uuidString)
        }
        if result.clearedRenderEndpoint { response["clearedRenderEndpoint"] = true }
        // What the edit could not carry, said out loud: the agent can put the user's setting back, or say so.
        if !result.droppedValues.isEmpty { response["droppedValues"] = result.droppedValues }
        return SZJSONRPC.encode(response)
    }

    private func uiMoveNode(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments.uuid("node") else { throw SZMCPError.message("ui_move_node needs `node` id") }
        guard let x = arguments.double("x"), let y = arguments.double("y") else {
            throw SZMCPError.message("ui_move_node needs `x` and `y`")
        }
        guard let node = host.store.project?.graph.node(id: id) else {
            throw SZMCPError.message("no node \(id)")
        }
        let position = placedPosition(x: x, y: y,
                                      cardSize: SZNodeLayout.size(of: node,
                                                                  previewsEnabled: host.livePreviews))
        guard host.store.moveNode(id: id, to: position) else {
            throw SZMCPError.message("no node \(id)")
        }
        return SZJSONRPC.encode(["moved": true, "x": position.x, "y": position.y])
    }

    private func uiRemoveNode(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments.uuid("node") else { throw SZMCPError.message("ui_remove_node needs `node` id") }
        try requireUnfenced([id])
        // Through the host (not bare store.removeNode) so the node's chat artifacts are purged too.
        return SZJSONRPC.encode(["removed": host.deleteNode(id: id, origin: .agent)])
    }

    private func uiTidyGraph(_ arguments: [String: Any]) throws -> String {
        guard host.store.project != nil else { throw SZMCPError.message("no project loaded") }
        let layout = host.tidyGraph()   // one transaction + persist; returns the applied centers
        let positions = layout.map { ["node": $0.key.uuidString, "x": $0.value.x, "y": $0.value.y] as [String: Any] }
        return SZJSONRPC.encode(["tidied": !layout.isEmpty, "positions": positions])
    }

    private func uiSplitNode(_ arguments: [String: Any]) throws -> String {
        guard let node = arguments.uuid("node") else { throw SZMCPError.message("ui_split_node needs `node` id") }
        let pieces = arguments.double("pieces").map { Int($0) } ?? 2
        let run = arguments["run"] as? Bool ?? true
        if run, host.hasStagedGraphOp {
            throw SZMCPError.message("a split/merge is already staged — it commits when the current run ends")
        }
        try requireUnfenced([node])
        guard let ids = host.splitNode(id: node, pieces: pieces, run: run,
                                       instruction: arguments.string("instruction")) else {
            throw SZMCPError.message("cannot split \(node) (missing node, pieces < 2, no project, or no run could start)")
        }
        // `staged` is the truth the caller needs: the pieces exist but are HIDDEN, and the original still
        // renders, until the run commits them (or rolls them back). `running` is the live host state — a
        // staged op may have started a run or joined one already in flight.
        return SZJSONRPC.encode(["pieces": ids.map(\.uuidString), "staged": run, "running": host.isRunning])
    }

    private func uiMergeNodes(_ arguments: [String: Any]) throws -> String {
        let ids = arguments.uuidList("nodes")
        guard ids.count >= 2 else { throw SZMCPError.message("ui_merge_nodes needs `nodes`: ≥2 node ids") }
        let run = arguments["run"] as? Bool ?? true
        if run, host.hasStagedGraphOp {
            throw SZMCPError.message("a split/merge is already staged — it commits when the current run ends")
        }
        try requireUnfenced(ids)
        guard let merged = host.mergeNodes(ids: ids, run: run,
                                           instruction: arguments.string("instruction")) else {
            throw SZMCPError.message("cannot merge (the ids must form a connected linear data chain, or no run could start)")
        }
        return SZJSONRPC.encode(["merged": merged.uuidString, "staged": run, "running": host.isRunning])
    }

    private func uiSetProvider(_ arguments: [String: Any]) throws -> String {
        guard let provider = arguments.string("provider") else {
            throw SZMCPError.message("ui_set_provider needs `provider`")
        }
        // Provider first (a switch resets sessions and re-targets the option setters), then each
        // present option through the same intents the composer cluster uses.
        guard host.setActiveProvider(provider) else {
            let reason = if SZProviderRegistry.shared.provider(id: provider) == nil {
                "unknown provider \(provider)"
            } else if host.disabledProviderIDs.contains(provider) {
                "\(provider) is disabled — enable it in Agent Providers first"
            } else {
                "cannot switch provider while a run or chat turn is in flight"
            }
            throw SZMCPError.message(reason)
        }
        if let model = arguments.string("model"), !host.setActiveModel(model) {
            throw SZMCPError.message("\(provider) has no model \(model)")
        }
        if let effort = arguments.string("reasoning_effort"), !host.setActiveReasoningEffort(effort) {
            throw SZMCPError.message("\(provider) does not support reasoning effort \(effort)")
        }
        if let fast = arguments["fast_mode"] as? Bool, !host.setActiveFastMode(fast) {
            throw SZMCPError.message("\(provider) does not support fast mode")
        }
        // Echo the resolved selection, plus the active routing profile — a profile may override
        // this per graph position (the caller set the fallback, not what every turn runs).
        let resolved = host.resolvedGenerationSettings(for: host.activeProviderID)
        var response: [String: Any] = ["provider": host.activeProviderID,
                                       "model": resolved.model ?? "",
                                       "fast_mode": resolved.fastMode ?? false,
                                       "active_profile": Self.jsonNull(effectiveRoutingProfileName)]
        if let effort = resolved.reasoningEffort { response["reasoning_effort"] = effort }
        return SZJSONRPC.encode(response)
    }

    /// The saved-profile name app-state currently activates — a stale persisted name (its profile
    /// deleted elsewhere) reads as Off, matching `activeRoutingProfile`'s degrade rule.
    var effectiveRoutingProfileName: String? {
        host.routingProfiles.first { $0.name == host.activeRoutingProfileName }?.name
    }

    /// An optional string as its JSON payload value: the string, or JSON null.
    nonisolated static func jsonNull(_ value: String?) -> Any {
        if let value { return value }
        return NSNull()
    }

    /// Activate a profile (or Off) through the SAME host mutator as AI Settings, so the busy
    /// guard, persistence, and session affinity are the one shipped behavior.
    private func uiSetRoutingProfile(_ arguments: [String: Any]) throws -> String {
        // null strips to absent at dispatch, so null, "" and omitted all mean Off.
        let raw = arguments.string("profile")
        let name = (raw?.isEmpty ?? true) ? nil : raw
        if let name, !host.routingProfiles.contains(where: { $0.name == name }) {
            let saved = host.routingProfiles.map(\.name)
            throw SZMCPError.message("no routing profile named \"\(name)\" — saved profiles: "
                + (saved.isEmpty ? "(none)" : saved.joined(separator: ", ")))
        }
        guard host.setActiveRoutingProfile(name) else {
            throw SZMCPError.message(
                "cannot switch the routing profile while a run is in flight — live work keeps its models")
        }
        return SZJSONRPC.encode(["active_profile": Self.jsonNull(effectiveRoutingProfileName)])
    }

    private func uiRoutingProfiles() -> String {
        SZJSONRPC.encode([
            "profiles": host.routingProfiles.map(\.name),
            "active_profile": Self.jsonNull(effectiveRoutingProfileName),
            "env_pinned": Self.jsonNull(Self.envPinnedRoutingProfileName),
        ])
    }

    /// The profile SZ_MODEL_ROUTING pins by NAME — nil when unset or when the value is only the
    /// 0/1 switch (kill / app-state governs).
    static var envPinnedRoutingProfileName: String? {
        switch SZHost.modelRoutingEnv {
        case nil, "0", "1": nil
        case .some(let name): name
        }
    }

    private func uiRun(_ arguments: [String: Any]) -> String {
        let instruction = arguments.string("instruction") ?? ""
        // Naming nodes SCOPES the task to them — the only way two asks can be concurrent.
        let nodes = Set((arguments["nodes"] as? [Any] ?? [])
            .compactMap { ($0 as? String).flatMap(UUID.init(uuidString:)) })
        // A turn inside a run may not schedule another: its run already dispatches a fleet off
        // its own edges, so this asks for work under way. Keyed on the caller's claim, so it
        // covers every agent on every provider without naming one. Blind spot, shared with the
        // mutation fence: a turn that fell back to the standing agent bus (no free port for its
        // own listener) carries no claim, and is not caught here.
        if let run = host.activeRun(for: SZToolCaller.claim) {
            let held = run.workSet.count
            return SZJSONRPC.encode([
                "status": "refused",
                "reason": "your turn is already inside a run over \(held) node(s), which dispatches "
                    + "its own agents. To steer that work, send the node's agent a message with "
                    + "ui_send_chat.",
            ])
        }
        // NOT gated on "something is already running" — that is the whole point: an ask over
        // other nodes starts alongside. Only a claim it cannot get makes it wait, and that is
        // `startRun`'s own verdict below.
        // Called from the Director Agent's OWN streaming chat turn: starting now would race that
        // turn on the same transcript (deliver's one-in-flight-marker-per-scope invariant), so the
        // run is MINTED — the door's `requestBuild` lane, one home for supersede + narration —
        // and admitted at the pump's head when that turn's claim frees.
        if host.chatInFlight.contains(SZChatScope.directorKey) {
            host.mintRun(instruction: instruction, nodes: nodes)
            return SZJSONRPC.encode(["status": "queued",
                                     "detail": "the run starts when your current turn ends"])
        }
        // The START's own answer, not `isRunning`: with several runs live, another one being in
        // flight says nothing about whether THIS ask started.
        // `narrateContention: false` — the `.waiting` branch below mints the ask, so the transient
        // "wait for it to finish, then build again" line would be advice to do what just happened
        // automatically, immediately contradicted by the queue's own line.
        switch host.startRun(instruction: instruction, nodes: nodes,
                             narrateContention: false) {   // returns immediately
        case .started: break
        case .waiting:
            // A transient claim holds what it needs — schedule it rather than lose it.
            host.mintRun(instruction: instruction, nodes: nodes)
            return SZJSONRPC.encode(["status": "queued", "position": host.pendingTasks.count,
                                     "detail": host.status])
        case .refused:
            return SZJSONRPC.encode(["status": "refused", "reason": host.status])
        }
        return SZJSONRPC.encode(["status": "started", "provider": host.activeProviderID])
    }

    private func uiAmendTask(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments.string("task_id").flatMap(UUID.init(uuidString:)) else {
            throw SZMCPError.message("ui_amend_task needs a `task_id` (a uuid)")
        }
        guard let instruction = arguments.string("instruction"),
              !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SZMCPError.message("ui_amend_task needs a non-empty `instruction`")
        }
        guard host.amendTask(id, with: instruction) else {
            return SZJSONRPC.encode(["amended": false, "reason": Self.taskGoneReason(id, host: host)])
        }
        return SZJSONRPC.encode(["amended": true])
    }

    private func uiCancelTask(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments.string("task_id").flatMap(UUID.init(uuidString:)) else {
            throw SZMCPError.message("ui_cancel_task needs a `task_id` (a uuid)")
        }
        guard host.withdrawTask(id) else {
            return SZJSONRPC.encode(["cancelled": false, "reason": Self.taskGoneReason(id, host: host)])
        }
        return SZJSONRPC.encode(["cancelled": true])
    }

    /// Why a task could not be amended or cancelled — a running task is a different situation from
    /// one that never existed, and saying which is what tells the caller what to do instead.
    private static func taskGoneReason(_ id: UUID, host: SZHost) -> String {
        host.activeRuns[id] != nil
            ? "that task is already running — message its agents to steer it"
            : "no scheduled task with that id"
    }

    private func uiSendChat(_ arguments: [String: Any]) throws -> String {
        guard let message = arguments.string("message"),
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SZMCPError.message("ui_send_chat needs a non-empty `message`")
        }
        let scope = try chatScope(arguments, tool: "ui_send_chat")
        // One entry point with the GUI composer (`SZHost.sendChat`); `.agent` origin routes a mid-run
        // message to the steer record paths instead of the user flow. Every enqueued/recorded message
        // carries its id so the caller can poll `ui_message_status`.
        switch host.sendChat(scope: scope, message: message, origin: .agent) {
        case .rejected:
            // A pre-flight refusal (provider/host not ready, dead mention) — the message will NOT
            // deliver. The old wire meaning of "sent" was "a turn started"; answering that here
            // would tell the caller a dropped message succeeded.
            return SZJSONRPC.encode(["status": "rejected", "scope": scope.key,
                                     "detail": "not deliverable — \(host.status)"])
        case .queued(let id):
            return SZJSONRPC.encode(["status": "queued", "message_id": id.uuidString, "scope": scope.key])
        case .recordedForReconcile(let id):
            return SZJSONRPC.encode(["status": "recorded", "message_id": id.uuidString, "scope": scope.key])
        }
    }

    /// Poll a sent message's delivery state — the MCP-shaped ack (handlers are synchronous and must
    /// never block; the in-process `awaitProcessed` is the real primitive, for in-process callers
    /// like the future behavior-tree engine). Answers from the live queue + the bounded tombstone
    /// list; a message from before a restart is honestly `unknown`.
    private func uiMessageStatus(_ arguments: [String: Any]) throws -> String {
        guard let raw = arguments.string("message_id"), let id = UUID(uuidString: raw) else {
            throw SZMCPError.message("ui_message_status needs `message_id` (a uuid from ui_send_chat)")
        }
        guard let envelope = host.mailbox.envelope(for: id) else {
            return SZJSONRPC.encode(["state": "unknown",
                                     "detail": "no record of that message (it may predate an app restart)"])
        }
        var response: [String: Any] = ["state": envelope.state.rawValue]
        if let reason = envelope.failureReason { response["reason"] = reason }
        return SZJSONRPC.encode(response)
    }

    private func uiSetInputDefault(_ arguments: [String: Any]) throws -> String {
        guard let node = arguments.uuid("node") else { throw SZMCPError.message("ui_set_input_default needs `node`") }
        guard let port = arguments.string("port") else { throw SZMCPError.message("ui_set_input_default needs `port`") }
        guard let portModel = host.store.project?.graph.node(id: node)?.contract?.inputs.first(where: { $0.name == port }) else {
            throw SZMCPError.message("no input port \(port) on node \(node)")
        }
        let value = try Self.portValue(portModel.type, from: arguments["value"])
        try requireUnfenced([node])
        // The host clamps a slider port to its declared range, exactly as the slider does. Echo the
        // APPLIED value (like ui_move_node echoes the snapped x/y) so the agent's world model tracks
        // the truth instead of the value it asked for.
        let applied = host.setInputDefault(node: node, port: port, value: value, origin: .agent)
        var response: [String: Any] = ["set": port]
        if let json = Self.jsonValue(applied) { response["value"] = json }
        // A file that can't be read would otherwise be discovered as a black node several turns later.
        if let reason = host.store.project?.graph.node(id: node)?.unreadableInputs[port] {
            response["warning"] = reason
        }
        return SZJSONRPC.encode(response)
    }

    /// A port value as its natural JSON type — mirrors `portValue`'s coercion in reverse. Taken off the
    /// enum rather than `SZPortValue.floats`, which narrows to `Float` (echoing 1.2 as 1.2000000476…)
    /// and flattens a bool to 1/0.
    static func jsonValue(_ value: SZPortValue) -> Any? {
        switch value {
        case .float(let v): v
        case .bool(let b): b
        case .float2(let a), .float3(let a), .float4(let a),
             .colorRGB(let a), .colorRGBA(let a), .float3x3(let a), .float4x4(let a): a
        case .enumeration(let s), .string(let s): s
        case .event: nil
        }
    }

    private func uiToggleDisplay(_ arguments: [String: Any]) throws -> String {
        guard let node = arguments.uuid("node") else { throw SZMCPError.message("ui_toggle_display needs `node`") }
        guard let port = arguments.string("port") else { throw SZMCPError.message("ui_toggle_display needs `port`") }
        // Reject what the node card can't offer: the monitor icon renders for a `texture` OUTPUT and
        // nothing else (SZNodeView.outputRow) — note it does NOT require `display: true`, which only
        // picks the run's default endpoint. `store.setRenderEndpoint` enforces the same rule but merely
        // returns false, and `toggleDisplay` then hands back the unchanged endpoint — indistinguishable
        // from a legitimate clear. Reject here so `{endpoint: null}` can only ever mean "cleared".
        let outputs = host.store.project?.graph.node(id: node)?.contract?.outputs
        guard let outputPort = outputs?.first(where: { $0.name == port }), outputPort.type == .texture else {
            throw SZMCPError.message("node \(node) has no texture output port '\(port)' — call agent_read_node to see its ports")
        }
        // A STAGED split/merge piece isn't on the canvas: the editor strips it from the drawn graph and from
        // hit-testing (`SZNodeEditorPanel.contentGraph` / `nodeHit`), so its monitor icon cannot be clicked.
        // The Director, which reads the raw graph, otherwise "helpfully" parks the viewport on the unbuilt
        // final stage — a black viewport for the whole run, and a dangling endpoint if the op rolls back.
        // The host reveals the pieces and repoints the endpoint itself, at commit.
        guard !host.hiddenPieces.contains(node) else {
            throw SZMCPError.message(
                "node \(node) is a staged split/merge piece, hidden until the operation commits — "
                + "the host moves the render endpoint to it then; leave the endpoint where it is")
        }
        try requireUnfenced([node])
        let endpoint = host.toggleDisplay(node: node, port: port, origin: .agent)
        if let endpoint, endpoint.node == node, endpoint.port == port {
            return SZJSONRPC.encode(["endpoint": port])
        }
        return SZJSONRPC.encode(["endpoint": NSNull()])
    }

    private func uiSetNodeBody(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments.uuid("node") else { throw SZMCPError.message("ui_set_node_body needs `node` id") }
        guard let modeRaw = arguments.string("mode"), let mode = SZNodeBodyMode(rawValue: modeRaw) else {
            throw SZMCPError.message("ui_set_node_body needs `mode` ∈ {none, preview, custom}")
        }
        // The same host op as the card's photo toggle and the context-menu card toggle — ONE
        // resolve+apply choreography (validation, store write, stale thumb drop, persist,
        // watch-set refresh) for human and agent edits. Its errors are the agent's guidance.
        try requireUnfenced([id])
        let body: SZNodeBody
        do {
            body = try host.applyNodeBody(
                node: id, mode: mode, port: arguments.string("port"),
                cols: (arguments["cols"] as? NSNumber)?.intValue, rows: (arguments["rows"] as? NSNumber)?.intValue,
                pinned: arguments["pinned"] as? Bool, plugs: arguments["plugs"] as? Bool, origin: .agent)
        } catch {
            throw SZMCPError.message(String(describing: error))
        }

        var applied: [String: Any] = ["mode": body.mode.rawValue]
        if let plugs = body.plugs { applied["plugs"] = plugs }
        if let previewPort = body.previewPort { applied["previewPort"] = previewPort }
        if let custom = body.custom {
            var card: [String: Any] = [:]
            if let cols = custom.cols { card["cols"] = cols }
            if let rows = custom.rows { card["rows"] = rows }
            if let pinned = custom.pinned { card["pinned"] = pinned }
            applied["custom"] = card
        }
        return SZJSONRPC.encode(["body": applied])
    }

    /// Materialize a built-in library node into the graph — the human's drag/drop and palette path,
    /// exposed so a test drive (and an agent that wants a shipped node verbatim, e.g. `corner-pin`)
    /// can place one without authoring it.
    private func uiAddLibraryNode(_ arguments: [String: Any]) throws -> String {
        guard let library = arguments.string("library") else { throw SZMCPError.message("ui_add_library_node needs `library` (a NodeLibrary id, e.g. corner-pin)") }
        let x = (arguments["x"] as? NSNumber)?.doubleValue ?? 0
        let y = (arguments["y"] as? NSNumber)?.doubleValue ?? 0
        let id = try host.instantiateLibraryNode(libraryID: library, position: SZPoint(x: x, y: y),
                                                 origin: .agent)
        host.noteRunCreatedWork([id])   // added by the run's own tooling, so it joins its work set
        var response: [String: Any] = ["node": id.uuidString, "library": library]
        if let body = host.store.project?.graph.node(id: id)?.body { response["body"] = body.mode.rawValue }
        return SZJSONRPC.encode(response)
    }

    /// Coerce a JSON `value` to the port's declared type. Numbers arrive as JSON numbers or as numeric
    /// strings ("14", "true", "[0.1, 0.2]") — MCP clients serialise a loosely-typed argument as text.
    static func portValue(_ type: SZPortType, from raw: Any?) throws -> SZPortValue {
        func got() -> String {
            switch raw {
            case nil: "nothing"
            case let s as String: "\"\(s)\""
            case let v?: "\(v)"
            }
        }
        // A numeric string is parsed with the JSON number grammar, NOT `Double(_:)` — which also accepts
        // "nan", "inf" and hex floats ("0x1p3"). And whatever the form, the value must be FINITE: a NaN
        // compares false against every bound, so it survives the slider's clamp and lands in the runtime's
        // uniform buffer as a black frame nobody can trace back to a tool call.
        func finite(_ value: Double?) -> Double? { (value?.isFinite ?? false) ? value : nil }
        func number() throws -> Double {
            if let n = raw as? NSNumber, let d = finite(n.doubleValue) { return d }
            if let s = raw as? String, let d = finite(Self.jsonNumber(s)) { return d }
            throw SZMCPError.message("value must be a finite number (got \(got()))")
        }
        func array(_ count: Int) throws -> [Double] {
            var elements: [Any]? = raw as? [Any]
            if elements == nil, let s = raw as? String, let data = s.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                elements = parsed as? [Any]
            }
            let numbers = elements?.compactMap { finite(($0 as? NSNumber)?.doubleValue) }
            // One refusal for every way the array can be wrong (missing, mistyped entry, wrong arity), and
            // like the others it names what the agent SENT — a count would answer a question nobody asked.
            guard let numbers, numbers.count == elements?.count, numbers.count == count else {
                throw SZMCPError.message("value must be an array of \(count) finite numbers (got \(got()))")
            }
            return numbers
        }
        func string() throws -> String {
            guard let s = raw as? String else { throw SZMCPError.message("value must be a string (got \(got()))") }
            return s
        }
        switch type {
        case .float: return .float(try number())
        case .bool:
            if let n = raw as? NSNumber { return .bool(n.boolValue) }
            if let s = raw as? String {
                switch s.trimmingCharacters(in: .whitespaces).lowercased() {
                case "true", "1": return .bool(true)
                case "false", "0": return .bool(false)
                default: break
                }
            }
            throw SZMCPError.message("value must be a bool (got \(got()))")
        case .float2: return .float2(try array(2))
        case .float3: return .float3(try array(3))
        case .float4: return .float4(try array(4))
        case .colorRGB: return .colorRGB(try array(3))
        case .colorRGBA: return .colorRGBA(try array(4))
        case .float3x3: return .float3x3(try array(9))
        case .float4x4: return .float4x4(try array(16))
        case .enumeration: return .enumeration(try string())
        case .string: return .string(try string())
        case .event: return .event
        case .texture, .floatArray: throw SZMCPError.message("\(type.rawValue) inputs have no default value")
        }
    }

    /// A numeric string read with the JSON number grammar — the same one the array form parses with, so
    /// "14" / " 0.6 " / "1e3" pass while "nan", "inf", "0x1p3" and "14x" do not. The leading-character
    /// guard keeps JSON's other literals out: `true` would otherwise parse as the number 1.
    private static func jsonNumber(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "-" || first.isNumber else { return nil }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8),
                                                            options: [.fragmentsAllowed]) else { return nil }
        return (parsed as? NSNumber)?.doubleValue
    }

    private func uiShowPanel(_ arguments: [String: Any]) throws -> String {
        host.showPanel(try panelIDArgument(arguments, key: "panel"))
        return panelLayoutJSON()
    }

    private func uiClosePanel(_ arguments: [String: Any]) throws -> String {
        let id = try panelIDArgument(arguments, key: "panel")
        // The close no-ops on the last panel and on one that isn't open (tile OR pop-out). Report
        // what happened rather than echoing a layout that silently didn't change (cf.
        // ui_close_chat_tab's Director refusal).
        guard host.panelLayout.contains(id) || host.isPoppedOut(id) else {
            return refusedPanelClose("the \(id.token) panel isn't open")
        }
        host.closePanel(id)
        guard !host.panelLayout.contains(id) && !host.isPoppedOut(id) else {
            return refusedPanelClose("the last panel can't be closed")
        }
        return SZJSONRPC.encode(["closed": true, "layout": panelLayoutObject(),
                                 "popped_out_panels": poppedOutTokens()])
    }

    private func refusedPanelClose(_ reason: String) -> String {
        SZJSONRPC.encode(["closed": false, "reason": reason, "layout": panelLayoutObject(),
                          "popped_out_panels": poppedOutTokens()])
    }

    private func uiMovePanel(_ arguments: [String: Any]) throws -> String {
        let panel = try panelIDArgument(arguments, key: "panel")
        guard let zone = arguments.string("zone").flatMap(SZPanelDropZone.init(rawValue:)) else {
            throw SZMCPError.message("`zone` must be one of: left, right, top, bottom, center")
        }
        if arguments["onto"] != nil {
            host.movePanel(panel, onto: try panelIDArgument(arguments, key: "onto"), zone: zone)
        } else {
            guard zone != .center else {
                throw SZMCPError.message("`zone` can't be \"center\" without `onto`"
                    + " (a swap is between two panels)")
            }
            host.pinPanel(panel, to: zone)
        }
        return panelLayoutJSON()
    }

    private func uiClonePanel(_ arguments: [String: Any]) throws -> String {
        let source = try panelIDArgument(arguments, key: "panel")
        // Diagnose the refusal precisely — the gates mirror canClonePanel's, spelled out so the
        // caller learns WHICH one bit.
        guard source.kind.maxInstances > 1 else {
            return refusedPanelOp("cloned", "\(source.kind.rawValue) isn't cloneable")
        }
        guard host.panelLayout.contains(source) else {
            return refusedPanelOp("cloned", "the \(source.token) panel isn't open")
        }
        guard let clone = host.clonePanel(source) else {
            return refusedPanelOp("cloned",
                                  "all \(source.kind.maxInstances) \(source.kind.rawValue) tiles already exist")
        }
        return SZJSONRPC.encode(["cloned": true, "id": clone.token, "layout": panelLayoutObject(),
                                 "popped_out_panels": poppedOutTokens()])
    }

    private func uiPopoutPanel(_ arguments: [String: Any]) throws -> String {
        let id = try panelIDArgument(arguments, key: "panel")
        guard SZHost.popoutAllowedKinds.contains(id.kind) else {
            return refusedPanelOp("popped_out", "\(id.kind.rawValue) panels can't pop out")
        }
        guard !host.isPoppedOut(id) else {
            return refusedPanelOp("popped_out", "the \(id.token) panel is already popped out")
        }
        guard host.panelLayout.contains(id) else {
            return refusedPanelOp("popped_out", "the \(id.token) panel isn't open")
        }
        guard host.panelLayout.presentIDs.count > 1 else {
            return refusedPanelOp("popped_out", "the last panel can't pop out")
        }
        var frame: NSRect?
        if let x = arguments.double("x"), let y = arguments.double("y"),
           let width = arguments.double("width"), let height = arguments.double("height") {
            frame = NSRect(x: x, y: y, width: width, height: height)
        }
        host.popOutPanel(id, frame: frame)
        let applied = host.poppedOutPanels[id]
        return SZJSONRPC.encode(["popped_out": true,
                                 "frame": ["x": applied?.x ?? 0, "y": applied?.y ?? 0,
                                           "width": applied?.width ?? 0, "height": applied?.height ?? 0],
                                 "layout": panelLayoutObject(),
                                 "popped_out_panels": poppedOutTokens()])
    }

    private func uiDockPanel(_ arguments: [String: Any]) throws -> String {
        let id = try panelIDArgument(arguments, key: "panel")
        guard host.isPoppedOut(id) else {
            return refusedPanelOp("docked", "the \(id.token) panel isn't popped out")
        }
        let onto = arguments.string("onto")
        let zone = arguments.string("zone")
        if onto != nil || zone != nil {
            // The explicit-target (drag-to-dock) path: both args or neither.
            let target = try panelIDArgument(arguments, key: "onto")
            guard let zone = zone.flatMap(SZPanelDropZone.init(rawValue:)), zone != .center else {
                throw SZMCPError.message("`zone` must be one of: left, right, top, bottom"
                    + " (docking only splits — a detached panel has nothing to swap with)")
            }
            guard host.panelLayout.contains(target) else {
                return refusedPanelOp("docked", "the \(target.token) panel isn't open to dock onto")
            }
            host.dockPanel(id, onto: target, zone: zone)
        } else {
            host.dockPanel(id)
        }
        return SZJSONRPC.encode(["docked": true, "layout": panelLayoutObject(),
                                 "popped_out_panels": poppedOutTokens()])
    }

    /// A structured panel-op refusal: `{<verb>: false, reason, layout, popped_out_panels}`.
    /// The token array is deliberately NOT named "popped_out": that is ui_popout_panel's verb key,
    /// and a dictionary literal with a duplicate key traps at runtime.
    private func refusedPanelOp(_ verb: String, _ reason: String) -> String {
        SZJSONRPC.encode([verb: false, "reason": reason, "layout": panelLayoutObject(),
                          "popped_out_panels": poppedOutTokens()])
    }

    private func panelIDArgument(_ arguments: [String: Any], key: String) throws -> SZPanelID {
        guard let id = arguments.string(key).flatMap(SZPanelID.init(token:)) else {
            throw SZMCPError.message("`\(key)` must be one of: "
                + Self.panelTokens.joined(separator: ", "))
        }
        return id
    }

    /// The popped-out panels as tokens, sorted for stable assertions.
    private func poppedOutTokens() -> [String] {
        host.poppedOutPanels.keys.sorted().map(\.token)
    }

    /// The layout tree after a panel op — lets a closed-loop test assert the exact resulting shape.
    private func panelLayoutJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(host.panelLayout.root),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// The same tree as a JSON object, for nesting inside a response body.
    private func panelLayoutObject() -> Any {
        guard let data = try? JSONEncoder().encode(host.panelLayout.root),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [:] as [String: Any] }
        return object
    }
}
