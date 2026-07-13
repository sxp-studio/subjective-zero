// SPDX-License-Identifier: AGPL-3.0-only
// Claude Code CLI provider. Subprocess wrapper around `claude -p …` (no API key). Distinct from
// codex in: --mcp-config JSON for the nc bridge, and a host-minted --session-id UUID. A chat turn
// continues an existing session with `--resume <id>` (the same id we minted) instead of `--session-id`.
import Foundation
import SZCore

public struct SZClaudeProvider: SZProvider {
    public init() {}

    /// The provider's registry id — the one place the string is written (the registry's default and
    /// anything else naming this provider reference it instead of a literal).
    public static let providerID = "claude"

    public let id = Self.providerID
    public let displayName = "Claude Code"
    /// Pinned version ids, not the CLI's floating aliases — "Opus 4.8" in the menu must mean
    /// Opus 4.8 (a version-labeled alias would lie the day the alias re-points). `claude --help`
    /// names exactly that hazard: `--model` takes "an alias for the LATEST model (e.g. 'fable',
    /// 'opus', or 'sonnet') or a model's full name". We pass the full name. New models arrive with
    /// app updates (Sparkle).
    ///
    /// Listed in the order that same help text prints its aliases — fable, opus, sonnet — which is
    /// the CLI's own frontier-first ordering. Every id is live-verified against claude 2.1.206
    /// (`claude -p --model <id>`), never inferred: an id the backend won't serve fails the run, not
    /// the build, so no in-process test can catch it. All three share the provider's effort list and
    /// its `high` default, so none overrides effort.
    ///
    /// Fast mode is the one place they diverge: the CLI will only ENABLE it for Opus 4.8. It accepts
    /// `--settings {"fastMode":true}` for all three — it swallows any settings key without so much as
    /// a warning, so acceptance proves nothing — but its own `result.fast_mode_state` reads `on` for
    /// Opus 4.8 and `off` for Fable 5 and Sonnet 5. That gate is what the toggle mirrors, so the two
    /// the CLI won't enable it for declare it and the picker stops offering an inert switch.
    ///
    /// Whether an enabled turn is then actually SERVED fast is a separate, per-account question, and
    /// nothing here can answer it: the result event reports it per turn as `usage.speed`. Read that
    /// only together with `fast_mode_state` — on its own it reads `standard` on every turn, fast mode
    /// requested or not. It reads `standard` on this org, whose fast-mode spend is disabled, so
    /// requested, enabled, and served are three different things and the stream consumer says which.
    ///
    /// Opus 4.8 is the default, not Fable 5. Fable is the frontier model and prices like one; Opus
    /// 4.8 is the balanced everyday one, and a Director run wants the latter. Same call codex makes
    /// with Sol and Terra.
    public let models = [
        SZProviderModel(id: "claude-fable-5", displayName: "Fable 5", supportsFastMode: false),
        SZProviderModel(id: "claude-opus-4-8", displayName: "Opus 4.8"),   // inherits the provider's true
        SZProviderModel(id: "claude-sonnet-5", displayName: "Sonnet 5", supportsFastMode: false),
    ]
    public let defaultModel = "claude-opus-4-8"
    /// `--effort` levels, recorded from claude 2.1.206's own complaint on an unknown value ("Valid
    /// values: low, medium, high, xhigh, max"), and re-confirmed against Fable 5: the list is
    /// provider-wide, not per-model. Note the CLI only WARNS and falls back to its own default —
    /// it does not exit — so an effort token that drifts off this list degrades silently. That is
    /// what `resolvedGenerationSettings` clamping is for.
    public let defaultReasoningEffort = "high"
    public let supportedReasoningEfforts = ["low", "medium", "high", "xhigh", "max"]
    public let supportsFastMode = true   // the CLI HAS the flag; per-model reality is on the models
    public let healthArgs = ["claude", "--version"]
    public let authStatusArgs = ["claude", "auth", "status"]   // JSON {"loggedIn": …}; exit 1 = logged out
    /// Recorded from claude 2.1.200: a logged-out `claude -p` exits 1 with "Not logged in ·
    /// Please run /login"; API-key rejection says "Invalid API key".
    public let authFailureMarkers = ["Not logged in", "Please run /login", "Invalid API key"]
    public let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    public let loginCommand = "claude auth login"
    public let usesPreallocatedSessionID = true   // we mint the UUID and pass --session-id

