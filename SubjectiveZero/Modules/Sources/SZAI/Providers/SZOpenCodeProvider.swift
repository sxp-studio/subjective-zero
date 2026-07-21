// SPDX-License-Identifier: AGPL-3.0-only
// opencode CLI provider (opencode.ai). Subprocess wrapper around `opencode run --format json …`
// (no API key — opencode owns auth: OpenAI/Anthropic/etc. OAuth or user keys, via `opencode auth`).
// The seam header in SZProvider.swift already name-checks opencode as the design precedent — this is
// that provider. Distinct from claude/codex/grok/pi in the combination, all verified on opencode
// 1.18.4 (2026-07-21):
//
//  1. DYNAMIC MODEL CATALOG (pi-style). opencode is a multi-provider harness — the served models
//     depend on which backends the USER authed, so no static manifest can know them. The catalog is
//     enumerated from the CLI (`opencode models --verbose`, token-free), cached by the host, and
//     re-fetched on health transitions — see `refreshModelCatalog`. Model ids are qualified
//     `provider/model` argv tokens (e.g. "openai/gpt-5.6-terra"), the form `-m` accepts.
//
//  2. PER-MODEL REASONING EFFORTS FROM METADATA. Each model's verbose JSON carries
//     `capabilities.reasoning` and a `variants` map whose KEYS are exactly the `--variant` tokens the
//     model accepts (openai reasoning models: none/low/medium/high/xhigh/max) — pi's `thinkingLevelMap`
//     equivalent. Unlike grok's inert flag, these map straight onto OpenAI's real `reasoningEffort`
//     API param, so they are honest to declare; `launch()` emits `--variant <token>`. "none" is dropped
//     from the menu (no subz provider models a no-thinking token — pi's rule).
//
//  3. MCP VIA AN INLINE ENV CONFIG. opencode has no per-invocation MCP flag. It CAN read a cwd
//     `opencode.json`, but a session's project (and thus which config chain supplies its MCP servers)
//     resolves to the nearest GIT root — so a cwd-staged file inside a git worktree is intermittently
//     dropped and `nc` never dialed (caught via a host-side connection trace: zero agent-bus accepts).
//     Instead `launch()` passes the config inline via `OPENCODE_CONFIG_CONTENT` (a `mcp.subz` local
//     stdio server = `nc` bridging to the host's TCP listener) — directory-independent, so every
//     instance opencode spins up carries it (verified 4/4 from inside a git worktree, where the file
//     path failed). The MCP tool names then arrive namespaced `subz_*` (see the launch() rewrite).
//
// Sessions are codex-style: opencode mints its own `ses_…` id, so we DON'T preallocate — `parse()`
// reads it back off any `--format json` event (every event carries `sessionID`). A chat turn continues
// with `-s <ses_…>` (not `-c`, which means "last session" and is ambiguous across the host's per-scope
// working dirs). A failed turn exits nonzero AND emits a top-level `{"type":"error",…}` event
// (verified with a bogus model id: exit 1), so success rides the exit code.
import Foundation
import Synchronization
import SZCore

public struct SZOpenCodeProvider: SZProvider {
    public init() {}

    /// The provider's registry id — the one place the string is written (see SZClaudeProvider).
    public static let providerID = "opencode"

    public let id = Self.providerID
    public let displayName = "opencode"   // the brand mark is lowercase (unlike Codex/Grok/Pi)

    /// Served from the last catalog snapshot (fetched or seeded) — empty until one lands, which keeps
    /// every consumer honest: the picker serves nothing to mislabel, `resolvedGenerationSettings` falls
    /// through to "", and `launch()` omits `-m` (opencode's own configured default carries the run).
    public var models: [SZProviderModel] { catalog.snapshot.withLock { $0?.models ?? [] } }
    public var defaultModel: String { catalog.snapshot.withLock { $0?.defaultModelID ?? "" } }

