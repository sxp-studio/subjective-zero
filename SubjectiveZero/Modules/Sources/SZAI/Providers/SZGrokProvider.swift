// SPDX-License-Identifier: AGPL-3.0-only
// Grok CLI provider. Subprocess wrapper around `grok -p …` (no API key). Distinct from claude and
// codex in: MCP attaches through a config FILE staged into the working directory by `prepare()`
// (the CLI has no per-invocation MCP flag — `--mcp-config` is rejected, verified grok 0.2.93), and
// the `--output-format streaming-json` stream carries token-level `thought`/`text` chunks with NO
// tool-call events, so tool activity is invisible in the trace (the CLI's richer ACP mode,
// `grok agent stdio`, is a persistent process and doesn't fit the one-shot spawn seam — future work).
// Sessions are claude-style: the host mints `--session-id`, a chat turn continues with `--resume`
// (continuity live-verified on 0.2.93: a resumed turn recalled the prior turn's content).
//
// DYNAMIC MODEL CATALOG (pi-style, see SZPiProvider). grok's served ids are unversioned backend
// aliases the CLI enumerates via `grok models` — they re-point and disappear underneath a pinned
// manifest (observed 2026-07-16: the previously recorded "grok-composer-2.5-fast"/"grok-build"
// were gone and every `-m` run failed "unknown model id"; the same CLI build now vends only
// "grok-4.5"). So nothing is pinned: the catalog is fetched from the CLI, cached by the host, and
// `launch()` omits `-m` entirely while no catalog is known — the CLI then runs its own default,
// which is by construction an id the backend currently serves.
import Foundation
import Synchronization

public struct SZGrokProvider: SZProvider {
    public init() {}

    /// The provider's registry id — the one place the string is written (see SZClaudeProvider).
    public static let providerID = "grok"

    public let id = Self.providerID
    public let displayName = "Grok"

    /// Served from the last catalog snapshot (fetched or seeded) — empty until one lands, which
    /// keeps every consumer honest: the picker serves nothing to mislabel, `resolvedGenerationSettings`
    /// falls through to "", and `launch()` omits `-m` (the CLI's own default carries the run).
    public var models: [SZProviderModel] { catalog.snapshot.withLock { $0?.models ?? [] } }
    public var defaultModel: String { catalog.snapshot.withLock { $0?.defaultModelID ?? "" } }
    /// grok 0.2.93 HAS a `--reasoning-effort` flag but does not act on it for either served model,
    /// so no effort menu is declared and `launch()` never emits the flag. Evidence (2026-07-12):
    /// the flag silently accepts ANY value (even an invalid token — exit 0, no warning), so
    /// acceptance proves nothing; and two measured comparisons (`none` vs `high`, then `minimal` vs
    /// `xhigh` on a harder prompt, both models) showed no meaningful change in thought volume
    /// (27→26 / 24→24 chunks; 102→151 / 410→431 chars) with `none` not even suppressing thinking.
    /// Revisit if a future CLI honours it.
    public let defaultReasoningEffort = ""
    public let supportedReasoningEfforts: [String] = []
    public let supportsFastMode = false   // no fast-mode concept in this CLI's argv
    public let healthArgs = ["grok", "--version"]
    /// `grok models` exits 0 whether logged in or not (verified 0.2.93) — only the output differs
    /// ("You are logged in with grok.com." vs "You are not authenticated."), so the auth tier's
    /// marker path, not the exit code, is what classifies a logged-out install.
    public let authStatusArgs = ["grok", "models"]
    /// Recorded from grok 0.2.93. "You are not authenticated" is `grok models`' logged-out output;
    /// the other two are the device-auth banner a logged-out `grok -p` prints — it does NOT fail:
    /// it polls for an interactive browser login until killed, which is why the probe classifies
    /// markers ahead of its timeout.
    public let authFailureMarkers = [
        "You are not authenticated",
        "To sign in, open this URL",
        "Waiting for authorization",
    ]
    public let installCommand = "curl -fsSL https://x.ai/cli/install.sh | bash"
    public let loginCommand = "grok login"
    public let usesPreallocatedSessionID = true   // we mint the UUID and pass --session-id

    /// Last catalog snapshot. A reference cell (Mutex is noncopyable, so it rides in a class) —
    /// every copy of this value-type provider serves one truth, while each `SZGrokProvider()`
    /// gets its own cell, keeping tests isolated. (Same shape as SZPiProvider.)
    private let catalog = CatalogCell()

    private final class CatalogCell: Sendable {
        let snapshot = Mutex<SZProviderModelCatalog?>(nil)
    }

    // MARK: - Dynamic catalog

    public func seedModelCatalog(_ snapshot: SZProviderModelCatalog) {
        catalog.snapshot.withLock { $0 = snapshot }
    }

