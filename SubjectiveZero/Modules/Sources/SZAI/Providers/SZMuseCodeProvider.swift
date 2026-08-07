// SPDX-License-Identifier: AGPL-3.0-only
// Muse Code CLI provider (Meta, muse-code beta). Subprocess wrapper around `muse exec --json …`
// (no API key on the argv — muse owns auth via `muse auth set --api-key-stdin` / `muse login`,
// credentials in its own config-dir auth.json). All facts below measured against Muse Code 0.1.0
// (0.1.0-R708.1), 2026-08-07 — the CLI shipped 2026-08-05 and its portal docs are account-gated,
// so nothing here is taken from documentation. Distinct from the other providers in:
//
//  1. STAGED CONFIG HOME. muse reads MCP servers from `<config>/muse/settings.json` — there is no
//     per-invocation MCP flag, and the settings file also carries the user's own servers/defaults.
//     `prepare()` stages a throwaway config home INSIDE the scope's working directory (grok's
//     `.grok/config.toml` / pi's `.subz/` placement — the one per-agent dir the seam provides;
//     the cache dir is shared app-wide and concurrent scopes would race on it) and `launch()`
//     points `XDG_CONFIG_HOME` at it: the run gets exactly one MCP server (ours) and the user's
//     real settings stay untouched. Turns in one scope are serialized by the host (one in flight
//     per scope), so the rewrite-every-prepare self-heal never races a live reader. Credentials
//     still come from the USER's store via an `auth.json` symlink into the staged home —
//     measured: the binary ignores the launcher's `MUSE_AUTH_PATH` env var, but follows the
//     symlink (a redirected run authenticated and completed).
//
//  2. SESSIONS ARE claude-STYLE, RESUME IS NOT. The host mints `--session-id <uuid>` (honored
//     verbatim — the stream's `stream.id` is the minted uuid). A chat turn continues by passing
//     the SAME `--session-id` again: measured, the second exec appends to the retained session
//     (its first event lands at sequence 2). There is no `--resume` flag on exec; the `muse
//     resume` subcommand is the interactive TUI picker, not a headless lane.
//
//  3. EVENT-LOG STREAM. `--json` emits the session's event log as JSONL envelopes
//     ({payload_type, payload:{kind,…}}), not chat messages: `run_output_delta` text chunks,
//     `task_lifecycle` records for every tool/model task (task_kind `tool.{name}`, MCP tools on
//     the `mcp__` name prefix — claude's convention), and a final `run_terminal` carrying the
//     authoritative reply text. No reasoning text ever appears in the stream (muse's own
//     `export` help describes the stored blobs as "verbatim encrypted reasoning" — the local
//     observation is the absence; the encryption is muse's claim), and per-turn token usage
//     rides only the DURABLE log (readable offline later via `muse export`), not the live
//     stream — so muse turns carry no `.thinking` prose and no `.usage` event.
import Foundation

public struct SZMuseCodeProvider: SZProvider {
    public init() {}

    /// The provider's registry id — the one place the string is written (see SZClaudeProvider).
    public static let providerID = "muse"

