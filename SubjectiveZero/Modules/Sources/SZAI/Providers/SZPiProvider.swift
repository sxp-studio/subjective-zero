// SPDX-License-Identifier: AGPL-3.0-only
// pi CLI provider (pi.dev, @earendil-works/pi-coding-agent). Subprocess wrapper around
// `pi -p --mode json …` (no API key — pi owns auth: ChatGPT/Claude/Copilot OAuth or user keys).
// Distinct from claude/codex/grok in three ways, all verified on pi 0.80.6 (2026-07-12):
//
//  1. DYNAMIC MODEL CATALOG. pi is a BYOK multi-provider harness — the served models depend on
//     which accounts the USER connected (`/login`), so no static manifest can know them. The
//     catalog is enumerated from the CLI itself (`--mode rpc` → `get_available_models`, which
//     also vends per-model thinking-level maps), cached by the host, and re-fetched on health
//     transitions — see `refreshModelCatalog`. Model ids are qualified `provider/id` argv tokens
//     (e.g. "openai-codex/gpt-5.5") — the most pinned form `--model` accepts.
//
//  2. MCP VIA A STAGED EXTENSION. pi deliberately ships no MCP support; its extension API is the
//     seam. `prepare()` stages a dependency-free bridge extension (Resources/Extensions/) that
//     dials the host's TCP listener and registers each MCP tool via `pi.registerTool` — raw JSON
//     Schema `parameters` verified working. Loaded with an explicit `--extension` path.
//     The user's OWN pi config (extensions/skills/context files) is deliberately NOT silenced:
//     pi users self-select for a customized harness (decided 2026-07-12). Known trade-off: a
//     user extension that opens a `ctx.ui` dialog can stall a headless turn.
//
//  3. EXIT CODES DON'T CARRY FAILURE. In `--mode json` a failed turn (bad model, backend error)
//     still exits 0 — only text mode maps errors to exit 1 (print-mode.js, verified with a bogus
//     model id: assistant `stopReason:"error"` + exit 0). `parse()` therefore reads the LAST
//     assistant message's stopReason from the event stream, not the exit code alone.
//
// Sessions are claude-style: the host mints a UUID; `--session-id` both creates AND resumes
// ("use exact project session ID, creating it if missing" — continuity live-verified: a resumed
// turn recalled the prior turn's content; the session header echoes the passed id). Sessions are
// keyed by cwd on pi's side, which matches the host's stable per-scope working directories.
//
// STDIN: `pi -p` reads piped stdin to EOF before starting (main.js readPipedStdin) — an inherited
// stdin that never closes hangs the CLI with ZERO output (reproduced 4×). SZSystemProcessRunner
// wires /dev/null stdin on every spawn, which is what un-hangs it; the RPC catalog fetch instead
// pipes its two command lines and closes.
import Foundation
import Synchronization

public struct SZPiProvider: SZProvider {
    public init() {}

    /// The provider's registry id — the one place the string is written (see SZClaudeProvider).
    public static let providerID = "pi"

    public let id = Self.providerID
    public let displayName = "Pi"

    /// Served from the last catalog snapshot (fetched or seeded) — empty until one lands, which
    /// keeps every consumer honest: the picker dims (health-gated), `setActiveModel` refuses,
    /// and `launch()` omits `--model` (defensive; pre-flights refuse a non-ready provider first).
    public var models: [SZProviderModel] { catalog.snapshot.withLock { $0?.models ?? [] } }
    public var defaultModel: String { catalog.snapshot.withLock { $0?.defaultModelID ?? "" } }