    /// Provider-level fallbacks only — every enumerated model overrides these from its own `variants`
    /// map (openai reasoning models expose low…max; non-reasoning models get an empty menu). Used just
    /// for a stored id no longer in the catalog. "medium" is opencode's conventional middle effort.
    public let defaultReasoningEffort = "medium"
    public let supportedReasoningEfforts = ["low", "medium", "high", "xhigh", "max"]
    /// opencode has no fast-mode FLAG: fast is a distinct model id ("…-terra-fast" alongside "…-terra"),
    /// so it surfaces in the dynamic catalog as a selectable model, not a toggle. (Same "no such flag"
    /// reason grok/pi carry false.)
    public let supportsFastMode = false
    public let healthArgs = ["opencode", "--version"]
    /// `opencode auth list` prints the configured credentials ("OpenAI  oauth … 1 credentials"). It is
    /// not model-gated (opencode is multi-provider) — the auth tier's marker path classifies a
    /// credential-less install by the "0 credentials" summary line.
    public let authStatusArgs = ["opencode", "auth", "list"]
    /// Recorded from opencode 1.18.4's `auth list` summary. A logged-out install has no stored
    /// credentials, so the count line reads "0 credentials". (The tier-3 probe backstops this: a
    /// credential-less real run fails, which the setup sheet surfaces regardless of this marker.)
    public let authFailureMarkers = ["0 credentials"]
    public let installCommand = "curl -fsSL https://opencode.ai/install | bash"
    public let loginCommand = "opencode auth login"
    public let usesPreallocatedSessionID = false   // opencode mints the id; it comes back in the stream

    /// Last catalog snapshot. A reference cell (Mutex is noncopyable, so it rides in a class) — every
    /// copy of this value-type provider serves one truth, while each `SZOpenCodeProvider()` gets its
    /// own cell, keeping tests isolated. (Same shape as SZPiProvider / SZGrokProvider.)
    private let catalog = CatalogCell()

    private final class CatalogCell: Sendable {
        let snapshot = Mutex<SZProviderModelCatalog?>(nil)
    }

    // MARK: - Dynamic catalog

    public func seedModelCatalog(_ snapshot: SZProviderModelCatalog) {
        catalog.snapshot.withLock { $0 = snapshot }
    }

    /// One `opencode models --verbose` run (token-free — it reads the local models.dev cache, no
    /// backend turn). Emits one pretty-printed JSON object per model, carrying id/providerID/name,
    /// `capabilities.reasoning`, and the `variants` map. Logged out it still lists the free
    /// (auth-less) models, so — unlike pi — it doesn't collapse to empty; the auth tier, not this
    /// fetch, is what reports a credential-less install.
    public func refreshModelCatalog(runner: any SZProcessRunning) async throws -> SZProviderModelCatalog? {
        let result = try await runner.run(
            "/usr/bin/env", ["opencode", "models", "--verbose"],
            environment: SZAgentEnvironment.base(), currentDirectoryURL: nil, timeout: 20, onOutput: nil)
        guard result.exitCode == 0, !result.timedOut else {
            throw SZOpenCodeCatalogError.fetchFailed(exitCode: result.exitCode, timedOut: result.timedOut)
        }
        guard let snapshot = Self.catalogSnapshot(fromVerboseOutput: result.output) else {
            throw SZOpenCodeCatalogError.unparseableResponse
        }
        catalog.snapshot.withLock { $0 = snapshot }
        return snapshot
    }

    /// Map `opencode models --verbose` output into a snapshot. Internal for the recorded-fixture tests.
    /// Each top-level `{ … }` is one model object; `Self.topLevelJSONObjects` extracts them
    /// string-state-aware (robust to the pretty formatting). Only `status == "active"` models are
    /// kept. The default is the first non-free model (a real authed provider) so a free "opencode/*"
    /// model is never the picker's default; falls back to the first model overall.
    static func catalogSnapshot(fromVerboseOutput output: String) -> SZProviderModelCatalog? {
        var raw: [[String: Any]] = []
        for object in topLevelJSONObjects(in: output) {
            guard let data = object.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["providerID"] is String, obj["id"] is String else { continue }
            guard (obj["status"] as? String) == "active" else { continue }   // active only; drop status-less
            raw.append(obj)
        }
        let names = raw.compactMap { $0["name"] as? String }
        let duplicated = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
        let models = raw.compactMap { model(fromVerbose: $0, duplicatedNames: duplicated) }
        guard !models.isEmpty else { return nil }
        let defaultID = models.first { !$0.id.hasPrefix("opencode/") }?.id ?? models.first?.id
        return SZProviderModelCatalog(models: models, defaultModelID: defaultID)
    }