    /// MCP tools an agent may call (plus its native file tools). These must be pre-approved here — in
    /// non-interactive `-p` mode a tool not on this list is denied (it can't prompt). One shared superset
    /// for both roles: a Coding Agent only ever calls the `agent_*` set (its prompt scopes it there), and
    /// the Director Agent shapes the graph through `ui_*` and, during a reconcile turn, directs a
    /// node's Coding Agent via `ui_send_chat` (recorded, not a recursive run).
    ///
    /// `ui_run` IS allowed. A chat turn is how a user asks for a build ("...then build it"), and
    /// director/chat.md tells the Director to call it — but an unlisted tool is denied outright in
    /// non-interactive `-p` mode, so the Director could only stop and ask the user to grant it. Recursion
    /// needs no help from the allowlist: `uiRun` refuses while `isRunning`, and a call from the Director's
    /// own streaming turn is queued to fire at turn end.
    private static let allowedTools = [
        "Read", "Write", "Edit",
        // Coding Agent — implement one node.
        "mcp__subz__agent_read_graph", "mcp__subz__agent_read_node",
        "mcp__subz__agent_library_index",
        "mcp__subz__agent_library_card", "mcp__subz__agent_library_source",
        "mcp__subz__agent_write_node_staged", "mcp__subz__agent_compile_node", "mcp__subz__agent_report_status",
        "mcp__subz__agent_docs_index", "mcp__subz__agent_docs_read",   // fetch the canonical schema/ABI instead of guessing
        // Director Agent — establish contracts + wiring + direct coding agents on reconcile.
        "mcp__subz__ui_add_prompt_node", "mcp__subz__ui_add_source_node",
        "mcp__subz__ui_update_node", "mcp__subz__ui_edit_ports", "mcp__subz__ui_connect",
        "mcp__subz__ui_disconnect", "mcp__subz__ui_move_node", "mcp__subz__ui_remove_node",
        "mcp__subz__ui_split_node", "mcp__subz__ui_merge_nodes", "mcp__subz__ui_toggle_display",
        "mcp__subz__ui_send_chat", "mcp__subz__ui_run",
        // No `debug_*`: the agent bus doesn't serve them (SZHostBridge.Surface). The Director reads the
        // graph with `agent_read_graph` — reaching for `debug_snapshot_state` made a run behave unlike
        // the one a user gets, and cost it a tool-search round trip before its first move.
    ].joined(separator: ",")