    /// pi's own default thinking level (recorded from `get_state` on 0.80.6: "medium"); per-model
    /// menus arrive as catalog overrides derived from each model's `thinkingLevelMap`, so these
    /// provider-level values are only the fallback for an unknown/stale model id.
    public let defaultReasoningEffort = "medium"
    /// pi's standard levels through `high` (docs/models.md: supported via the provider default
    /// mapping unless a map nulls them). `off` is deliberately not offered — no subz provider
    /// models a "no thinking" menu token. `xhigh`/`max` are per-model (catalog overrides).
    public let supportedReasoningEfforts = ["minimal", "low", "medium", "high"]
    public let supportsFastMode = false   // no fast-mode concept in this CLI's argv
    public let healthArgs = ["pi", "--version"]
    /// `pi --list-models` exits 0 in BOTH auth states (verified 0.80.6) — logged out it prints
    /// "No models available. Use /login…", so the auth tier's marker path classifies, grok-style.
    /// `--offline` skips pi's startup network operations (update checks), keeping the check
    /// deterministic inside the tier's 10s timeout; it does not hide OAuth-served models
    /// (verified: same 7-model table with and without).
    public let authStatusArgs = ["pi", "--list-models", "--offline"]
    /// Recorded from pi 0.80.6. The first two are the logged-out `--list-models` output; the
    /// third is a logged-out one-shot run's error ("No API key found for the selected model.").
    public let authFailureMarkers = [
        "No models available",
        "Use /login",
        "No API key found",
    ]
    /// npm over the curl installer: matches how the CLI resolves on the synthesized PATH (nvm
    /// bin dirs are already searched). `--ignore-scripts` is the vendor's own documented form.
    public let installCommand = "npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
    /// pi has no non-interactive login: auth is `/login` INSIDE the TUI (OAuth or API key). The
    /// Terminal launcher opens the TUI; docs/APP_SETUP.md tells the user to type `/login` there.
    public let loginCommand = "pi"
    public let usesPreallocatedSessionID = true   // we mint the UUID and pass --session-id

    /// Last catalog snapshot. A reference cell (Mutex is noncopyable, so it rides in a class) —
    /// every copy of this value-type provider serves one truth, while each `SZPiProvider()`
    /// gets its own cell, keeping tests isolated.
    private let catalog = CatalogCell()

    private final class CatalogCell: Sendable {
        let snapshot = Mutex<SZProviderModelCatalog?>(nil)
    }

    // MARK: - Dynamic catalog

    public func seedModelCatalog(_ snapshot: SZProviderModelCatalog) {
        catalog.snapshot.withLock { $0 = snapshot }
    }

    /// One `pi --mode rpc` round trip (token-free): `get_state` for the CLI's own default model,
    /// `get_available_models` for the catalog. The two command lines ride stdin and the process
    /// exits on stdin EOF (verified). Logged out this cleanly returns zero models (`{"models":[]}`
    /// with a sentinel "unknown" default — ignored), which the host stores as-is: an empty catalog
    /// alongside `authNeeded` is the truthful state.
    public func refreshModelCatalog(runner: any SZProcessRunning) async throws -> SZProviderModelCatalog? {
        let commands = Data("""
        {"id":"1","type":"get_state"}
        {"id":"2","type":"get_available_models"}

        """.utf8)
        let result = try await runner.run(
            "/usr/bin/env", ["pi", "--mode", "rpc", "--no-session", "--offline"],
            environment: SZAgentEnvironment.base(), currentDirectoryURL: nil,
            input: commands, timeout: 20, onOutput: nil)
        guard result.exitCode == 0, !result.timedOut else {
            throw SZPiCatalogError.fetchFailed(exitCode: result.exitCode, timedOut: result.timedOut)
        }
        guard let snapshot = Self.catalogSnapshot(fromRPCOutput: result.output) else {
            throw SZPiCatalogError.unparseableResponse
        }
        catalog.snapshot.withLock { $0 = snapshot }
        return snapshot
    }

    /// Map the two RPC response lines into a snapshot. Internal for the recorded-fixture tests.
    static func catalogSnapshot(fromRPCOutput output: String) -> SZProviderModelCatalog? {
        var rpcModels: [[String: Any]]?
        var stateModel: [String: Any]?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "response",
                  let payload = obj["data"] as? [String: Any] else { continue }
            switch obj["command"] as? String {
            case "get_available_models": rpcModels = payload["models"] as? [[String: Any]]
            case "get_state": stateModel = payload["model"] as? [String: Any]
            default: break
            }
        }
        guard let rpcModels else { return nil }

        let names = rpcModels.compactMap { $0["name"] as? String }
        let duplicated = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
        let models = rpcModels.compactMap { Self.model(fromRPC: $0, duplicatedNames: duplicated) }

