// SPDX-License-Identifier: AGPL-3.0-only
// The `debug_*` MCP surface — verify + operate (docs/MCP.md). Read build errors, snapshot the live
// graph, freeze the clock. One extension per surface (BUILD_SPEC.md MCP+*.swift pattern); `agent_*`
// and `ui_*` live in their own sibling files. (Frame capture is `agent_view_frame` in SZMCP+Agent.swift.)
import AppKit
import Foundation
import SZAI
import SZCore
import SZRuntime
import Synchronization

extension SZHostBridge {
    nonisolated static var debugToolDefinitions: [[String: Any]] {
        [
            tool("debug_get_build_errors", "Return the most recent node build errors, or (none)."),
            tool("debug_snapshot_state", "Return the live project graph as JSON."),
            tool("debug_chat_transcript", "Return a chat transcript as JSON — role/text/thinking plus, where present, timestamp/duration/usage/breakdown per message (the same numbers the in-app turn breakdown shows).",
                 properties: ["scope": ["type": "string", "description": "a node uuid, or \"director\" (default)"]]),
            tool("debug_turn_timings", "Per-turn timing data for profiling, as JSON: completed agent turns per scope — {turnID, start, duration, usage, events} where events are the turn's recorded phases (queue wait, first output, tool spans, compile/promote, the CLI's own report) with id/parent (span hierarchy) and runID (run grouping). The latest run's rollup rides the Director run-complete narration (run.* stages). `tracing` reports whether collection is on (SZ_TRACE / DEBUG).",
                 properties: ["scope": ["type": "string", "description": "a node uuid or \"director\" to filter; omit for every scope"]]),
            tool("debug_run_summary", "A recorded run's report as human-readable text — the same summary the Debug panel's Copy button produces: header (wall, tokens, cost), the run timeline with offsets, and each turn's phase list. Defaults to the most recent run.",
                 properties: ["run": ["type": "string", "description": "a runID (or unique prefix) from debug_turn_timings; omit for the latest run"]]),
            tool("debug_run_tokens", "A recorded run's per-turn TOKEN report as text — the same output the Profiler's Copy Tokens button produces: each turn's in (cached %), out (reasoning), and cost on the run's clock. Per-turn totals — CLIs report usage once, at turn end. Defaults to the most recent run.",
                 properties: ["run": ["type": "string", "description": "a runID (or unique prefix) from debug_turn_timings; omit for the latest run"]]),
            tool("debug_turn_prompt", "The rendered prompt a turn ACTUALLY sent to its CLI, verbatim — inspect what the agent was briefed with. Survives relaunches via the on-disk debug capture (newest \(SZHost.debugTurnCaptureCap) turns; tool-result payloads live beside it in Application Support/SubjectiveZero/debug-turns/<turnID>/).",
                 properties: ["turn": ["type": "string", "description": "a turnID from debug_turn_timings; omit for the most recent turn"]]),
            tool("debug_agent_state", "Agent/chat state for closed-loop tests: `isRunning` (a run in flight), `sessions` (scopes with a resumable agent session), `chatting` (node ids whose Coding Agent is mid-chat-turn → shown Coding + locked), `tabs` (chat tab order, left→right), and `statuses` (each node's last `agent_report_status` — the reconcile-loop signal)."),
            tool("debug_fail_node_once", "Test affordance: force a node to fail its NEXT coding dispatch — report `needsInput` without running an agent — so the reconcile loop fires live & repeatably (the agents rarely fail on their own). Consumed once. Call before ui_run.",
                 properties: [
                    "node": ["type": "string", "description": "node id (UUID)"],
                    "message": ["type": "string", "description": "the blocker the node reports (optional) — a realistic one steers the Director's reconcile turn"],
                 ]),
            tool("debug_set_paused", "Freeze or resume the render clock (mirrors the HUD Pause/Play button). `paused:true` freezes time + frame index so successive `agent_view_frame`s render the same instant — the deterministic way to A/B an input (e.g. sweep a slider and compare frames without the camera/animation drifting between captures). `paused:false` resumes. Idempotent; returns the applied `paused`.",
                 properties: ["paused": ["type": "boolean", "description": "true = pause, false = resume"]]),
            tool("debug_quit", "Quit the app cleanly, exactly like ⌘Q (windows close, state persists, the camera stops). Test-bus only — the way an automated drive ends a session instead of resorting to kill signals that skip teardown. Replies before terminating."),
            tool("debug_check_pack", "PRE-FLIGHT a pack of agent folders without spending a token: load + validate `path` exactly as the host would (decode, naming, graph shape, the door, seats, dispatch targets, turn briefs, step folders), returning each agent's summary, the sorted defect list, and a verdict naming the highest tier honestly attained — `loads`, `validates`, or `does not load`. Step-attached checks (a compiled step's declared outcomes) compile every step folder through the real toolchain first — expect seconds, not milliseconds. Omit `path` for the live packs root (the materialized bundled packs, or SZ_AGENT_PACKS).",
                 properties: ["path": ["type": "string", "description": "absolute path to a pack root (a directory of agent folders)"]]),
        ]
    }

