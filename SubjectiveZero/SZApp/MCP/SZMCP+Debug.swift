// SPDX-License-Identifier: AGPL-3.0-only
// The `debug_*` MCP surface — verify + operate (docs/MCP.md). Read build errors, snapshot the live
// graph, freeze the clock. One extension per surface (BUILD_SPEC.md MCP+*.swift pattern); `agent_*`
// and `ui_*` live in their own sibling files. (Frame capture is `agent_view_frame` in SZMCP+Agent.swift.)
import Foundation
import SZCore

extension SZHostBridge {
    nonisolated static var debugToolDefinitions: [[String: Any]] {
        [
            tool("debug_get_build_errors", "Return the most recent node build errors, or (none)."),
            tool("debug_snapshot_state", "Return the live project graph as JSON."),
            tool("debug_chat_transcript", "Return a chat transcript as JSON (role/text per message).",
                 properties: ["scope": ["type": "string", "description": "a node uuid, or \"director\" (default)"]]),
            tool("debug_agent_state", "Agent/chat state for closed-loop tests: `isRunning` (a Director Agent run in flight), `sessions` (scopes with a resumable agent session), `chatting` (node ids whose Coding Agent is mid-chat-turn → shown Coding + locked), `tabs` (chat tab order, left→right), `orchestrator` (the active orchestration strategy), and `statuses` (each node's last `agent_report_status` — the reconcile-loop signal)."),
            tool("debug_set_orchestrator", "Select the orchestration (Director) strategy for the next run (stop-gap for the Settings screen): `procedural` (deterministic / offline) or `agentic` (an LLM Director Agent). Takes effect on the next ui_run.",
                 properties: ["strategy": ["type": "string", "enum": ["procedural", "agentic"]]]),
            tool("debug_fail_node_once", "Test affordance: force a node to fail its NEXT coding dispatch — report `needsInput` without running an agent — so the reconcile loop fires live & repeatably (the agents rarely fail on their own). Consumed once. Call before ui_run.",
                 properties: [
                    "node": ["type": "string", "description": "node id (UUID)"],
                    "message": ["type": "string", "description": "the blocker the node reports (optional) — a realistic one steers the Director's reconcile turn"],
                 ]),
            tool("debug_set_paused", "Freeze or resume the render clock (mirrors the HUD Pause/Play button). `paused:true` freezes time + frame index so successive `agent_view_frame`s render the same instant — the deterministic way to A/B an input (e.g. sweep a slider and compare frames without the camera/animation drifting between captures). `paused:false` resumes. Idempotent; returns the applied `paused`.",
                 properties: ["paused": ["type": "boolean", "description": "true = pause, false = resume"]]),
        ]
    }

    /// Handle a `debug_*` call, or nil if `name` isn't ours.
    func handleDebugTool(name: String, arguments: [String: Any]) throws -> String? {
        switch name {
        case "debug_get_build_errors": return host.lastBuildErrors ?? "(none)"
        case "debug_snapshot_state":   return debugSnapshotState()
        case "debug_chat_transcript":  return try debugChatTranscript(arguments)
        case "debug_agent_state":      return debugAgentState()
        case "debug_set_orchestrator": return try debugSetOrchestrator(arguments)
        case "debug_fail_node_once":   return try debugFailNodeOnce(arguments)
        case "debug_set_paused":       return try debugSetPaused(arguments)
        default: return nil
        }
    }

    /// Freeze/resume the render clock via the same host path as the HUD Pause/Play button, so its icon
    /// stays in sync. Explicit boolean (not a toggle) so a scripted A/B — pause, set an input, capture,
    /// change the input, capture — is deterministic regardless of the current state.
    private func debugSetPaused(_ arguments: [String: Any]) throws -> String {
        guard let paused = arguments["paused"] as? Bool else {
            throw SZMCPError.message("debug_set_paused needs `paused` (bool)")
        }
        if host.isPaused != paused { host.togglePlayback() }
        return SZJSONRPC.encode(["paused": host.isPaused])
    }

    private func debugFailNodeOnce(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments.uuid("node") else { throw SZMCPError.message("debug_fail_node_once needs `node` (UUID)") }
        let blocker = arguments.string("message") ?? "(debug) forced failure for reconcile test"
        host.forceFailNodeOnce(node: id, blocker: blocker)
        return SZJSONRPC.encode(["willFailOnce": id.uuidString])
    }

    private func debugAgentState() -> String {
        SZJSONRPC.encode([
            "isRunning": host.isRunning,
            "sessions": Array(host.agentSessions.keys).sorted(),
            "chatting": host.nodeAgentState.filter(\.value.isChatting).keys.map(\.uuidString).sorted(),
            "tabs": host.chatTabs.map(\.key),       // chat tab order (left→right), Director first
            "orchestrator": host.orchestratorStrategy.rawValue,   // active strategy
            // node uuid → last reported status line (the reconcile signal).
            "statuses": Dictionary(uniqueKeysWithValues: host.nodeStatusLines.map { ($0.key.uuidString, $0.value) }),
        ])
    }

    private func debugSetOrchestrator(_ arguments: [String: Any]) throws -> String {
        guard let strategy = arguments.string("strategy") else {
            throw SZMCPError.message("debug_set_orchestrator needs `strategy`")
        }
        guard host.setOrchestrator(strategy) else { throw SZMCPError.message("unknown strategy \(strategy)") }
        return SZJSONRPC.encode(["orchestrator": strategy])
    }

    private func debugChatTranscript(_ arguments: [String: Any]) throws -> String {
        let scope = try chatScope(arguments, tool: "debug_chat_transcript")
        let messages = host.store.messages(for: scope).map {
            ["role": $0.role.rawValue, "text": $0.text, "thinking": $0.thinking]
        }
        return SZJSONRPC.encode(["scope": scope.key, "messages": messages])
    }

    private func debugSnapshotState() -> String {
        guard let project = host.store.project else { return "{}" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(project),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "{}" }

        // Enrich each enum port with its EFFECTIVE options (the node's runtime-enumerated list for a
        // dynamic enum like `camera`, else the static contract `options`) so an agent reading the snapshot
        // sees the same choices the editor dropdown offers (its current value is already in `default`).
        if var graph = root["graph"] as? [String: Any], var nodes = graph["nodes"] as? [[String: Any]] {
            for i in nodes.indices {
                guard let idString = nodes[i]["id"] as? String, let id = SZNodeID(uuidString: idString),
                      var contract = nodes[i]["contract"] as? [String: Any],
                      var inputs = contract["inputs"] as? [[String: Any]] else { continue }
                for j in inputs.indices where inputs[j]["type"] as? String == "enum" {
                    guard let port = inputs[j]["name"] as? String else { continue }
                    let effective = host.effectiveOptions(node: id, port: port)
                    if !effective.isEmpty { inputs[j]["options"] = effective.map { [$0.label, $0.value] } }
                }
                contract["inputs"] = inputs
                nodes[i]["contract"] = contract
            }
            graph["nodes"] = nodes
            root["graph"] = graph
        }

        guard let out = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted]) else {
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: out, as: UTF8.self)
    }
}