    public let id = Self.providerID
    public let displayName = "Muse Code"
    /// The one served model. There is no enumeration command in 0.1.0 (`muse --help` offers only
    /// `--model <MODEL>`); the id was read back from a live run's `run.model.configured` event
    /// (`model_id: "muse-spark-1.2"`, the CLI's own startup default) and a turn on it completes
    /// clean. Press coverage names a discounted data-sharing "-contributor" variant as a model id —
    /// measured FALSE on 0.1.0: `--model muse-spark-1.2-contributor` is refused ("model
    /// `muse-spark-1.2-contributor` is not in the catalog"), so the Contributor tier is an
    /// account-level portal setting, not a CLI-selectable model, and there is nothing to list.
    public let models = [
        SZProviderModel(id: "muse-spark-1.2", displayName: "Muse Spark 1.2"),
    ]
    public let defaultModel = "muse-spark-1.2"
    /// The CLI's own default (its `--help` prints "default: high").
    public let defaultReasoningEffort = "high"
    /// Recorded from 0.1.0's own rejection of a bad value: "--reasoning-effort none is not
    /// supported with --provider meta; choose minimal|low|medium|high|xhigh|ultra" (`none` exists
    /// only for the offline echo provider). Provider-wide — one model, one menu.
    public let supportedReasoningEfforts = ["minimal", "low", "medium", "high", "xhigh", "ultra"]
    public let supportsFastMode = false   // no fast-mode concept in this CLI's argv
    public let healthArgs = ["muse", "--version"]
    /// Empty is deliberate: 0.1.0 has no token-free auth status command. `muse auth` only knows
    /// `set`; unknown subcommands fall through to the interactive TUI; and every `exec` variant
    /// either errors before the credential check ("missing prompt") or runs a paid turn. The
    /// health seam's documented fallback covers this — "Installed — auth not checked", with the
    /// probe tier as the arbiter — and the markers below still classify probe/run output.
    public let authStatusArgs: [String] = []
    /// Recorded from 0.1.0: a credential-less `muse exec` exits 1 with "missing meta credentials:
    /// run `muse login` or set META_API_KEY, …" — caught by the first marker. The second also
    /// catches the binary's rejected-key lane, whose message ("still unauthorized after a token
    /// refresh; run `muse login` again", from the shipped binary's strings) contains it.
    public let authFailureMarkers = ["missing meta credentials", "run `muse login`"]
    public let installCommand = "curl -fsSL https://dev.meta.ai/install.sh | bash"
    public let loginCommand = "muse login"
    public let usesPreallocatedSessionID = true   // we mint the UUID and pass --session-id

    /// Stage the scope's private config home (see header note 1): `muse/settings.json` names our
    /// MCP bridge (rewritten every spawn so a stale port from a previous app launch self-heals —
    /// grok's lesson), `muse/auth.json` symlinks to the user's real credential store, and the
    /// bridge script wraps `nc` because a settings `command` is a bare executable path — the
    /// schema has no args field (measured: an embedded space is treated as part of the path and
    /// fails to spawn).
    public func prepare(_ request: SZAgentRunRequest) throws {
        let home = Self.configHome(for: request)
        let museDir = home.appending(path: "muse")
        try FileManager.default.createDirectory(at: museDir, withIntermediateDirectories: true)

        let authLink = museDir.appending(path: "auth.json")
        try? FileManager.default.removeItem(at: authLink)
        try FileManager.default.createSymbolicLink(at: authLink, withDestinationURL: Self.userAuthFile())

        var settings = #"{"schema_version":1}"#
        if let port = request.mcpServerPort {
            let bridge = home.appending(path: "subz-mcp-bridge.sh")
            try Self.bridgeScript(port: port).write(to: bridge, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridge.path)
            settings = Self.settingsJSON(bridgePath: bridge.path)
        }
        try settings.write(to: museDir.appending(path: "settings.json"), atomically: true, encoding: .utf8)
    }