    /// Handle a `debug_*` call, or nil if `name` isn't ours.
    func handleDebugTool(name: String, arguments: [String: Any]) throws -> String? {
        switch name {
        case "debug_get_build_errors": return host.lastBuildErrors ?? "(none)"
        case "debug_snapshot_state":   return debugSnapshotState()
        case "debug_chat_transcript":  return try debugChatTranscript(arguments)
        case "debug_turn_timings":     return try debugTurnTimings(arguments)
        case "debug_run_summary":      return try debugRunSummary(arguments)
        case "debug_run_tokens":       return try debugRunTokens(arguments)
        case "debug_turn_prompt":      return try debugTurnPrompt(arguments)
        case "debug_agent_state":      return debugAgentState()
        case "debug_fail_node_once":   return try debugFailNodeOnce(arguments)
        case "debug_set_paused":       return try debugSetPaused(arguments)
        case "debug_quit":             return debugQuit()
        case "debug_check_pack":       return debugCheckPack(arguments)
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

    /// The pack pre-flight, rendered by the same loader path the host will use. The tool
    /// handler is synchronous, so the loader's async report is awaited on a detached task and
    /// joined here. Step-attached checks compile every step folder through the real runtime
    /// (one swiftc each) — a check with steps is seconds, not milliseconds, and honestly so.
    /// The automated drive's ⌘Q: reply, then terminate through the ordinary AppKit path on
    /// the next runloop turn — windows close, state persists, capture devices stop. Never a
    /// signal: SIGKILL skips exactly the teardown a drive needs to have happened.
    private func debugQuit() -> String {
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
        return SZJSONRPC.encode(["quitting": true])
    }

    private func debugCheckPack(_ arguments: [String: Any]) -> String {
        guard let root = arguments.string("path").map({ URL(filePath: $0) })
            ?? SZHost.graphAgentPacksRoot() else {
            return "no packs root — the bundled packs did not materialize and no SZ_AGENT_PACKS "
                + "override is set; pass `path` to a pack root (a directory of agent folders)"
        }
        final class Box: @unchecked Sendable { var report = "" }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.report = await SZAgentPackLoader.check(root: root, steps: SZPackStepProvider(root: root))
            done.signal()
        }
        // A deadline, because this thread is the bridge: a pathological Step.swift can hang
        // swiftc, and a hung check must degrade to one honest sentence, not stall the bus.
        guard done.wait(timeout: .now() + 300) == .success else {
            return "check timed out after 300s — a step compile is likely wedged; the report was abandoned"
        }
        return box.report
    }

    /// The check tool's step seam: each step folder compiles through the real toolchain —
    /// the same swiftc → codesign → dlopen → declaration read launch will use — into
    /// throwaway build dirs, entirely OFF the main actor (the tool handler blocks the
    /// bridge thread while waiting, so nothing here may hop to it). nil = no `Step.swift`
    /// or a step that declares nothing; throw = the compile went red, with the compiler's
    /// message as the defect detail.
    private final class SZPackStepProvider: SZStepProviding, @unchecked Sendable {
        let root: URL
        /// One compile per step folder, however many graph nodes reference it.
        private let cache = Mutex<[String: Result<SZStepDeclarationInfo?, any Error>]>([:])
        init(root: URL) { self.root = root }

        func declaration(agent: String, step: String) async throws -> SZStepDeclarationInfo? {
            let key = "\(agent)/\(step)"
            if let cached = cache.withLock({ $0[key] }) { return try cached.get() }
            let fresh: Result<SZStepDeclarationInfo?, any Error>
            do { fresh = .success(try await compileAndDeclare(agent: agent, step: step)) }
            catch { fresh = .failure(error) }
            cache.withLock { $0[key] = fresh }
            return try fresh.get()
        }

        private func compileAndDeclare(agent: String, step: String) async throws -> SZStepDeclarationInfo? {
            let source = root.appending(path: "\(agent)/steps/\(step)/Step.swift")
            guard FileManager.default.fileExists(atPath: source.path) else { return nil }
            let scratch = FileManager.default.temporaryDirectory
                .appending(path: "sz-check-pack-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }

            let dylib = try SZToolchain().compile(stepSource: source,
                                                  into: scratch.appending(path: "build"))
            let loader = SZStepLoader()
            try loader.load(dylib: dylib, runtimeLoadsDir: scratch.appending(path: "runtime-loads"))
            guard let json = loader.declaration else { return nil }
            return try JSONDecoder().decode(SZStepDeclarationInfo.self, from: Data(json.utf8))
        }
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
            // node uuid → last reported status line (the reconcile signal).
            "statuses": Dictionary(uniqueKeysWithValues: host.nodeStatusLines.map { ($0.key.uuidString, $0.value) }),
        ])
    }