        // The CLI's own default (the user's ~/.pi settings, verified) — qualified like every
        // catalog id. Logged out it's a sentinel ("unknown"/"unknown") that never matches.
        var defaultID: String?
        if let stateModel,
           let provider = stateModel["provider"] as? String, let bare = stateModel["id"] as? String {
            let qualified = "\(provider)/\(bare)"
            defaultID = models.contains { $0.id == qualified } ? qualified : nil
        }
        return SZProviderModelCatalog(models: models, defaultModelID: defaultID ?? models.first?.id)
    }

    private static func model(fromRPC obj: [String: Any], duplicatedNames: Set<String>) -> SZProviderModel? {
        guard let bare = obj["id"] as? String, let provider = obj["provider"] as? String,
              !bare.isEmpty, provider != "unknown" else { return nil }
        let name = obj["name"] as? String ?? bare
        let efforts = thinkingLevels(
            reasoning: obj["reasoning"] as? Bool ?? false,
            map: obj["thinkingLevelMap"] as? [String: Any] ?? [:])
        return SZProviderModel(
            id: "\(provider)/\(bare)",
            displayName: duplicatedNames.contains(name) ? "\(name) (\(provider))" : name,
            supportedReasoningEfforts: efforts,
            defaultReasoningEffort: efforts.isEmpty ? nil
                : (efforts.contains("medium") ? "medium" : efforts.first))
    }

    /// pi's documented `thinkingLevelMap` tristate (docs/models.md, 0.80.6): standard levels
    /// through `high` are supported unless the map nulls them; extended `xhigh`/`max` only when
    /// present as a string. `off` is excluded from menus (see supportedReasoningEfforts).
    static func thinkingLevels(reasoning: Bool, map: [String: Any]) -> [String] {
        guard reasoning else { return [] }
        func supported(_ level: String, standard: Bool) -> Bool {
            switch map[level] {
            case nil: return standard          // omitted: default mapping covers standard levels
            case is NSNull: return false       // null: explicitly unsupported
            default: return true               // string: supported, value is the provider token
            }
        }
        var levels = ["minimal", "low", "medium", "high"].filter { supported($0, standard: true) }
        levels += ["xhigh", "max"].filter { supported($0, standard: false) }
        return levels
    }

    // MARK: - Spawn

    /// Stage the MCP bridge extension for a turn that carries a port; remove it otherwise (grok's
    /// staged-file pattern — rewritten every spawn so a stale port from a previous app launch
    /// self-heals). The bridge is the only extension subz adds; the user's own pi setup loads
    /// untouched alongside it (see the header).
    public func prepare(_ request: SZAgentRunRequest) throws {
        let bridgeFile = Self.bridgePath(in: request.workingDirectory)
        guard let port = request.mcpServerPort else {
            try? FileManager.default.removeItem(at: bridgeFile)
            return
        }
        try FileManager.default.createDirectory(
            at: bridgeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.bridgeSource(port: port).write(to: bridgeFile, atomically: true, encoding: .utf8)
    }

    public func launch(_ request: SZAgentRunRequest, preallocatedSessionID: String?) -> SZLaunch {
        // --offline skips pi's startup network operations only — an authenticated model call
        // succeeds under it (verified), and a logged-out one fails FAST with a marker instead of
        // hanging on OAuth (a logged-out run without it was observed hanging with zero output).
        var args = ["pi", "-p", "--mode", "json", "--offline"]
        let model = request.model ?? defaultModel
        if !model.isEmpty { args += ["--model", model] }
        if let effort = request.reasoningEffort, !effort.isEmpty {
            args += ["--thinking", effort]
        }
        // One flag creates and resumes; run() passes preallocated only on a fresh turn.
        if let sessionID = request.resumeSessionID ?? preallocatedSessionID {
            args += ["--session-id", sessionID]
        }
        if request.mcpServerPort != nil {
            args += ["--extension", Self.bridgePath(in: request.workingDirectory).path]
        }
        args.append(request.prompt)   // trailing positional — `-p` is a bare flag, unlike claude's
        let env = SZAgentEnvironment.base(extra: [
            "SWIFT_MODULE_CACHE_PATH": request.cacheDirectory.appending(path: "swift-module-cache").path,
            "CLANG_MODULE_CACHE_PATH": request.cacheDirectory.appending(path: "clang-module-cache").path,
        ])
        return SZLaunch(executable: "/usr/bin/env", arguments: args, environment: env)
    }

    public func parse(output: String, exitCode: Int32, preallocatedSessionID: String?) -> SZAgentOutcome {
        // Failure detection reads the stream, not just the exit code (header comment #3): the
        // LAST assistant message's stopReason is the turn's verdict — intermediate ones read
        // "toolUse". No assistant message at all is a failure too (the CLI died pre-reply).
        var lastStopReason: String?
        var headerSessionID: String?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }   // stderr warnings interleave in the merged stream — skip
            switch obj["type"] as? String {
            case "session":
                headerSessionID = headerSessionID ?? obj["id"] as? String
            case "message_end":
                if let message = obj["message"] as? [String: Any],
                   message["role"] as? String == "assistant" {
                    lastStopReason = message["stopReason"] as? String
                }
            default:
                break
            }
        }
        let failed = exitCode != 0 || lastStopReason == nil
            || lastStopReason == "error" || lastStopReason == "aborted"
        // The header echoes the passed --session-id (verified); parsing it is the belt-and-braces
        // for a resume turn, where run() passes no preallocated id.
        return SZAgentOutcome(sessionID: preallocatedSessionID ?? headerSessionID, failed: failed)
    }

    public func makeStreamConsumer() -> any SZAgentStreamConsumer { SZPiStreamConsumer() }

    static func bridgePath(in workingDirectory: URL) -> URL {
        workingDirectory.appending(path: ".subz/mcp-bridge.mjs")
    }

    /// The staged extension: the bundled bridge with the turn's port templated in. Missing
    /// resource throws → `prepare()` aborts the turn loudly rather than running toolless.
    static func bridgeSource(port: UInt16) throws -> String {
        guard let url = Bundle.module.url(
                forResource: "subz-mcp-bridge", withExtension: "js", subdirectory: "Extensions"),
              let template = try? String(contentsOf: url, encoding: .utf8) else {
            throw SZPiCatalogError.bridgeResourceMissing
        }
        return template.replacingOccurrences(of: "__SUBZ_MCP_PORT__", with: String(port))
    }
}