    public func launch(_ request: SZAgentRunRequest, preallocatedSessionID: String?) -> SZLaunch {
        var args = ["muse", "exec", "--json",
                    "--model", request.model ?? defaultModel,
                    "--reasoning-effort", request.reasoningEffort ?? defaultReasoningEffort,
                    // Headless approval bypass, codex/grok/opencode parity (an unattended turn
                    // can't answer prompts; exec's `--user-input-auto-resolve` would CANCEL tool
                    // calls, not approve them). The OS sandbox stays ON — measured, it does not
                    // block the MCP bridge's localhost dial. TODO(SZ-muse-permissions): tighten
                    // via muse's approval-mode/workspace policy once the coding flow's tools are
                    // pinned, then live-verify a ui_run coding agent still writes+compiles.
                    "--disable-approval",
                    // Hermetic runs: without this, muse imports the user's personal skills from
                    // OTHER agent CLIs into the turn (measured: "Including your 1 Codex personal
                    // skill") — an app-driven agent must not inherit them.
                    "--no-foreign-personal-context"]
        // One flag for both lanes (header note 2): a chat turn re-passes the session's id, a fresh
        // turn passes the minted one.
        if let sessionID = request.resumeSessionID ?? preallocatedSessionID {
            args += ["--session-id", sessionID]
        }
        // muse's clap parser reads a leading-`-` prompt as a flag; a leading space defeats that
        // and is invisible to the model (pi's guard, same reason — measured accepted).
        var prompt = request.prompt
        if prompt.hasPrefix("-") { prompt = " " + prompt }
        args.append(prompt)
        let env = SZAgentEnvironment.base(extra: [
            "SWIFT_MODULE_CACHE_PATH": request.cacheDirectory.appending(path: "swift-module-cache").path,
            "CLANG_MODULE_CACHE_PATH": request.cacheDirectory.appending(path: "clang-module-cache").path,
            // The staged config home (header note 1). Session retention lives under the DATA dir,
            // which is not redirected — resume across spawns keeps working (measured).
            "XDG_CONFIG_HOME": Self.configHome(for: request).path,
            // The `muse` command is a launcher script that checks for launcher+binary updates
            // hourly and swaps them in place (read in full from the shipped 0.1.0 installer,
            // which is where both this behavior and the opt-out env var come from); an
            // app-driven spawn must not race that swap mid-run.
            "MUSE_NO_AUTO_UPDATE": "1",
        ])
        return SZLaunch(executable: "/usr/bin/env", arguments: args, environment: env)
    }