    private func debugChatTranscript(_ arguments: [String: Any]) throws -> String {
        let scope = try chatScope(arguments, tool: "debug_chat_transcript")
        let messages = host.store.messages(for: scope).map { Self.messageJSON($0) }
        return SZJSONRPC.encode(["scope": scope.key, "messages": messages])
    }

    /// The profiling read path for a debugging agent on the test bus: every completed agent turn's
    /// wall time, usage, and recorded phase events, per scope — machine-shaped (no transcript prose
    /// to parse). Reads the store, so it covers restored transcripts too; with tracing off it
    /// still lists turns (durations persist regardless), just without `events`.
    private func debugTurnTimings(_ arguments: [String: Any]) throws -> String {
        let scopeKeys: [String]
        if arguments.string("scope") != nil {
            scopeKeys = [try chatScope(arguments, tool: "debug_turn_timings").key]
        } else {
            scopeKeys = host.store.chat.keys.sorted()
        }
        var scopes: [String: Any] = [:]
        for key in scopeKeys {
            guard let scope = SZChatScope(key: key) else { continue }
            let turns: [[String: Any]] = host.store.messages(for: scope).compactMap { message in
                guard message.role != .user,
                      message.duration != nil || !(message.breakdown ?? []).isEmpty else { return nil }
                var turn: [String: Any] = ["turnID": message.id.uuidString,
                                           "start": Self.iso8601.string(from: message.timestamp)]
                if let duration = message.duration { turn["duration"] = duration }
                if let usage = message.usage { turn["usage"] = Self.usageJSON(usage) }
                if let events = message.breakdown, !events.isEmpty {
                    turn["events"] = events.map { Self.eventJSON($0) }
                }
                return turn
            }
            if !turns.isEmpty { scopes[key] = turns }
        }
        return SZJSONRPC.encode(["scopes": scopes, "tracing": SZTrace.isEnabled])
    }

    /// The run report, rendered by the same SZCore code path as the Debug panel's Copy button.
    private func debugRunSummary(_ arguments: [String: Any]) throws -> String {
        try resolveRunRecord(arguments, toolName: "debug_run_summary")
            .map(SZTurnBreakdown.renderSummary) ?? noRunsMessage
    }