    private static func model(fromVerbose obj: [String: Any], duplicatedNames: Set<String>) -> SZProviderModel? {
        guard let provider = obj["providerID"] as? String, let bare = obj["id"] as? String,
              !provider.isEmpty, !bare.isEmpty else { return nil }
        let name = obj["name"] as? String ?? bare
        let capabilities = obj["capabilities"] as? [String: Any]
        let reasoning = capabilities?["reasoning"] as? Bool ?? false
        let variants: [String] = Array((obj["variants"] as? [String: Any] ?? [:]).keys)
        let efforts = reasoning ? reasoningEfforts(fromVariants: variants) : []
        return SZProviderModel(
            id: "\(provider)/\(bare)",
            displayName: duplicatedNames.contains(name) ? "\(name) (\(provider))" : name,
            supportedReasoningEfforts: efforts.isEmpty ? nil : efforts,
            defaultReasoningEffort: efforts.isEmpty ? nil
                : (efforts.contains("medium") ? "medium" : efforts.first))
    }

    /// The `--variant` tokens a model accepts, in subz's canonical menu order. "none" is dropped
    /// (no subz provider offers a no-thinking menu token — pi's rule); an unrecognised variant is
    /// appended after the known ones rather than dropped, so a new opencode effort still surfaces.
    static func reasoningEfforts(fromVariants variants: [String]) -> [String] {
        let order = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        let present = Set(variants).subtracting(["none"])
        let known = order.filter(present.contains)
        let extra = present.subtracting(order).sorted()
        return known + extra
    }