    public func parse(output: String, exitCode: Int32, preallocatedSessionID: String?) -> SZAgentOutcome {
        // muse's session id is the one we minted. Success needs a zero exit AND a completed
        // terminal envelope: the measured lanes (clean turn exit 0 + terminal "completed";
        // credential/argv failures exit 1/2) never disagree, but the exit code of a turn whose
        // terminal is "failed" is unmeasured — and parse() holds the full event log, so it reads
        // the terminal instead of hoping (pi's stopReason lesson: exit codes lie). A stream with
        // no terminal at all (killed mid-turn) stays on the exit code — the runner's
        // signal/timeout classification covers that lane. No reported stats: per-turn usage and
        // durations ride the durable log (`muse export`), not the live stream.
        var failed = exitCode != 0
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  payload["kind"] as? String == "run_terminal" else { continue }
            failed = failed || (payload["terminal"] as? String != "completed")
            break
        }
        return SZAgentOutcome(sessionID: preallocatedSessionID, failed: failed)
    }

    public func makeStreamConsumer() -> any SZAgentStreamConsumer { SZMuseStreamConsumer() }

    /// The staged config home — a dot-dir inside the scope's working directory, the seam's one
    /// per-agent path (the cache dir is shared app-wide: staging there let concurrent scopes
    /// rewrite each other's settings mid-run). Same placement as grok's `.grok/` and pi's
    /// `.subz/`; a wiped scope dir heals everything.
    static func configHome(for request: SZAgentRunRequest) -> URL {
        request.workingDirectory.appending(path: ".muse-config")
    }

    /// The user's real credential store, at the same default the CLI resolves ("save credentials
    /// at …/.config/muse/auth.json" names it): `$XDG_CONFIG_HOME/muse/auth.json` when the user's
    /// environment sets it, else `~/.config/muse/auth.json`.
    static func userAuthFile() -> URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        return base.appending(path: "muse/auth.json")
    }

    /// The stdio MCP server muse spawns is `nc` bridging to the host's in-process TCP listener
    /// (claude/grok parity), wrapped in a script because `command` takes no args (see prepare()).
    static func bridgeScript(port: UInt16) -> String {
        """
        #!/bin/sh
        # Staged by SubjectiveZero before each muse run — rewritten every spawn, do not edit.
        exec /usr/bin/nc 127.0.0.1 \(port)
        """
    }

    /// Settings schema measured field-by-field off 0.1.0's own rejections (snake_case
    /// `schema_version`/`mcp_servers`, string `command`); the framing is pinned because the host's
    /// bus speaks newline-delimited JSON-RPC, not Content-Length frames, and `auto` shouldn't be
    /// left to guess. Handshake verified end-to-end: initialize → notifications/initialized →
    /// tools/list against a local listener, run exits 0 with the tool registered.
    static func settingsJSON(bridgePath: String) -> String {
        let path = bridgePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {"schema_version":1,"mcp_servers":{"subz":{"transport":"stdio",\
        "command":"\(path)","framing":"line_delimited_json"}}}
        """
    }
}

/// Parses muse's `--json` event-log JSONL (header note 3). `run_output_delta` chunks accumulate
/// into the reply candidate; a tool task (`task_lifecycle` `proposed` with task_kind `tool.{name}`)
/// flushes accumulated text as narration first (`.thinking` — matching every other provider's
/// reply/trace split) and emits one `.toolCall`; the final `run_terminal` carries the authoritative
/// reply text, preferred over the accumulated deltas (they are the same text when both exist —
/// measured — but terminal survives a dropped delta). A non-`completed` terminal surfaces as a ⚠
/// note; the run's failure itself rides the exit code. Reminder/model housekeeping tasks
/// (task_kind `reminder.*`, `model.*`) are lifecycle noise, not tool calls.
final class SZMuseStreamConsumer: SZAgentStreamConsumer {
    private var pendingReply = ""
    private var replied = false

    func consume(_ line: String) -> [SZAgentStreamEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return [] }
        switch payload["kind"] as? String {
        case "run_output_delta":
            pendingReply += payload["text"] as? String ?? ""
            return []
        case "task_lifecycle":
            guard let event = payload["event"] as? [String: Any],
                  event["kind"] as? String == "proposed",
                  let taskKind = event["task_kind"] as? String,
                  taskKind.hasPrefix("tool.") else { return [] }
            var events: [SZAgentStreamEvent] = []
            let narration = pendingReply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !narration.isEmpty {   // text before a tool call was narration, not the answer
                events.append(.thinking(narration))
                pendingReply = ""
            }
            events.append(.toolCall(name: Self.friendlyTool(String(taskKind.dropFirst("tool.".count)))))
            return events
        case "run_terminal":
            var events: [SZAgentStreamEvent] = []
            let terminal = payload["terminal"] as? String ?? ""
            if terminal != "completed" {
                let reason = (payload["reason"] as? String).map { ": \($0)" } ?? ""
                events.append(.thinking("⚠ run ended \(terminal)\(reason)"))
            }
            let text = (payload["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let reply = text.isEmpty
                ? pendingReply.trimmingCharacters(in: .whitespacesAndNewlines) : text
            pendingReply = ""
            if !reply.isEmpty {
                replied = true
                events.append(.reply(reply))
            }
            return events
        default:
            return []
        }
    }

    func finish() -> [SZAgentStreamEvent] {
        let reply = pendingReply.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingReply = ""
        guard !replied, !reply.isEmpty else { return [] }   // stream died before its terminal event
        return [.reply(reply)]
    }

    /// Trim MCP namespacing from a task's tool name (`mcp__subz__agent_compile_node` →
    /// `agent_compile_node`) so the trace shows the bare name every other provider does — the
    /// seam's `.toolCall(name:)` contract. Builtin tool names pass through unchanged.
    static func friendlyTool(_ name: String) -> String {
        name.replacingOccurrences(of: "mcp__subz__", with: "").replacingOccurrences(of: "mcp__", with: "")
    }
}
