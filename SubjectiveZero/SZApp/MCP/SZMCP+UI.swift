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
            tool("ui_connect", "Connect one node's output port to another's input port; returns the connection id. A data input holds at most one incoming connection — connecting to an occupied data input replaces the existing connection. Repeating an existing connection returns its id unchanged.",
                 properties: [
                    "from": ["type": "string"], "fromPort": ["type": "string"],
                    "to": ["type": "string"], "toPort": ["type": "string"],
                    "kind": ["type": "string", "enum": ["data", "flow"]],
                 ]),
            tool("ui_disconnect", "Remove a connection by id.",
                 properties: ["connection": ["type": "string"]]),
            tool("ui_update_node", "Update a node's title / sfSymbol / prompt / contract (reflows its UI).",
                 properties: [
                    "node": ["type": "string"],
                    "title": ["type": "string"], "sfSymbol": ["type": "string"],
                    "prompt": ["type": "string"], "summary": ["type": "string"],
                    "permissions": ["type": "array", "items": ["type": "string"],
                                    "description": "entitlements the node needs (camera, microphone)"],
                 ]),
            tool("ui_edit_ports", "Change a node's typed I/O. The ONLY way to add, retype, or remove a port — `ui_update_node` cannot touch the port surface. Omitted ports are left alone; removal is explicit, so you can never drop a control by forgetting to re-send it. `upsert` matches by name (re-sending a port replaces it, which is how you retype). Editing the surface of an already-implemented node marks it for rebuild (`needsRebuild`) and joins it to any run in flight — it keeps rendering its old build until its Coding Agent regenerates it. Data edges and the render endpoint that name a removed or retyped port are dropped.",
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
            tool("ui_set_provider", "Set the active provider (and optionally its model / reasoning effort / fast mode) for new agent sessions (runs + a fresh Director Agent chat). Mirrors the composer's provider cluster. NOTE: changing the provider resets all agent sessions (transcripts survive; each next message rebuilds context from its transcript) and is refused while a run or chat turn is in flight. The options apply to the provider being set and must be values it supports. Returns the resolved selection.",
                 properties: [
                    "provider": ["type": "string",
                                 "enum": SZProviderRegistry.shared.providers.map(\.id)],
                    "model": ["type": "string", "description": "one of the provider's models (omit = keep/default)"],
                    "reasoning_effort": ["type": "string", "description": "one of the provider's supported efforts (omit = keep/default; unsupported on claude)"],
                    "fast_mode": ["type": "boolean", "description": "toggle the provider's fast tier (omit = keep/default)"],
                 ]),
            tool("ui_run", "Start the implementation run over the current graph — a Coding Agent per pending node, with the active provider. `instruction` (optional) steers the run. Called from your own chat turn, the run is QUEUED and starts when your turn ends (finish your reply; do not wait for it). Refused while a run is already in flight.",
                 properties: [
                    "instruction": ["type": "string", "description": "optional free-text steer for the run"],
                 ]),
            tool("ui_stop", "Stop the in-flight run (mirrors the HUD Stop button) — cancels the Director and every coding agent. Returns {status: \"stopped\"} if a run was cancelled, or {status: \"not_running\"} if nothing was in flight.",
                 properties: [:]),
            tool("ui_send_chat", "Send a chat message to an agent. `scope` is a node id (chat that node's Coding Agent) or \"director\" (the Director Agent). Every accepted message returns a `message_id`; `status` is \"queued\" (enqueued — delivers as a real turn when the recipient is free; poll ui_message_status if you need the outcome) or \"recorded\" (a mid-run steer, folded into the recipient's next prompt). A fresh Director Agent chat uses the active provider; resuming continues on the session's own CLI.",
                 properties: [
                    "scope": ["type": "string", "description": "a node uuid, or \"director\" (default)"],
                    "message": ["type": "string"],
                 ]),
            tool("ui_message_status", "Delivery state of a message you sent (`message_id` from ui_send_chat): {state: queued|delivering|processed|failed, reason?}. `failed` carries the reason. Unknown ids (e.g. from before an app restart) return {state: \"unknown\"}. Poll between your own steps — the send never blocks.",
                 properties: ["message_id": ["type": "string"]]),
            tool("ui_set_input_default", "Set an unconnected input's default value (mirrors its slider/toggle/dropdown) — changes the live render. `value` is coerced to the port's declared type (number, bool, or array of numbers). A slider port's value is clamped to its `ui.min/max` and snapped to `ui.step`, exactly as dragging the slider would; the returned `value` is the APPLIED one, which may differ from what you asked for.",
                 properties: [
                    "node": ["type": "string"], "port": ["type": "string"],
                    "value": ["description": "number, bool, or array of numbers (per the port type)"],
                 ]),
            tool("ui_toggle_display", "Toggle a node's texture output as the viewport render endpoint (mirrors clicking the node card's monitor icon) — switches the live viewport to that output. Pointing at the current endpoint clears it. `port` must be a `texture` output.",
                 properties: ["node": ["type": "string"], "port": ["type": "string"]]),
            tool("ui_set_node_body", "Set a generated node card's body region (between header and rows). `mode`: \"none\" (compact card) or \"preview\" (a live thumbnail of a texture output — `port` picks which, defaulting to the display-marked/first texture output). An unset body auto-previews a texture node; an explicit value pins the choice. Geometry-affecting and persisted; echoes the applied body (including the resolved preview port).",
                 properties: [
                    "node": ["type": "string"],
                    "mode": ["type": "string", "enum": ["none", "preview"]],
                    "port": ["type": "string", "description": "preview only: which texture output to show"],
                 ]),
            tool("ui_select_chat", "Open/select a chat tab (mirrors clicking a tab or a node's chat bubble) and show the panel. `scope` = a node uuid (opens that node's Coding Agent chat) or \"director\".",
                 properties: ["scope": ["type": "string", "description": "a node uuid, or \"director\" (default)"]]),
            tool("ui_close_chat_tab", "Close a node's (or the Debug) chat tab, mirroring its ✕ — `scope` is required. Returns {closed:true, scope}. The Director tab has no ✕ and can't be closed: that returns {closed:false, reason}.",
                 properties: ["scope": ["type": "string", "description": "a node uuid, or \"debug\""]]),
            tool("ui_reorder_chat_tab", "Reorder chat tabs (mirrors dragging a tab): move the `scope` tab in front of the `before` tab. Each is a node uuid or \"director\" (any tab can move, including the Director).",
                 properties: [
                    "scope": ["type": "string", "description": "the tab to move: a node uuid or \"director\""],
                    "before": ["type": "string", "description": "move it in front of this tab: a node uuid or \"director\""],
                 ]),
            tool("ui_show_panel", "Show a top-level panel (mirrors its View-menu toggle) — reopens at its remembered spot. Returns the resulting layout tree.",
                 properties: ["panel": Self.panelProperty]),
            tool("ui_close_panel", "Close a top-level panel (mirrors its header ✕) — its split collapses and its spot is remembered. Returns {closed:true, layout}. The last panel can't be closed, and a panel that isn't open can't either: both return {closed:false, reason, layout}.",
                 properties: ["panel": Self.panelProperty]),
            tool("ui_move_panel", "Move a panel (mirrors dragging its header onto another panel): an edge `zone` splits `onto` with `panel` on that side; \"center\" swaps the two. Returns the resulting layout tree.",
                 properties: [
                    "panel": Self.panelProperty,
                    "onto": Self.panelProperty,
                    "zone": ["type": "string", "enum": ["left", "right", "top", "bottom", "center"]],
                 ]),
        ]
    }

    private nonisolated static var panelProperty: [String: Any] {
        ["type": "string", "enum": SZPanelKind.allCases.map(\.rawValue)]
    }

    func handleUITool(name: String, arguments: [String: Any]) throws -> String? {
        switch name {
        case "ui_add_prompt_node": return try uiAddPromptNode(arguments)
        case "ui_add_source_node": return try uiAddSourceNode(arguments)
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
        case "ui_run":             return uiRun(arguments)
        case "ui_stop":            return uiStop(arguments)
        case "ui_send_chat":       return try uiSendChat(arguments)
        case "ui_message_status":  return try uiMessageStatus(arguments)
        case "ui_set_input_default": return try uiSetInputDefault(arguments)
        case "ui_toggle_display":  return try uiToggleDisplay(arguments)
        case "ui_set_node_body":   return try uiSetNodeBody(arguments)
        case "ui_select_chat":     return try uiSelectChat(arguments)
        case "ui_close_chat_tab":  return try uiCloseChatTab(arguments)
        case "ui_reorder_chat_tab": return try uiReorderChatTab(arguments)
        case "ui_show_panel":      return try uiShowPanel(arguments)
        case "ui_close_panel":     return try uiClosePanel(arguments)
        case "ui_move_panel":      return try uiMovePanel(arguments)
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
        let created = host.createMediaNodes(specs)
        guard created.count == specs.count else {   // a disk/compile failure part-way; the rest did land
            throw SZMCPError.message(
                "created \(created.count) of \(specs.count) source nodes — read the graph to see which")
        }

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
            let match = SZGraphCanvasModel.connectableSockets(of: node).first {
                $0.side == side && $0.kind == kind && (kind == .flow || $0.port == port)
            }
            guard let socket = match else {
                throw SZMCPError.message("node \(node.id) has no \(kindRaw) \(side == .output ? "output" : "input") port '\(port)' — call agent_read_node to see its ports")
            }
            return socket
        }
        let src = try resolveSocket(on: fromNode, side: .output, port: fromPort)
        let dst = try resolveSocket(on: toNode, side: .input, port: toPort)
        guard SZGraphCanvasModel.canConnect(src, dst, in: graph) else {
            if from == to { throw SZMCPError.message("cannot connect node \(from) to itself") }
            throw SZMCPError.message("incompatible \(kindRaw) connection \(fromNode.title):\(fromPort) → \(toNode.title):\(toPort) (port types differ)")
        }
        try requireUnfenced([from, to])
        // Through the host (not bare store.connect) so the new edge persists + reloads the runtime.
        let connection = host.addConnection(
            from: SZPortRef(node: from, port: fromPort),
            to: SZPortRef(node: to, port: toPort),
            kind: kind,
            origin: .agent
        )
        guard let connection else { throw SZMCPError.message("no project loaded") }
        return SZJSONRPC.encode(["id": connection.uuidString])
    }

    private func uiStop(_ arguments: [String: Any]) -> String {
        guard host.isRunning else { return SZJSONRPC.encode(["status": "not_running"]) }
        host.cancelRun()   // cancels the run Task + every coding agent; force-clears isRunning even if wedged
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
        try requireUnfenced([id])
        let found = host.store.updateNode(
            id: id,
            title: arguments.string("title"),
            sfSymbol: arguments.string("sfSymbol"),
            prompt: arguments.string("prompt"),
            summary: arguments.string("summary"),
            permissions: permissions
        )
        guard found else { throw SZMCPError.message("no node \(id)") }
        host.persistGraphEditAndReload(action: "update node")
        return SZJSONRPC.encode(["updated": true])
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
        let inputs = try ports("inputs"), outputs = try ports("outputs")
        let edit = SZStore.SZPortEdit(upsertInputs: inputs.upsert, removeInputs: inputs.remove,
                                      upsertOutputs: outputs.upsert, removeOutputs: outputs.remove)
        guard !edit.isEmpty else { throw SZMCPError.message("ui_edit_ports needs at least one upsert or remove") }

        try requireUnfenced([id])
        let result = host.store.editPorts(node: id, edit)
        guard result.found else { throw SZMCPError.message("no node \(id)") }
        // The store guessed `.contractChanged`; only reading the live source can tell whether the code is merely
        // behind the new contract or now names ports that don't exist (dropping a port the code reads leaves
        // those reads resolving to nil every frame — a fault, not an unfinished feature).
        host.classifyRebuild(node: id)
        if result.raisedRebuild { host.noteRunCreatedWork([id]) }
        // Through the host (not a bare store edit) so the new contract + the rebuild flag reach disk and the
        // runtime — otherwise a crash before the next run loses both. Safe because `kind` is untouched: a
        // reload re-renders the node rather than dropping it from `renderableSubgraph`.
        host.persistGraphEditAndReload(action: "edit ports")

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
        let position = placedPosition(x: x, y: y, cardSize: SZNodeLayout.size(of: node))
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
        // Echo the RESOLVED selection so a driving agent's world model tracks the applied truth.
        let resolved = host.resolvedGenerationSettings(for: host.activeProviderID)
        var response: [String: Any] = ["provider": host.activeProviderID,
                                       "model": resolved.model ?? "",
                                       "fast_mode": resolved.fastMode ?? false]
        if let effort = resolved.reasoningEffort { response["reasoning_effort"] = effort }
        return SZJSONRPC.encode(response)
    }

    private func uiRun(_ arguments: [String: Any]) -> String {
        guard !host.isRunning else {
            return SZJSONRPC.encode(["status": "refused", "reason": "a run is already in flight"])
        }
        let instruction = arguments.string("instruction") ?? ""
        // Called from the Director Agent's OWN streaming chat turn: starting now would race that
        // turn on the same transcript (deliver's one-in-flight-marker-per-scope invariant), so the
        // run is recorded and fired at turn end — with the chat turn standing in for the run's
        // decompose turn (`directorAlreadyBriefed`). See SZHost.pendingDirectorRun.
        if host.chatInFlight.contains(SZChatScope.directorKey) {
            host.pendingDirectorRun = instruction
            return SZJSONRPC.encode(["status": "queued",
                                     "detail": "the run starts when your current turn ends"])
        }
        host.startRun(instruction: instruction)   // returns immediately; the run streams into the tabs
        return SZJSONRPC.encode(["status": "started", "provider": host.activeProviderID])
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
        case .sent:
            return SZJSONRPC.encode(["status": "sent", "scope": scope.key])
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
        return SZJSONRPC.encode(response)
    }

    /// A port value as its natural JSON type — mirrors `portValue`'s coercion in reverse. Taken off the
    /// enum rather than `SZPortValue.floats`, which narrows to `Float` (echoing 1.2 as 1.2000000476…)
    /// and flattens a bool to 1/0.
    private static func jsonValue(_ value: SZPortValue) -> Any? {
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
        guard let modeRaw = arguments.string("mode"), let mode = SZNodeBodyMode(rawValue: modeRaw),
              mode != .custom else {   // custom cards haven't landed natively yet
            throw SZMCPError.message("ui_set_node_body needs `mode` ∈ {none, preview}")
        }
        guard let node = host.store.project?.graph.node(id: id) else {
            throw SZMCPError.message("no node \(id)")
        }
        // Body is a generated-card affordance: a prompt card is a single field with no body region.
        guard node.kind == .generated else {
            throw SZMCPError.message("node \(id) is a prompt card — it has no body region")
        }

        let body: SZNodeBody
        if mode == .preview {
            // The explicit `port` must be a texture output; omitted, the shared default rule picks
            // one (`preferredTextureOutput` — the SAME pick the card's auto-preview shows, so the
            // echoed body can never disagree with the canvas). No texture output → nothing to
            // preview → reject, so the persisted body is always renderable.
            let outputs = node.contract?.outputs ?? []
            if let port = arguments.string("port") {
                guard outputs.contains(where: { $0.name == port && $0.type == .texture }) else {
                    throw SZMCPError.message("node \(id) has no texture output port '\(port)'")
                }
                body = SZNodeBody(mode: .preview, previewPort: port)
            } else if let port = outputs.preferredTextureOutput?.name {
                body = SZNodeBody(mode: .preview, previewPort: port)
            } else {
                throw SZMCPError.message("node \(id) has no texture output to preview")
            }
        } else {
            body = SZNodeBody(mode: .none)
        }

        // The same host op as the card's photo toggle — one apply choreography (store write, stale
        // thumb drop, persist, watch-set refresh) for human and agent edits.
        try requireUnfenced([id])
        guard host.setNodeBody(node: id, body: body, origin: .agent) else {
            throw SZMCPError.message("no node \(id)")
        }

        var applied: [String: Any] = ["mode": body.mode.rawValue]
        if let previewPort = body.previewPort { applied["previewPort"] = previewPort }
        return SZJSONRPC.encode(["body": applied])
    }

    /// Coerce a JSON `value` to the port's declared type.
    private static func portValue(_ type: SZPortType, from raw: Any?) throws -> SZPortValue {
        func number() throws -> Double {
            guard let n = raw as? NSNumber else { throw SZMCPError.message("value must be a number") }
            return n.doubleValue
        }
        func array() throws -> [Double] {
            guard let a = raw as? [Any] else { throw SZMCPError.message("value must be an array of numbers") }
            return a.compactMap { ($0 as? NSNumber)?.doubleValue }
        }
        func string() throws -> String {
            guard let s = raw as? String else { throw SZMCPError.message("value must be a string") }
            return s
        }
        switch type {
        case .float: return .float(try number())
        case .bool:
            if let n = raw as? NSNumber { return .bool(n.boolValue) }
            return .bool(try number() != 0)
        case .float2: return .float2(try array())
        case .float3: return .float3(try array())
        case .float4: return .float4(try array())
        case .colorRGB: return .colorRGB(try array())
        case .colorRGBA: return .colorRGBA(try array())
        case .float3x3: return .float3x3(try array())
        case .float4x4: return .float4x4(try array())
        case .enumeration: return .enumeration(try string())
        case .string: return .string(try string())
        case .event: return .event
        case .texture, .floatArray: throw SZMCPError.message("\(type.rawValue) inputs have no default value")
        }
    }

    private func uiSelectChat(_ arguments: [String: Any]) throws -> String {
        let scope = try chatScope(arguments, tool: "ui_select_chat")
        host.showChat(scope)
        return SZJSONRPC.encode(["scope": scope.key])
    }

    private func uiCloseChatTab(_ arguments: [String: Any]) throws -> String {
        // `chatScope` defaults a missing scope to the Director, so without this an argument-less call
        // would come back as the Director refusal below — answering a question the caller never asked.
        guard arguments.string("scope") != nil else {
            throw SZMCPError.message("ui_close_chat_tab needs a `scope` (a node uuid, or \"debug\")")
        }
        let scope = try chatScope(arguments, tool: "ui_close_chat_tab")
        // The Director tab has no ✕ in the UI and `closeChatTab` no-ops on it. Say so, rather than
        // reporting the close we didn't do. A well-formed request refused by a rule is a structured
        // answer (cf. ui_run's `refused`), not a tool error.
        guard scope != .director else {
            return SZJSONRPC.encode(["closed": false, "reason": "the Director tab can't be closed"])
        }
        host.closeChatTab(scope)
        return SZJSONRPC.encode(["closed": true, "scope": scope.key])
    }

    private func uiReorderChatTab(_ arguments: [String: Any]) throws -> String {
        guard arguments.string("scope") != nil, arguments.string("before") != nil else {
            throw SZMCPError.message("ui_reorder_chat_tab needs `scope` and `before` node ids")
        }
        host.reorderChatTabs(move: try chatScope(arguments, tool: "ui_reorder_chat_tab"),
                             before: try chatScope(arguments, tool: "ui_reorder_chat_tab", key: "before"))
        return SZJSONRPC.encode(["tabs": host.chatTabs.map(\.key)])
    }

    private func uiShowPanel(_ arguments: [String: Any]) throws -> String {
        host.showPanel(try panelKindArgument(arguments, key: "panel"))
        return panelLayoutJSON()
    }

    private func uiClosePanel(_ arguments: [String: Any]) throws -> String {
        let kind = try panelKindArgument(arguments, key: "panel")
        // `removePanel` no-ops on the last panel and on one that isn't open. Report what happened rather
        // than echoing a layout that silently didn't change (cf. ui_close_chat_tab's Director refusal).
        guard host.panelLayout.contains(kind) else {
            return refusedPanelClose("the \(kind.rawValue) panel isn't open")
        }
        host.closePanel(kind)
        guard !host.panelLayout.contains(kind) else {
            return refusedPanelClose("the last panel can't be closed")
        }
        return SZJSONRPC.encode(["closed": true, "layout": panelLayoutObject()])
    }

    private func refusedPanelClose(_ reason: String) -> String {
        SZJSONRPC.encode(["closed": false, "reason": reason, "layout": panelLayoutObject()])
    }

    private func uiMovePanel(_ arguments: [String: Any]) throws -> String {
        let panel = try panelKindArgument(arguments, key: "panel")
        let onto = try panelKindArgument(arguments, key: "onto")
        guard let zone = arguments.string("zone").flatMap(SZPanelDropZone.init(rawValue:)) else {
            throw SZMCPError.message("`zone` must be one of: left, right, top, bottom, center")
        }
        host.movePanel(panel, onto: onto, zone: zone)
        return panelLayoutJSON()
    }

    private func panelKindArgument(_ arguments: [String: Any], key: String) throws -> SZPanelKind {
        guard let kind = arguments.string(key).flatMap(SZPanelKind.init(rawValue:)) else {
            throw SZMCPError.message("`\(key)` must be one of: "
                + SZPanelKind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return kind
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