    /// The panel's Copy Tokens twin: the per-turn token report (`renderTokenReport`).
    private func debugRunTokens(_ arguments: [String: Any]) throws -> String {
        try resolveRunRecord(arguments, toolName: "debug_run_tokens")
            .map(SZTurnBreakdown.renderTokenReport) ?? noRunsMessage
    }

    private var noRunsMessage: String {
        SZTrace.isEnabled ? "(no recorded runs in this project yet — do a run first)"
                          : "(tracing is off — SZ_TRACE/DEBUG gate; no runs recorded)"
    }

    /// The shared `run` argument resolution: default latest, prefix-match otherwise. nil = no
    /// records at all (the caller's tracing-aware empty message applies).
    private func resolveRunRecord(_ arguments: [String: Any],
                                  toolName: String) throws -> SZTurnBreakdown.RunRecord? {
        let records = SZTurnBreakdown.runRecords(chat: host.store.chat, titles: host.nodeTitlesByScopeKey)
        guard !records.isEmpty else { return nil }
        guard let wanted = arguments.string("run") else { return records[0] }
        let matches = records.filter { $0.id.uuidString.lowercased().hasPrefix(wanted.lowercased()) }
        guard matches.count == 1 else {
            throw SZMCPError.message(matches.isEmpty
                ? "\(toolName): no run matches \"\(wanted)\" — see debug_turn_timings for runIDs"
                : "\(toolName): \"\(wanted)\" is ambiguous (\(matches.count) runs) — use more of the id")
        }
        return matches[0]
    }

    /// The verbatim prompt a turn sent to its CLI — the in-memory ring, else the on-disk debug
    /// capture (survives relaunches; newest `debugTurnCaptureCap` turns).
    private func debugTurnPrompt(_ arguments: [String: Any]) throws -> String {
        guard let turnID = arguments.uuid("turn") ?? host.turnPromptOrder.last else {
            return "(no prompts recorded this session — run a turn first, or pass `turn` for a"
                + " captured past turn)"
        }
        guard let prompt = host.heldPrompt(for: turnID) else {
            throw SZMCPError.message("debug_turn_prompt: no prompt held for \(turnID.uuidString) — "
                + "only the last \(SZHost.debugTurnCaptureCap) captured turns are kept")
        }
        return prompt
    }

    // MARK: transcript/timing JSON builders (shared by the two tools above)

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        // Fractional seconds, or every µs/ms-scale event in a breakdown collapses onto the same
        // whole-second `start` and a debugging agent can't order them.
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func messageJSON(_ message: SZChatMessage) -> [String: Any] {
        var m: [String: Any] = ["role": message.role.rawValue, "text": message.text,
                                "thinking": message.thinking,
                                "timestamp": iso8601.string(from: message.timestamp)]
        if let duration = message.duration { m["duration"] = duration }
        if let usage = message.usage { m["usage"] = usageJSON(usage) }
        if let events = message.breakdown, !events.isEmpty { m["breakdown"] = events.map { eventJSON($0) } }
        return m
    }

    private static func usageJSON(_ usage: SZTokenUsage) -> [String: Any] {
        var u: [String: Any] = ["inputTokens": usage.inputTokens, "outputTokens": usage.outputTokens]
        if let cached = usage.cachedInputTokens { u["cachedInputTokens"] = cached }
        if let reasoning = usage.reasoningOutputTokens { u["reasoningOutputTokens"] = reasoning }
        if let cost = usage.costUSD { u["costUSD"] = cost }
        return u
    }

    private static func eventJSON(_ event: SZTurnEvent) -> [String: Any] {
        var e: [String: Any] = ["stage": event.stage, "start": iso8601.string(from: event.start)]
        if let duration = event.duration { e["duration"] = duration }
        if let detail = event.detail { e["detail"] = detail }
        if let id = event.id { e["id"] = id.uuidString }
        if let parentID = event.parentID { e["parent"] = parentID.uuidString }
        if let runID = event.runID { e["runID"] = runID.uuidString }
        if let addedTokens = event.addedTokens { e["addedTokens"] = addedTokens }
        if let calls = event.calls { e["calls"] = calls }
        return e
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