enum SZPiCatalogError: Error, CustomStringConvertible {
    case fetchFailed(exitCode: Int32, timedOut: Bool)
    case unparseableResponse
    case bridgeResourceMissing

    var description: String {
        switch self {
        case .fetchFailed(let exitCode, let timedOut):
            "pi model catalog fetch failed (\(timedOut ? "timed out" : "exit \(exitCode)"))"
        case .unparseableResponse:
            "pi model catalog fetch returned no parseable get_available_models response"
        case .bridgeResourceMissing:
            "bundled subz-mcp-bridge.js resource is missing"
        }
    }
}

/// Parses pi's `--mode json` JSONL. Classification happens on complete messages (`message_end`),
/// not the token-level `message_update` deltas — deltas would spam the trace (grok's lesson).
/// An assistant message's `text` block is held as the candidate reply; a later assistant message
/// supersedes it (the earlier text was narration — claude/codex/grok's reply/trace split), and
/// `finish()` emits the survivor once. `thinking` blocks carry REAL reasoning text (pi talks to the
/// model APIs directly — no CLI-side redaction) → `.thinking`; `tool_execution_start` → `.toolCall`.
/// No usage events have been observed in pi's stream, so pi turns carry no `.usage`.
/// Lines are strict JSON (pi JSON.stringify's its events — verified, zero raw control
/// characters), but stderr warnings interleave in the merged stream, so unparseable lines skip.
final class SZPiStreamConsumer: SZAgentStreamConsumer {
    private var pendingReply: String?

    func consume(_ line: String) -> [SZAgentStreamEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return [] }
        switch type {
        case "message_end":
            guard let message = obj["message"] as? [String: Any],
                  message["role"] as? String == "assistant" else { return [] }
            var events: [SZAgentStreamEvent] = []
            if let error = (message["errorMessage"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                events.append(.thinking("⚠ " + error))
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    let text = (block["text"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if let prior = pendingReply { events.append(.thinking(prior)) }  // superseded → narration
                    pendingReply = text
                case "thinking":
                    let thought = (block["thinking"] as? String ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !thought.isEmpty { events.append(.thinking(thought)) }
                default:
                    break   // toolCall blocks: tool_execution_start below carries the name
                }
            }
            return events
        case "tool_execution_start":
            return [.toolCall(name: obj["toolName"] as? String ?? "tool")]
        case "auto_retry_start":
            let reason = (obj["errorMessage"] as? String ?? "transient error")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return [.thinking("⚠ retrying: " + reason)]
        default:
            return []   // session header, lifecycle brackets, deltas, tool results
        }
    }

    func finish() -> [SZAgentStreamEvent] {
        guard let reply = pendingReply, !reply.isEmpty else { return [] }
        pendingReply = nil
        return [.reply(reply)]
    }
}
