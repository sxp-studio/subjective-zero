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
    /// Full version ids, never the CLI's floating aliases (`opus`, `sonnet`), which re-point on a
    /// release. Ordered fable, opus, sonnet, haiku, newest first. Every id is live-verified with
    /// `claude -p --model <id>` (last on 2.1.282, 2026-09-25): a wrong id fails the run, not the build.
    ///
    /// Fast mode follows the CLI's `result.fast_mode_state`, which reads `on` only for the three
    /// newest Opus models. Every other model declares false; on Opus 4.7 the API rejects a fast turn.
    ///
    /// The newest Opus is the default: Fable is the frontier tier and prices like one.
    public let models = [
        SZProviderModel(id: "claude-fable-5-1", displayName: "Fable 5.1", supportsFastMode: false),
        SZProviderModel(id: "claude-fable-5", displayName: "Fable 5", supportsFastMode: false),
        SZProviderModel(id: "claude-opus-5-5", displayName: "Opus 5.5"),   // inherits the provider's true
        SZProviderModel(id: "claude-opus-5", displayName: "Opus 5"),       // ditto
        SZProviderModel(id: "claude-opus-4-8", displayName: "Opus 4.8"),   // ditto
        SZProviderModel(id: "claude-opus-4-7", displayName: "Opus 4.7", supportsFastMode: false),
        SZProviderModel(id: "claude-sonnet-5", displayName: "Sonnet 5", supportsFastMode: false),
        SZProviderModel(id: "claude-sonnet-4-6", displayName: "Sonnet 4.6", supportsFastMode: false),
        SZProviderModel(id: "claude-haiku-4-5", displayName: "Haiku 4.5", supportsFastMode: false),
    ]
    public let defaultModel = "claude-opus-5-5"
    /// Provider-wide: every model completes a turn at `max`. The CLI only warns on an unknown value,
    /// so `resolvedGenerationSettings` clamps to this list.
    public let defaultReasoningEffort = "high"
    public let supportedReasoningEfforts = ["low", "medium", "high", "xhigh", "max"]
    public let supportsFastMode = true   // the CLI has the flag; per-model reality is on the models
    public let healthArgs = ["claude", "--version"]
    public let authStatusArgs = ["claude", "auth", "status"]   // JSON {"loggedIn": …}; exit 1 = logged out
    /// Recorded from claude 2.1.200: a logged-out `claude -p` exits 1 with "Not logged in ·
    /// Please run /login"; API-key rejection says "Invalid API key".
    public let authFailureMarkers = ["Not logged in", "Please run /login", "Invalid API key"]
    public let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"
    public let loginCommand = "claude auth login"
    public let usesPreallocatedSessionID = true   // we mint the UUID and pass --session-id

    /// The `--allowedTools` value. Claude is the only provider that gates per-tool: in non-interactive
    /// `-p` mode a tool off this list is denied and the model can't prompt, so it silently reports it
    /// can't. The MCP set is therefore not owned here — it mirrors the app's single source of truth
    /// (`SZHostBridge.agentCallableToolNames`, the tools the `.agent` bus actually serves), plumbed in
    /// via `request.allowedMCPTools`. So a new MCP tool is reachable by construction and there is no
    /// second list to drift (that gap is exactly what once hid `agent_view_frame` from the agent).
    /// The native file tools (`Read/Write/Edit`) stay here — they are claude's own, not MCP surface.
    /// Empty `mcpTools` (no MCP attached, e.g. the health probe) → native tools only.
    private static func allowedTools(_ mcpTools: [String]) -> String {
        (["Read", "Write", "Edit"] + mcpTools.map { "mcp__subz__\($0)" }).joined(separator: ",")
    }

    public func launch(_ request: SZAgentRunRequest, preallocatedSessionID: String?) -> SZLaunch {
        var args = ["claude", "-p", request.prompt,
                    "--model", request.model ?? defaultModel,
                    "--effort", request.reasoningEffort ?? defaultReasoningEffort]
        if let port = request.mcpServerPort {
            args += ["--mcp-config", Self.mcpConfig(port: port), "--strict-mcp-config"]
        }
        args += ["--setting-sources", ""]
        // Fast mode rides an inline --settings blob (composes with the empty
        // --setting-sources above, which only silences file sources).
        if request.fastMode { args += ["--settings", #"{"fastMode":true}"#] }
        args += [
            "--add-dir", request.packageDirectory.path,
            "--allowedTools", Self.allowedTools(request.allowedMCPTools),
            "--permission-mode", "acceptEdits",
            "--output-format", "stream-json", "--verbose",
            // Liveness for the silence budget: without partials the CLI emits nothing while an
            // assistant message generates, and a node's source is generated as tool_use arguments —
            // so a big node is one silent window long enough to look wedged. The aggregate
            // `assistant`/`result` events still arrive; `stream_event` is ignored by the consumer.
            "--include-partial-messages",
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
        var outcome = SZAgentOutcome(sessionID: preallocatedSessionID, failed: exitCode != 0)
        // The CLI's own account of the turn rides the final `result` event: `duration_ms` (wall),
        // `duration_api_ms` (API share), `num_turns` (live-verified 2.1.207; the event also carries
        // ttft_ms, unused — the host measures first output itself, provider-neutrally). Scanned from
        // the end: `result` is the stream's last event.
        for line in output.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "result" else { continue }
            let stats = SZAgentReportedStats(
                duration: (obj["duration_ms"] as? Int).map { Double($0) / 1000 },
                apiDuration: (obj["duration_api_ms"] as? Int).map { Double($0) / 1000 },
                turnCount: obj["num_turns"] as? Int)
            if stats != SZAgentReportedStats() { outcome.reportedStats = stats }
            break
        }
        return outcome
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
/// `thinking` content blocks arrive with empty text in headless mode — verified 2.1.207 on Fable 5
/// and Opus 4.8, in the aggregate `assistant` event and equally in `--include-partial-messages`
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
            // `fast_mode_state` is whether it turned fast mode on, `usage.speed` is what the API
            // actually served. A turn can be downgraded by the account's entitlement or by fast
            // mode's own rate limit, and without this line the bolt would keep claiming fast on a
            // turn that never was. Both halves are load-bearing: `usage.speed` alone reads
            // "standard" on every turn, fast mode requested or not.
            if obj["fast_mode_state"] as? String == "on",
               let speed = (obj["usage"] as? [String: Any])?["speed"] as? String, speed != "fast" {
                events.append(.thinking("fast mode requested — served \(speed)"))
            }
            // The turn's usage rides the result event (recorded from 2.1.207). Anthropic reports the
            // cache traffic separately from input_tokens, so the total prompt side is their sum and
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