    /// Extract each top-level JSON object from a stream of concatenated (pretty-printed) objects,
    /// tracking string/escape state so braces inside string values never open or close an object.
    /// `opencode models --verbose` prints an id line then a pretty object per model; this ignores the
    /// bare id lines (they carry no `{`) and yields only the balanced objects.
    static func topLevelJSONObjects(in text: String) -> [String] {
        var objects: [String] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                if depth == 0 { start = i }
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0, let s = start {
                    objects.append(String(text[s...i]))
                    start = nil
                }
            }
            i = text.index(after: i)
        }
        return objects
    }

    // MARK: - Spawn
    //
    // No `prepare()` and no per-scope data isolation. opencode keeps its session store in a SQLite db
    // (WAL) under the user's real `~/.local/share/opencode`, alongside `auth.json`. Concurrent agents
    // (the Director + parallel coding agents) share it safely — opencode's own file locking serialises
    // writes, and refreshed OAuth tokens land back in the user's real store, exactly as when the user
    // runs opencode themselves (verified: 4 concurrent turns on the shared store all attach + succeed).
    // An earlier attempt to isolate `XDG_DATA_HOME` per scope was REMOVED: it forced copying `auth.json`
    // into throwaway dirs, which diverges single-use rotating refresh tokens and can log the user out of
    // their own opencode. The concurrency failure it was meant to fix was actually the cwd-config
    // discovery bug, now fixed by injecting the MCP config via OPENCODE_CONFIG_CONTENT (see launch()).

    public func launch(_ request: SZAgentRunRequest, preallocatedSessionID: String?) -> SZLaunch {
        var args = ["opencode", "run", "--format", "json"]
        // Headless permission bypass — an unattended turn can't answer opencode's approval prompts.
        // codex/grok/pi parity (full bypass). TODO(SZ-opencode-permissions): tighten to a scoped
        // permission config once the coding flow's required tools are pinned, then live-verify a
        // ui_run coding agent still writes+compiles.
        args.append("--auto")
        // No known model (runtime catalog before its first fetch) → no `-m`: opencode runs its own
        // configured default, by construction an id it currently serves (grok's lesson — pinning a
        // stale id is what breaks every run when the catalog re-points).
        let model = request.model ?? defaultModel
        if !model.isEmpty { args += ["-m", model] }
        // The effort token IS opencode's `--variant` key (mapped 1:1 in the catalog); resolvedGeneration-
        // Settings has already clamped it to this model's menu, so it's always one opencode accepts.
        if let effort = request.reasoningEffort, !effort.isEmpty {
            args += ["--variant", effort]
        }
        if let resume = request.resumeSessionID {
            args += ["-s", resume]   // continue the existing conversation (chat turn)
        }
        // MCP TOOL NAMESPACE. opencode prefixes every tool from an MCP server with the server's name
        // (`subz`), so the bridge's `agent_*`/`ui_*` tools arrive as `subz_agent_*`/`subz_ui_*`. The
        // agent briefings name them bare (written CLI-agnostic). A literal-minded model won't cross
        // that gap: observed on opencode 1.18.4 + GPT-5.6 Terra, both the Director and coding agent
        // declared the bare-named tools "unavailable" and stalled — even though a direct call to
        // `subz_agent_read_graph` from the same session works. Rewriting the briefing's tool tokens to
        // the exact names opencode exposes makes it match the tool list with zero mapping. Only when a
        // bridge is attached (a portless probe turn has no SubZ tools).
        var prompt = request.prompt
        if request.mcpServerPort != nil {
            prompt = Self.namespacedSubZTools(in: prompt)
        }
        // opencode's arg parser (yargs) would read a leading-`-` prompt as a flag; a leading space
        // defeats that and is invisible to the model (pi's guard, same reason).
        if prompt.hasPrefix("-") { prompt = " " + prompt }
        args.append(prompt)   // trailing positional (`opencode run [message..]`)
        var extraEnv = [
            "SWIFT_MODULE_CACHE_PATH": request.cacheDirectory.appending(path: "swift-module-cache").path,
            "CLANG_MODULE_CACHE_PATH": request.cacheDirectory.appending(path: "clang-module-cache").path,
        ]
        // MCP bridge config rides an ENV var, not a cwd file: opencode resolves a session's project to
        // the nearest GIT root and runs the turn on a git-root-rooted instance whose config chain does
        // NOT include a cwd-staged `opencode.json` — so the `nc` server was intermittently never dialed
        // (verified via host-side trace: zero connections on the agent bus). `OPENCODE_CONFIG_CONTENT`
        // is inline + directory-independent, so every instance opencode spins up carries the server
        // (verified: 4/4 attach from inside a git worktree, where the cwd-file path failed).
        if let port = request.mcpServerPort {
            extraEnv["OPENCODE_CONFIG_CONTENT"] = Self.mcpConfigJSON(port: port)
        }
        return SZLaunch(executable: "/usr/bin/env", arguments: args,
                        environment: SZAgentEnvironment.base(extra: extraEnv))
    }

    public func parse(output: String, exitCode: Int32, preallocatedSessionID: String?) -> SZAgentOutcome {
        // Session id is opencode's own `ses_…`, present on every `--format json` event — take the
        // first. Success rides the exit code (a failed turn exits nonzero, verified).
        var sessionID: String?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = event["sessionID"] as? String else { continue }
            sessionID = id
            break
        }
        return SZAgentOutcome(sessionID: sessionID, failed: exitCode != 0)
    }

    public func makeStreamConsumer() -> any SZAgentStreamConsumer { SZOpenCodeStreamConsumer() }

    /// Rewrite every SubZ tool token (`agent_*` / `ui_*` — the whole bridge surface, and nothing else
    /// the briefings mention) to opencode's namespaced form (`subz_agent_*` / `subz_ui_*`), so the
    /// briefing names the tools exactly as the model's tool list does. Word-boundary anchored and
    /// scoped to those two prefixes: the contract JSON's `"ui"` key and `ui.min`/`ui.step` fields
    /// carry no underscore and are untouched. Generic — a new bridge tool needs no change here.
    static func namespacedSubZTools(in prompt: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b((?:agent_|ui_)[a-z][a-z0-9_]*)\b"#)
        else { return prompt }
        let range = NSRange(prompt.startIndex..., in: prompt)
        return regex.stringByReplacingMatches(in: prompt, range: range, withTemplate: "subz_$1")
    }

    /// The `mcp.subz` local stdio server is `nc` bridging to the host's in-process TCP listener —
    /// `type: "local"` with `command` as an argv array (schema live-verified 1.18.4). Injected via
    /// `OPENCODE_CONFIG_CONTENT`; opencode merges it into every instance's config (auth is separate, in
    /// auth.json, so the user's providers stay authed).
    ///
    /// `timeout` overrides opencode's 5s default, which is a PER-TOOL-CALL budget that drops the whole
    /// bridge when a call exceeds it. `agent_compile_node` shells out to `swiftc` — a simple node
    /// measured 2.4s, but a complex node or a cold module cache runs longer; 120s is generous headroom
    /// so a slow compile never strips the agent's tools mid-turn.
    static func mcpConfigJSON(port: UInt16) -> String {
        """
        {
          "$schema": "https://opencode.ai/config.json",
          "mcp": {
            "subz": {
              "type": "local",
              "command": ["/usr/bin/nc", "127.0.0.1", "\(port)"],
              "enabled": true,
              "timeout": 120000
            }
          }
        }
        """
    }
}

enum SZOpenCodeCatalogError: Error, CustomStringConvertible {
    case fetchFailed(exitCode: Int32, timedOut: Bool)
    case unparseableResponse

