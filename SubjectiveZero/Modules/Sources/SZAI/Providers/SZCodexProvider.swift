// SPDX-License-Identifier: AGPL-3.0-only
// Codex CLI provider. Subprocess wrapper around `codex exec …` (no API key). Distinct from claude
// in: `-c mcp_servers.*` config flags for the nc bridge, the prompt as a trailing positional, and a
// session id parsed from the jsonl event stream (`thread.started` → `thread_id`). A chat turn
// continues a thread with `codex exec resume <thread_id> … <prompt>` (no `--cd` on the resume
// subcommand — the process cwd carries the working directory instead).
import Foundation

public struct SZCodexProvider: SZProvider {
    public init() {}

    /// The provider's registry id — the one place the string is written (see SZClaudeProvider).
    public static let providerID = "codex"

    public let id = Self.providerID
    public let displayName = "Codex"
    /// Recorded from codex-cli 0.144.1's model manifest (`~/.codex/models_cache.json`), in its
    /// `priority` order — the order codex's own picker shows. The GPT-5.6 tier reaches `max` where
    /// 5.5/5.4 stop at `xhigh`, Luna stops at `max` while Sol and Terra reach `ultra`, and Sol alone
    /// defaults to `low`. Those are the only divergences, so only the 5.6 rows carry an override.
    /// `gpt-5.4-mini` and the hidden `codex-auto-review` stay unlisted.
    ///
    /// Every id here is live-verified (`codex exec -m <id>`), never inferred: the backend rejects a
    /// slug it won't serve with a hard 400 that no in-process test can see. `gpt-5.6-sol` is the
    /// standing example — it was announced before the rollout reached ChatGPT accounts, so for a
    /// window the CLI had no metadata for it ("Defaulting to fallback metadata") and every launch
    /// 400'd. A model joins this list when the manifest carries it AND a live launch returns clean.
    public let models = [
        SZProviderModel(id: "gpt-5.5", displayName: "GPT-5.5"),
        SZProviderModel(
            id: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
            defaultReasoningEffort: "low"),
        SZProviderModel(
            id: "gpt-5.6-terra",
            displayName: "GPT-5.6 Terra",
            supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
        SZProviderModel(
            id: "gpt-5.6-luna",
            displayName: "GPT-5.6 Luna",
            supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
        SZProviderModel(id: "gpt-5.4", displayName: "GPT-5.4"),
    ]
    public let defaultModel = "gpt-5.6-terra"
    public let defaultReasoningEffort = "medium"
    public let supportedReasoningEfforts = ["low", "medium", "high", "xhigh"]
    public let supportsFastMode = true
    public let healthArgs = ["codex", "--version"]
    public let authStatusArgs = ["codex", "login", "status"]   // "Logged in using ChatGPT"; exit 1 = logged out
    /// Recorded from codex-cli 0.141.0: logged-out runs print "Not logged in".
    public let authFailureMarkers = ["Not logged in"]
    public let installCommand = "npm install -g @openai/codex"
    public let loginCommand = "codex login"
    public let usesPreallocatedSessionID = false   // id comes back in the output stream

    public func launch(_ request: SZAgentRunRequest, preallocatedSessionID: String?) -> SZLaunch {
        var args = ["codex", "exec"]
        if request.resumeSessionID != nil { args.append("resume") }
        args += [
            "--json",
            "-m", request.model ?? defaultModel,
            "-c", "model_reasoning_effort=\"\(request.reasoningEffort ?? defaultReasoningEffort)\"",
        ]
        // Positioned with the other -c flags so it lands correctly on both exec and exec-resume.
        if request.fastMode {
            args += ["-c", #"service_tier="fast""#, "-c", "features.fast_mode=true"]
        }
        if let port = request.mcpServerPort {
            args += [
                "-c", "mcp_servers.subz.command=\"/usr/bin/nc\"",
                "-c", "mcp_servers.subz.args=[\"127.0.0.1\",\"\(port)\"]",
                "-c", "mcp_servers.subz.required=true",
            ]
        }
        // codex `exec` has no per-tool allowlist (unlike claude's --allowedTools), and currently runs
        // with a FULL approvals+sandbox bypass. A tighter setup — `--sandbox workspace-write` (no
        // bypass) — also works with MCP (the default `exec` sandbox is read-only, which blocks the
        // agent's writes; workspace-write is the right level).
        // TODO(SZ-codex-sandbox): switch to `--sandbox workspace-write` + flags-before-`resume`
        // ordering, then live-verify a ui_run coding agent still writes+compiles on codex-cli 0.141.
        args += ["--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check"]
        // `--cd` is only valid on `codex exec` (not the `resume` subcommand); a resume turn relies on
        // the process cwd (set by run() to request.workingDirectory) instead.
        if request.resumeSessionID == nil { args += ["--cd", request.workingDirectory.path] }
        if let resume = request.resumeSessionID { args.append(resume) }   // SESSION_ID positional
        args.append(request.prompt)                                       // PROMPT positional
        let env = SZAgentEnvironment.base(extra: [
            "XDG_CACHE_HOME": request.cacheDirectory.appending(path: "xdg").path,
            "SWIFT_MODULE_CACHE_PATH": request.cacheDirectory.appending(path: "swift-module-cache").path,
            "CLANG_MODULE_CACHE_PATH": request.cacheDirectory.appending(path: "clang-module-cache").path,
        ])
        return SZLaunch(executable: "/usr/bin/env", arguments: args, environment: env)
    }

    public func parse(output: String, exitCode: Int32, preallocatedSessionID: String?) -> SZAgentOutcome {
        var sessionID: String?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if event["type"] as? String == "thread.started", let id = event["thread_id"] as? String {
                sessionID = id
                break
            }
        }
        return SZAgentOutcome(sessionID: sessionID, failed: exitCode != 0)
    }

    public func makeStreamConsumer() -> any SZAgentStreamConsumer { SZCodexStreamConsumer() }
}

/// Parses codex's `--json` jsonl. codex surfaces narration as `agent_message` items and tools as
/// `mcp_tool_call` / `command_execution` items, plus optional `reasoning`. The final answer is the LAST
/// `agent_message`, so messages are held: a superseded one becomes narration (`.activity`) and the last
/// is emitted once as `.reply` at the end — matching claude's reply/trace split.
final class SZCodexStreamConsumer: SZAgentStreamConsumer {
    private var pendingReply: String?

    func consume(_ line: String) -> [SZAgentStreamEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "item.completed",
              let item = obj["item"] as? [String: Any],
              let type = item["type"] as? String else { return [] }
        let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "agent_message", "assistant_message":
            guard !text.isEmpty else { return [] }
            var events: [SZAgentStreamEvent] = []
            if let prior = pendingReply { events.append(.activity(prior)) }   // superseded → narration
            pendingReply = text
            return events
        case "reasoning":
            return text.isEmpty ? [] : [.activity(text)]
        case "mcp_tool_call":
            return [.activity("→ " + (item["tool"] as? String ?? "mcp tool"))]   // the real tool name
        case "command_execution":
            return [.activity("→ ran command")]
        default:
            return [.activity("→ " + type.replacingOccurrences(of: "_", with: " "))]
        }
    }

    func finish() -> [SZAgentStreamEvent] {
        guard let reply = pendingReply, !reply.isEmpty else { return [] }
        pendingReply = nil
        return [.reply(reply)]
    }
}
