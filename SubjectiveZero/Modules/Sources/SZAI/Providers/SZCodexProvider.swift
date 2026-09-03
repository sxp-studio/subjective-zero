// SPDX-License-Identifier: AGPL-3.0-only
// Codex CLI provider. Subprocess wrapper around `codex exec …` (no API key). Distinct from claude
// in: `-c mcp_servers.*` config flags for the nc bridge, the prompt as a trailing positional, and a
// session id parsed from the jsonl event stream (`thread.started` → `thread_id`). A chat turn
// continues a thread with `codex exec resume <thread_id> … <prompt>` (no `--cd` on the resume
// subcommand — the process cwd carries the working directory instead).
import Foundation
import SZCore
import Synchronization

public struct SZCodexProvider: SZProvider {
    public init() {}

    /// The provider's registry id — the one place the string is written (see SZClaudeProvider).
    public static let providerID = "codex"

    public let id = Self.providerID
    public let displayName = "Codex"
    /// Served from the catalog cell: the built-in snapshot until a persisted or fetched one
    /// replaces it, so the picker is never empty. codex's catalog is backend-global (not
    /// account-shaped like grok/pi/opencode's), so a snapshot recorded from the installed CLI is
    /// an honest start; `refreshModelCatalog` keeps it current.
    public var models: [SZProviderModel] { catalog.snapshot.withLock { $0.models } }
    public var defaultModel: String { catalog.snapshot.withLock { $0.defaultModelID ?? "" } }
    /// Stale-id fallback: a stored row or resumed thread on a model the catalog dropped still gets
    /// a menu and a default. Listed models carry the manifest's own values.
    public let defaultReasoningEffort = "medium"
    public let supportedReasoningEfforts = ["low", "medium", "high", "xhigh"]
    /// The CLI has the flag; per-model reality is each model's `supportsFastMode`, mapped from
    /// the manifest's `additional_speed_tiers`.
    public let supportsFastMode = true

    /// Last snapshot, in a reference cell (Mutex is noncopyable): every copy of this value type
    /// serves one truth, and each `SZCodexProvider()` gets its own, seeded with the built-in list.
    private let catalog = CatalogCell()

    private final class CatalogCell: Sendable {
        let snapshot = Mutex<SZProviderModelCatalog>(SZCodexProvider.builtInCatalog)
    }

    // MARK: - Dynamic catalog

    /// codex-cli 0.144.5's manifest (refreshed 2026-09-03), mapped by hand; the drift test re-maps
    /// a recorded copy and asserts equality. Visible rows in the vendor's priority order; rows the
    /// manifest marks `upgrade` (gpt-5.4 and gpt-5.4-mini, pointed at Terra and Luna) stay listed
    /// with a "(retiring)" label — a stored pick keeps its model and its thread until the vendor
    /// hides the row, and both still completed a turn on 2026-09-03.
    ///
    /// Every id is live-verified (`codex exec -m <id>`), never inferred: a slug the backend won't
    /// serve 400s at run time, invisible to tests. The manifest is the first gate — Sol's 400
    /// window was a slug the CLI had no metadata for, so it was absent. The second is the setup
    /// sheet's Test probe and the run's own failure path; composer, routing, and MCP picks are not
    /// probed. No per-model probing on refresh.
    static let builtInCatalog = SZProviderModelCatalog(
        models: [
            SZProviderModel(
                id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol",
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
                defaultReasoningEffort: "low"),
            SZProviderModel(
                id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra",
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"],
                defaultReasoningEffort: "medium"),
            SZProviderModel(
                id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna",
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max"],
                defaultReasoningEffort: "medium"),
            SZProviderModel(
                id: "gpt-5.5", displayName: "GPT-5.5",
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
                defaultReasoningEffort: "medium"),
            SZProviderModel(
                id: "gpt-5.4", displayName: "GPT-5.4 (retiring)",
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
                defaultReasoningEffort: "medium"),
            SZProviderModel(
                id: "gpt-5.4-mini", displayName: "GPT-5.4 Mini (retiring)",
                supportedReasoningEfforts: ["low", "medium", "high", "xhigh"],
                defaultReasoningEffort: "medium",
                supportsFastMode: false),   // the one row with no `fast` tier
        ],
        defaultModelID: "gpt-5.6-terra")