    /// One `grok models` run (token-free, <1s measured; the same command the auth tier uses, so
    /// its output shape is already a recorded contract). Logged out it exits 0 with the auth
    /// marker instead of a list — thrown as a failure so the host keeps the last-known catalog:
    /// unlike pi's BYOK catalog, grok's served models are backend-global, not account-shaped,
    /// so yesterday's snapshot is still the best truth a logged-out install has.
    public func refreshModelCatalog(runner: any SZProcessRunning) async throws -> SZProviderModelCatalog? {
        let result = try await runner.run(
            "/usr/bin/env", authStatusArgs,
            environment: SZAgentEnvironment.base(extra: ["GROK_DISABLE_AUTOUPDATER": "1"]),
            currentDirectoryURL: nil, timeout: 20, onOutput: nil)
        guard result.exitCode == 0, !result.timedOut else {
            throw SZGrokCatalogError.fetchFailed(exitCode: result.exitCode, timedOut: result.timedOut)
        }
        if authFailureMarkers.contains(where: result.output.contains) {
            throw SZGrokCatalogError.notAuthenticated
        }
        guard let snapshot = Self.catalogSnapshot(fromModelsOutput: result.output) else {
            throw SZGrokCatalogError.unparseableResponse
        }
        catalog.snapshot.withLock { $0 = snapshot }
        return snapshot
    }

    /// Map `grok models` output into a snapshot. Internal for the recorded-fixture tests.
    /// Recorded shape (0.2.93):
    ///
    ///     You are logged in with grok.com.
    ///
    ///     Default model: grok-4.5
    ///
    ///     Available models:
    ///       * grok-4.5 (default)
    ///
    /// with `- <id>` bullets on non-default entries when several are served (recorded 0.2.93,
    /// 2026-07-12 two-model catalog). Ids are the lines' first token under "Available models:"
    /// (leading `*`/`-` bullet stripped, trailing "(default)" annotation ignored). The default
    /// comes from the "Default model:" line, with the "(default)"-annotated entry as fallback.
    /// No effort/fast overrides are derived — this CLI has no acting effort or fast surface
    /// (see supportedReasoningEfforts).
    static func catalogSnapshot(fromModelsOutput output: String) -> SZProviderModelCatalog? {
        var models: [SZProviderModel] = []
        var defaultID: String?
        var annotatedDefaultID: String?
        var inList = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("Default model:") {
                defaultID = String(line.dropFirst("Default model:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Available models:") {
                inList = true
            } else if inList {
                let entry = (line.hasPrefix("* ") || line.hasPrefix("- "))
                    ? String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) : line
                guard let idToken = entry.split(separator: " ").first else { continue }
                let modelID = String(idToken)
                if entry.contains("(default)") { annotatedDefaultID = modelID }
                models.append(SZProviderModel(id: modelID, displayName: Self.displayName(forModelID: modelID)))
            }
        }
        guard !models.isEmpty else { return nil }
        let resolvedDefault = [defaultID, annotatedDefaultID, models.first?.id]
            .compactMap { $0 }.first { candidate in models.contains { $0.id == candidate } }
        return SZProviderModelCatalog(models: models, defaultModelID: resolvedDefault)
    }

    /// Picker label from a served id, keeping the "Grok" brand (these model names don't
    /// self-identify the way "Opus 4.8"/"GPT-5.5" do): dash segments title-cased, digits kept —
    /// "grok-4.5" → "Grok 4.5", "grok-composer-2.5-fast" → "Grok Composer 2.5 Fast".
    static func displayName(forModelID modelID: String) -> String {
        modelID.split(separator: "-")
            .map { segment in
                guard let first = segment.first, first.isLetter else { return String(segment) }
                return first.uppercased() + segment.dropFirst()
            }
            .joined(separator: " ")
    }