    var description: String {
        switch self {
        case .fetchFailed(let exitCode, let timedOut):
            "opencode model catalog fetch failed (\(timedOut ? "timed out" : "exit \(exitCode)"))"
        case .unparseableResponse:
            "opencode model catalog fetch returned no parseable model objects"
        }
    }
}

/// Parses opencode's `--format json` JSONL. Event types (verified 1.18.4): `step_start` (lifecycle,
/// ignored), `reasoning` (part.text — real reasoning summary, may be empty for redacted models) →
/// `.thinking`; `tool_use` (part.tool = name, part.callID) → `.toolCall`, deduped by callID since a
/// call can appear as it runs and again on completion; `text` (part.text, the answer) held as the
/// candidate reply — a superseded one becomes narration (`.thinking`), matching claude/codex/pi's
/// reply/trace split — and flushed once in `finish()`; `step_finish` (part.tokens + part.cost) → usage.
/// A turn has ONE step_finish per step (a tool round is its own step), so usage is SUMMED across the
/// turn and emitted once. opencode's numbers are Anthropic-style (like pi): `total = input + cache +
/// output + reasoning`, where `input` EXCLUDES the cached share — so `inputTokens` adds the cache back
/// (SZTokenUsage's `inputTokens` is the whole prompt side, `cachedInputTokens` its cached subset), and
/// `outputTokens` reports output+reasoning with reasoning as its share (reasoning is disjoint from
/// output). Tool names arrive namespaced `subz_*` (opencode prefixes MCP tools), stripped to the bare
/// name the seam expects. A top-level `error` event → a prefixed `.thinking` note.
final class SZOpenCodeStreamConsumer: SZAgentStreamConsumer {
    private var pendingReply: String?
    private var seenToolCallIDs = Set<String>()
    private var inputTokens = 0, outputTokens = 0, reasoningTokens = 0, cachedTokens = 0
    private var costUSD = 0.0
    private var sawUsage = false

    func consume(_ line: String) -> [SZAgentStreamEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return [] }
        let part = obj["part"] as? [String: Any]
        switch type {
        case "reasoning":
            let text = (part?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.thinking(text)]
        case "tool_use":
            let callID = part?["callID"] as? String ?? UUID().uuidString
            guard seenToolCallIDs.insert(callID).inserted else { return [] }   // once per call
            let tool = part?["tool"] as? String ?? "tool"
            // De-namespace SubZ bridge tools (opencode exposes them as `subz_*`) so the trace shows the
            // bare name every other provider does — the seam's `.toolCall(name:)` contract.
            return [.toolCall(name: tool.hasPrefix("subz_") ? String(tool.dropFirst("subz_".count)) : tool)]
        case "text":
            let text = (part?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            var events: [SZAgentStreamEvent] = []
            if let prior = pendingReply { events.append(.thinking(prior)) }   // superseded → narration
            pendingReply = text
            return events
        case "step_finish":
            guard let tokens = part?["tokens"] as? [String: Any] else { return [] }
            sawUsage = true
            let reasoning = tokens["reasoning"] as? Int ?? 0
            let cache = tokens["cache"] as? [String: Any]
            let cached = (cache?["read"] as? Int ?? 0) + (cache?["write"] as? Int ?? 0)
            inputTokens += (tokens["input"] as? Int ?? 0) + cached   // opencode's `input` excludes cache
            outputTokens += (tokens["output"] as? Int ?? 0) + reasoning   // opencode splits reasoning out
            reasoningTokens += reasoning
            cachedTokens += cached
            costUSD += part?["cost"] as? Double ?? 0
            return []
        case "error":
            let message = ((obj["error"] as? [String: Any])?["data"] as? [String: Any])?["message"] as? String
                ?? (obj["error"] as? [String: Any])?["name"] as? String ?? "error"
            return [.thinking("⚠ " + message.trimmingCharacters(in: .whitespacesAndNewlines))]
        default:
            return []   // step_start and any future lifecycle events
        }
    }

    func finish() -> [SZAgentStreamEvent] {
        var events: [SZAgentStreamEvent] = []
        if sawUsage {
            events.append(.usage(SZTokenUsage(
                inputTokens: inputTokens, outputTokens: outputTokens,
                cachedInputTokens: cachedTokens > 0 ? cachedTokens : nil,
                reasoningOutputTokens: reasoningTokens > 0 ? reasoningTokens : nil,
                costUSD: costUSD > 0 ? costUSD : nil)))
            sawUsage = false
        }
        if let reply = pendingReply, !reply.isEmpty {
            pendingReply = nil
            events.append(.reply(reply))
        }
        return events
    }
}