    /// Terra: codex's everyday pick and the shipped starter's builder-default; Sol prices like the
    /// frontier tier (the Opus-over-Fable call). `catalogSnapshot` follows Terra's `upgrade`
    /// pointer the day the vendor retires it.
    static let preferredDefaultModelID = "gpt-5.6-terra"

    /// A persisted snapshot replaces the built-in one. Its default is kept while the list carries
    /// it (our own mapper chose it), else re-derived, so an older build's stored default can't pin
    /// a vanished model. An empty snapshot is ignored.
    public func seedModelCatalog(_ snapshot: SZProviderModelCatalog) {
        guard !snapshot.models.isEmpty else { return }
        var seeded = snapshot
        let ids = snapshot.models.map(\.id)
        if seeded.defaultModelID.map(ids.contains) != true {
            seeded.defaultModelID = ids.contains(Self.preferredDefaultModelID) ? Self.preferredDefaultModelID : ids.first
        }
        catalog.snapshot.withLock { $0 = seeded }
    }

    /// One `codex debug models` run: the CLI refreshes its manifest (~3s network, 0.144.5) and
    /// prints it as JSON, token-free. A nonzero exit or timeout throws so the host keeps the last
    /// snapshot.
    public func refreshModelCatalog(runner: any SZProcessRunning) async throws -> SZProviderModelCatalog? {
        let result = try await runner.run(
            "/usr/bin/env", ["codex", "debug", "models"],
            environment: SZAgentEnvironment.base(), currentDirectoryURL: nil, timeout: 20, onOutput: nil)
        guard result.exitCode == 0, !result.timedOut else {
            throw SZCodexCatalogError.fetchFailed(exitCode: result.exitCode, timedOut: result.timedOut)
        }
        guard let snapshot = Self.catalogSnapshot(fromDebugModelsOutput: result.output) else {
            throw SZCodexCatalogError.unparseableResponse
        }
        catalog.snapshot.withLock { $0 = snapshot }
        return snapshot
    }