    public func launch(_ request: SZAgentRunRequest, preallocatedSessionID: String?) -> SZLaunch {
        var args = ["claude", "-p", request.prompt,
                    "--model", request.model ?? defaultModel,
                    "--effort", request.reasoningEffort ?? defaultReasoningEffort]
        if let port = request.mcpServerPort {
            args += ["--mcp-config", Self.mcpConfig(port: port), "--strict-mcp-config"]
        }
        args += ["--setting-sources", ""]
        // Fast mode rides an inline --settings blob (composes with the empty
        // --setting-sources above, which only silences FILE sources).
        if request.fastMode { args += ["--settings", #"{"fastMode":true}"#] }
        args += [
            "--add-dir", request.packageDirectory.path,
            "--allowedTools", Self.allowedTools,
            "--permission-mode", "acceptEdits",
            "--output-format", "stream-json", "--verbose",
        ]
        if let resume = request.resumeSessionID {
            args += ["--resume", resume]   // continue the existing conversation (chat turn)
        } else if let sessionID = preallocatedSessionID {
            args += ["--session-id", sessionID]
        }
        let env = SZAgentEnvironment.base(extra: [
            "SWIFT_MODULE_CACHE_PATH": request.cacheDirectory.appending(path: "swift-module-cache").path,
            "CLANG_MODULE_CACHE_PATH": request.cacheDirectory.appending(path: "clang-module-cache").path,
        ])
        return SZLaunch(executable: "/usr/bin/env", arguments: args, environment: env)
    }

    public func parse(output: String, exitCode: Int32, preallocatedSessionID: String?) -> SZAgentOutcome {
        // claude's session id is the one we minted; success rides the exit code.
        SZAgentOutcome(sessionID: preallocatedSessionID, failed: exitCode != 0)
    }

    public func makeStreamConsumer() -> any SZAgentStreamConsumer { SZClaudeStreamConsumer() }

    /// The stdio MCP server claude spawns is `nc` bridging to the host's in-process TCP listener.
    static func mcpConfig(port: UInt16) -> String {
        #"{"mcpServers":{"subz":{"command":"/usr/bin/nc","args":["127.0.0.1","\#(port)"]}}}"#
    }
}

/// Parses claude's stream-json. `assistant` events carry the agent's narration (`text` blocks →
/// `.thinking` once superseded) and the tools it calls (`tool_use` → `.toolCall`). The final answer is
/// held back (the last text block / the `result` event) and emitted once as `.reply` at the end, so it
/// never echoes into the trace.
///
/// `thinking` content blocks arrive with EMPTY text in headless mode — verified 2.1.207 on Fable 5
/// AND Opus 4.8, in the aggregate `assistant` event and equally in `--include-partial-messages`
/// `thinking_delta` stream events (only the signature ships). So claude's `.thinking` is narration
/// only; a non-empty `thinking` block would be surfaced below, but none has been observed.
final class SZClaudeStreamConsumer: SZAgentStreamConsumer {
    private var pendingReply: String?   // latest assistant text — the reply candidate, flushed at the end

    func consume(_ line: String) -> [SZAgentStreamEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        switch obj["type"] as? String {
        case "assistant":
            guard let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
            var events: [SZAgentStreamEvent] = []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    let t = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { break }
                    if let prior = pendingReply { events.append(.thinking(prior)) }   // superseded → narration
                    pendingReply = t
                case "tool_use":
                    if let prior = pendingReply { events.append(.thinking(prior)); pendingReply = nil }
                    events.append(.toolCall(name: Self.friendlyTool(block["name"] as? String ?? "tool")))
                case "thinking":
                    // Empty in every recorded headless stream (see header) — surfaced anyway for the
                    // day the CLI ships the text. Must not clobber the held reply candidate.
                    let t = (block["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { events.append(.thinking(t)) }
                default: break
                }
            }
            return events
        case "result":
            var events: [SZAgentStreamEvent] = []
            // Enabled and served are different things, and the CLI reports both on this event:
            // `fast_mode_state` is whether it turned fast mode ON, `usage.speed` is what the API
            // actually SERVED. A turn can be downgraded by the account's entitlement or by fast
            // mode's own rate limit, and without this line the bolt would keep claiming fast on a
            // turn that never was. Both halves are load-bearing: `usage.speed` alone reads
            // "standard" on EVERY turn, fast mode requested or not.
            if obj["fast_mode_state"] as? String == "on",
               let speed = (obj["usage"] as? [String: Any])?["speed"] as? String, speed != "fast" {
                events.append(.thinking("fast mode requested — served \(speed)"))
            }
            // The turn's usage rides the result event (recorded from 2.1.207). Anthropic reports the
            // cache traffic SEPARATELY from input_tokens, so the total prompt side is their sum and
            // the cached share is read + creation (the pricing distinction between the two is
            // already carried by total_cost_usd).
            if let usage = obj["usage"] as? [String: Any],
               let output = usage["output_tokens"] as? Int {
                let cached = (usage["cache_read_input_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                events.append(.usage(SZTokenUsage(
                    inputTokens: (usage["input_tokens"] as? Int ?? 0) + cached, outputTokens: output,
                    cachedInputTokens: cached > 0 ? cached : nil,
                    costUSD: obj["total_cost_usd"] as? Double
                )))
            }
            let r = (obj["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let reply = r.isEmpty ? (pendingReply ?? "") : r
            pendingReply = nil
            if !reply.isEmpty { events.append(.reply(reply)) }
            return events
        default:
            return []
        }
    }

    func finish() -> [SZAgentStreamEvent] {
        guard let reply = pendingReply, !reply.isEmpty else { return [] }   // stream ended w/o a result
        pendingReply = nil
        return [.reply(reply)]
    }

    /// Trim MCP namespacing from a tool name (`mcp__subz__agent_compile_node` → `agent_compile_node`);
    /// native tools (Read/Write/Edit) pass through unchanged.
    static func friendlyTool(_ name: String) -> String {
        name.replacingOccurrences(of: "mcp__subz__", with: "").replacingOccurrences(of: "mcp__", with: "")
    }
}