    /// The CLI discovers `<cwd>/.grok/config.toml` as its highest-priority config scope (pickup
    /// verified via `grok inspect`), and that file is the only way to hand it an MCP server for one
    /// run. Rewritten before every spawn so a stale port from a previous app launch self-heals, and
    /// removed when the turn carries no MCP — a leftover server entry would spend the CLI's 30s MCP
    /// startup timeout on a dead bridge.
    public func prepare(_ request: SZAgentRunRequest) throws {
        let configFile = request.workingDirectory.appending(path: ".grok/config.toml")
        guard let port = request.mcpServerPort else {
            try? FileManager.default.removeItem(at: configFile)
            return
        }
        try FileManager.default.createDirectory(
            at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.mcpConfigTOML(port: port).write(to: configFile, atomically: true, encoding: .utf8)
    }

    public func launch(_ request: SZAgentRunRequest, preallocatedSessionID: String?) -> SZLaunch {
        var args = ["grok", "-p", request.prompt,
                    "--output-format", "streaming-json",
                    // Full approval bypass for unattended runs, codex parity (a headless turn can't
                    // prompt). TODO(SZ-grok-permissions): tighten to scoped `--allow` rules
                    // (Edit/Write/MCPTool) and live-verify a ui_run coding agent still writes+compiles.
                    "--always-approve"]
        // No known model (runtime catalog before its first fetch) → no `-m`: the CLI runs its own
        // default, by construction an id the backend currently serves. Pinning a stale id here is
        // exactly what broke every run when the backend re-pointed the catalog (2026-07-16).
        let model = request.model ?? defaultModel
        if !model.isEmpty { args += ["-m", model] }
        if let resume = request.resumeSessionID {
            args += ["--resume", resume]   // continue the existing conversation (chat turn)
        } else if let sessionID = preallocatedSessionID {
            args += ["--session-id", sessionID]
        }
        // Never emits --reasoning-effort: see supportedReasoningEfforts. Update-check suppression
        // rides an env var rather than the documented --no-auto-update flag — the flag is absent
        // from `grok --help` 0.2.93 and an unknown flag is a hard argv error, while an unknown env
        // var is inert.
        let env = SZAgentEnvironment.base(extra: [
            "SWIFT_MODULE_CACHE_PATH": request.cacheDirectory.appending(path: "swift-module-cache").path,
            "CLANG_MODULE_CACHE_PATH": request.cacheDirectory.appending(path: "clang-module-cache").path,
            "GROK_DISABLE_AUTOUPDATER": "1",
        ])
        return SZLaunch(executable: "/usr/bin/env", arguments: args, environment: env)
    }

    public func parse(output: String, exitCode: Int32, preallocatedSessionID: String?) -> SZAgentOutcome {
        // grok's session id is the one we minted; success rides the exit code.
        SZAgentOutcome(sessionID: preallocatedSessionID, failed: exitCode != 0)
    }

    public func makeStreamConsumer() -> any SZAgentStreamConsumer { SZGrokStreamConsumer() }

    /// The stdio MCP server grok spawns is `nc` bridging to the host's in-process TCP listener.
    /// No `required` key — undocumented for this CLI (unlike codex's config).
    static func mcpConfigTOML(port: UInt16) -> String {
        """
        # Staged by SubjectiveZero before each grok run — rewritten every spawn, do not edit.
        [mcp_servers.subz]
        command = "/usr/bin/nc"
        args = ["127.0.0.1", "\(port)"]
        """
    }
}

enum SZGrokCatalogError: Error, CustomStringConvertible {
    case fetchFailed(exitCode: Int32, timedOut: Bool)
    case notAuthenticated
    case unparseableResponse

    var description: String {
        switch self {
        case .fetchFailed(let exitCode, let timedOut):
            "grok model catalog fetch failed (\(timedOut ? "timed out" : "exit \(exitCode)"))"
        case .notAuthenticated:
            "grok model catalog fetch hit the logged-out marker — kept the last-known catalog"
        case .unparseableResponse:
            "grok model catalog fetch returned no parseable model list"
        }
    }
}

/// Parses grok's streaming-json: token-level `{"type":"thought"|"text","data":…}` chunks and a final
/// `end` event (no per-line messages, no tool events, no usage — verified 0.2.93, so grok turns carry
/// no `.usage`). Usage was also hunted OUTSIDE the stream (0.2.93): the session dir
/// (~/.grok/sessions/<url-encoded-cwd>/<session-id>/) records only a CUMULATIVE context gauge
/// (`_meta.totalTokens` on updates.jsonl events, `contextTokensUsed` in signals.json) — no per-turn
/// input/output split exists anywhere, so there is nothing honest to map into SZTokenUsage. Chunks are accumulated — emitting per token would spam the trace — and flushed at
/// type transitions: a completed thought block becomes one `.thinking` when text starts, and text
/// superseded by a NEW thought block was narration, not the answer (matching claude/codex's
/// reply/trace split). The reply flushes in `finish()`, the one point that knows the stream is over.
final class SZGrokStreamConsumer: SZAgentStreamConsumer {
    private var pendingThought = ""
    private var pendingReply = ""

    func consume(_ line: String) -> [SZAgentStreamEvent] {
        guard let data = Self.sanitized(line).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return [] }
        switch type {
        case "thought":
            var events: [SZAgentStreamEvent] = []
            let reply = pendingReply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty {   // a new reasoning block after text → that text was narration
                events.append(.thinking(reply))
                pendingReply = ""
            }
            pendingThought += obj["data"] as? String ?? ""
            return events
        case "text":
            let events = flushThought()
            pendingReply += obj["data"] as? String ?? ""
            return events
        case "error":
            let message = (obj["message"] as? String ?? "error")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return flushThought() + [.thinking("⚠ " + message)]
        default:   // end / max_turns_reached / auto_compact_* — metadata, nothing to render
            return []
        }
    }

    func finish() -> [SZAgentStreamEvent] {
        var events = flushThought()
        let reply = pendingReply.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingReply = ""
        if !reply.isEmpty { events.append(.reply(reply)) }
        return events
    }

    private func flushThought() -> [SZAgentStreamEvent] {
        let thought = pendingThought.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingThought = ""
        return thought.isEmpty ? [] : [.thinking(thought)]
    }

    /// grok emits RAW control characters inside JSON string values (verified 0.2.93 — a strict
    /// parser throws "invalid control character"). Within one JSONL line a raw control char can
    /// only sit inside a string literal (JSON structure uses none), so escaping them linewise is
    /// safe and makes the line parseable.
    static func sanitized(_ line: String) -> String {
        guard line.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return line }
        var out = ""
        out.unicodeScalars.reserveCapacity(line.unicodeScalars.count)
        for scalar in line.unicodeScalars {
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