    /// Map `codex debug models` output into a snapshot. Internal for the fixture tests. Recorded
    /// shape (0.144.5): one `{"models":[…]}` object; rows carry `slug`, `visibility` (list|hide),
    /// `priority`, `supported_reasoning_levels` [{effort}], `default_reasoning_level`,
    /// `additional_speed_tiers`, and `upgrade` (null, or {model, migration_markdown} on a retiring
    /// row). stdout and stderr arrive merged, so the object is found by brace scan. Visible rows
    /// only, priority order; retiring rows labelled; `none` never on a menu (pi's rule); a default
    /// off the row's own menu is dropped. Default: Terra; when Terra is retiring and its
    /// replacement is listed, the replacement; else the first row not retiring.
    static func catalogSnapshot(fromDebugModelsOutput output: String) -> SZProviderModelCatalog? {
        var rows: [[String: Any]] = []
        for text in SZOpenCodeProvider.topLevelJSONObjects(in: output) {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let manifest = object["models"] as? [[String: Any]] else { continue }
            rows = manifest
            break
        }
        let visible = rows
            .filter { $0["visibility"] as? String == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
        let models = visible.compactMap(model(fromManifestRow:))
        guard !models.isEmpty else { return nil }
        let ids = models.map(\.id)
        var replacement: [String: String] = [:]   // retiring slug → the vendor's pointer
        for row in visible {
            if let slug = row["slug"] as? String, let upgrade = row["upgrade"] as? [String: Any] {
                replacement[slug] = upgrade["model"] as? String ?? ""
            }
        }
        let defaultID: String?
        if ids.contains(preferredDefaultModelID) {
            let pointer = replacement[preferredDefaultModelID]
            defaultID = pointer.map(ids.contains) == true ? pointer : preferredDefaultModelID
        } else {
            defaultID = ids.first { replacement[$0] == nil } ?? ids.first
        }
        return SZProviderModelCatalog(models: models, defaultModelID: defaultID)
    }

    private static func model(fromManifestRow row: [String: Any]) -> SZProviderModel? {
        guard let slug = row["slug"] as? String, !slug.isEmpty else { return nil }
        let efforts = (row["supported_reasoning_levels"] as? [[String: Any]] ?? [])
            .compactMap { $0["effort"] as? String }
            .filter { $0 != "none" }
        let defaultEffort = (row["default_reasoning_level"] as? String).flatMap { efforts.contains($0) ? $0 : nil }
        let speedTiers = row["additional_speed_tiers"] as? [String] ?? []
        let retiring = row["upgrade"] is [String: Any]
        return SZProviderModel(
            id: slug,
            displayName: displayName(forModelID: slug) + (retiring ? " (retiring)" : ""),
            supportedReasoningEfforts: efforts.isEmpty ? nil : efforts,
            defaultReasoningEffort: defaultEffort,
            supportsFastMode: speedTiers.contains("fast") ? nil : false)   // nil = inherit the provider's true
    }

    /// Picker label from a slug — "gpt-5.6-sol" → "GPT-5.6 Sol", "gpt-5.4-mini" → "GPT-5.4 Mini" —
    /// not the manifest's `display_name` ("GPT-5.6-Sol"), so labels keep their shape when the
    /// vendor's copy changes.
    static func displayName(forModelID modelID: String) -> String {
        let segments = modelID.split(separator: "-").map(String.init)
        func titled(_ segment: String) -> String { segment.prefix(1).uppercased() + segment.dropFirst() }
        guard segments.count >= 2, segments[1].first?.isNumber == true else {
            return segments.map(titled).joined(separator: " ")
        }
        let family = "\(segments[0].uppercased())-\(segments[1])"
        return ([family] + segments.dropFirst(2).map(titled)).joined(separator: " ")
    }
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

enum SZCodexCatalogError: Error, CustomStringConvertible {
    case fetchFailed(exitCode: Int32, timedOut: Bool)
    case unparseableResponse

    var description: String {
        switch self {
        case .fetchFailed(let exitCode, let timedOut):
            "codex model catalog fetch failed (\(timedOut ? "timed out" : "exit \(exitCode)"))"
        case .unparseableResponse:
            "codex model catalog fetch returned no parseable manifest"
        }
    }
}

/// Parses codex's `--json` jsonl. codex surfaces narration as `agent_message` items and tools as
/// `mcp_tool_call` / `command_execution` items, plus optional `reasoning` summaries (→ `.thinking`).
/// The final answer is the LAST `agent_message`, so messages are held: a superseded one becomes
/// narration (`.thinking`) and the last is emitted once as `.reply` at the end — matching claude's
/// reply/trace split. The turn's usage rides the final `turn.completed` event (recorded from 0.144.1;
/// `cached_input_tokens` is a subset of `input_tokens`, so input needs no summing, and
/// `reasoning_output_tokens` is reported even on turns that emit no `reasoning` item).
final class SZCodexStreamConsumer: SZAgentStreamConsumer {
    private var pendingReply: String?

    func consume(_ line: String) -> [SZAgentStreamEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if obj["type"] as? String == "turn.completed" {
            guard let usage = obj["usage"] as? [String: Any],
                  let output = usage["output_tokens"] as? Int else { return [] }
            return [.usage(SZTokenUsage(
                inputTokens: usage["input_tokens"] as? Int ?? 0, outputTokens: output,
                cachedInputTokens: usage["cached_input_tokens"] as? Int,
                reasoningOutputTokens: usage["reasoning_output_tokens"] as? Int
            ))]
        }
        guard obj["type"] as? String == "item.completed",
              let item = obj["item"] as? [String: Any],
              let type = item["type"] as? String else { return [] }
        let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "agent_message", "assistant_message":
            guard !text.isEmpty else { return [] }
            var events: [SZAgentStreamEvent] = []
            if let prior = pendingReply { events.append(.thinking(prior)) }   // superseded → narration
            pendingReply = text
            return events
        case "reasoning":
            return text.isEmpty ? [] : [.thinking(text)]
        case "mcp_tool_call":
            return [.toolCall(name: item["tool"] as? String ?? "mcp tool")]   // the real tool name
        case "command_execution":
            return [.toolCall(name: "ran command")]
        default:
            return [.toolCall(name: type.replacingOccurrences(of: "_", with: " "))]
        }
    }

    func finish() -> [SZAgentStreamEvent] {
        guard let reply = pendingReply, !reply.isEmpty else { return [] }
        pendingReply = nil
        return [.reply(reply)]
    }
}
