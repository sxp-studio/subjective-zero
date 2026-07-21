// SPDX-License-Identifier: AGPL-3.0-only
// The host's command router — the single sink for every MCP tool call (ARCHITECTURE.md "host seam").
// Concrete, in-SZApp: it calls SZRuntime / SZStore / SZAI by concrete type, so it cannot live in
// SZCore (Core depends on nothing). MainActor-isolated; the MCP server hops here from its
// connection queue.
//
// This file is the thin core: the type, the tool-call dispatcher, and the aggregated tool list. Each
// MCP surface's tools + handlers live in their own SZMCP+<Surface>.swift extension (BUILD_SPEC.md).
import Foundation
import SZCore

enum SZMCPError: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case .message(let m): m } }
}

/// The result of one `tools/call`: a text payload (the norm) or an inline image (e.g. `agent_view_frame`).
/// Sendable so it can cross back over the MainActor hop in `SZMCPServer`.
enum SZMCPToolResult: Sendable {
    case text(String)
    case image(base64: String)
}

@MainActor
final class SZHostBridge {
    unowned let host: SZHost

    init(host: SZHost) {
        self.host = host
    }

    /// Who is on the other end of a connection, and therefore which tools it may see and call.
    ///
    /// `debug_*` freezes the clock, forces node failures, and swaps the orchestrator. A closed-loop test
    /// driving the app needs all of it. An AGENT working inside the app does not — and when it reaches for
    /// `debug_snapshot_state` instead of `agent_read_graph`, the run stops resembling the one a user gets.
    /// It also pays for the noise: `debug_*` is a fifth of the tool surface an agent sifts before its
    /// first move.
    ///
    /// So agents get their own listener with the debug surface withheld, and the test bus keeps everything.
    /// `SZ_AGENT_DEBUG_TOOLS=1` hands it back for a session that deliberately wants it.
    enum Surface: Sendable {
        case full    // the closed-loop test bus
        case agent   // what a spawned agent sees

        /// Read once: the environment is fixed at launch, and `ProcessInfo.environment` copies the whole
        /// block on every access — this sits on the tool-call path.
        nonisolated static let agentDebugToolsAllowed =
            ProcessInfo.processInfo.environment["SZ_AGENT_DEBUG_TOOLS"] == "1"

        nonisolated var exposesDebugTools: Bool { self == .full || Self.agentDebugToolsAllowed }
    }

    /// The debug surface's tool names, derived from the definitions themselves — so `tools/list` and
    /// `tools/call` can't disagree about what "a debug tool" is. A name prefix would make the gate a
    /// naming convention: rename one tool and it silently becomes agent-callable, with nothing to fail.
    nonisolated static let debugToolNames = Set(debugToolDefinitions.compactMap { $0["name"] as? String })

    /// Production tools (agent + ui) deliberately withheld from the agent surface — each declared
    /// `agentCallable: false` at its definition. Derived, like `debugToolNames`, so the definition is
    /// the single source of truth: mark one and it drops off every agent bus and out of the mirror below.
    nonisolated static let agentWithheldToolNames = Set(
        (agentToolDefinitions + uiToolDefinitions)
            .filter { ($0["agentCallable"] as? Bool) == false }
            .compactMap { $0["name"] as? String })

    /// The production tool names a spawned agent MAY call — the `.agent` surface minus the withheld
    /// set (never `debug_*`). Definition order preserved for a stable allowlist string. This is what
    /// the Claude provider's `--allowedTools` mirrors (plumbed via `SZAgentRunRequest.allowedMCPTools`),
    /// so a NEW tool is reachable by construction and the allowlist can never go stale.
    nonisolated static let agentCallableToolNames: [String] =
        (agentToolDefinitions + uiToolDefinitions)
            .filter { ($0["agentCallable"] as? Bool) != false }
            .compactMap { $0["name"] as? String }

#if DEBUG
    /// Invariants the agent bus depends on, asserted once at startup. SZApp is an app target with no
    /// unit-test target that can import these definitions, so this stands in for the guard test: a future
    /// edit that reclassifies a tool (or leaks the policy key to the wire) trips here in every DEBUG run
    /// and in the MCP integration harness. All checks read env-independent derived sets, so
    /// `SZ_AGENT_DEBUG_TOOLS=1` (which legitimately adds `debug_*` to the live `.agent` tools/list) does
    /// not confuse them.
    nonisolated static func assertAgentSurfaceInvariants() {
        let callable = Set(agentCallableToolNames)
        assert(callable.isDisjoint(with: debugToolNames),
               "the agent allowlist mirror must never include a debug_* tool")
        assert(callable.isDisjoint(with: agentWithheldToolNames),
               "a tool cannot be both agent-callable and withheld")
        assert(callable.contains("agent_view_frame"),
               "agent_view_frame must be agent-callable (the bug this guards against)")
        assert(agentCallableToolNames.count == callable.count,
               "duplicate tool name across the agent + ui definitions")
        assert(toolDefinitions(for: .full).allSatisfy { $0["agentCallable"] == nil },
               "the agentCallable policy key must be stripped from every served definition")
    }
#endif

    /// MCP `tools/list` payload for one surface. Pure → `nonisolated` so the server needn't hop.
    /// The `.full` test bus keeps everything; the `.agent` bus drops both `debug_*` (via
    /// `exposesDebugTools`) and any `agentCallable: false` tool. The `agentCallable` key is host-side
    /// policy, not wire schema, so it is stripped from every returned definition.
    nonisolated static func toolDefinitions(for surface: Surface = .full) -> [[String: Any]] {
        let debug = surface.exposesDebugTools ? debugToolDefinitions : []
        let agentAndUI = (agentToolDefinitions + uiToolDefinitions).filter {
            surface == .full || ($0["agentCallable"] as? Bool) != false
        }
        return (debug + agentAndUI).map { def in
            var def = def; def["agentCallable"] = nil; return def
        }
    }

    /// Dispatch one `tools/call`, trying each surface in turn. Image tools (which return an inline image,
    /// not text) are tried first; the text surfaces stay `String?` and are wrapped in `.text`.
    func callTool(name: String, arguments: [String: Any], surface: Surface = .full) throws -> SZMCPToolResult {
        // Withheld, not merely unlisted: knowing the name from somewhere else must not be enough.
        guard !Self.debugToolNames.contains(name) || surface.exposesDebugTools else {
            throw SZMCPError.message("\(name) is not available to agents")
        }
        // Same rule for production tools flagged `agentCallable: false` — the `.full` test bus alone reaches them.
        guard !Self.agentWithheldToolNames.contains(name) || surface == .full else {
            throw SZMCPError.message("\(name) is not available to agents")
        }
        if let result = try handleImageTool(name: name, arguments: arguments) { return result }
        if let result = try handleDebugTool(name: name, arguments: arguments) { return .text(result) }
        if let result = try handleAgentTool(name: name, arguments: arguments) { return .text(result) }
        if let result = try handleUITool(name: name, arguments: arguments) { return .text(result) }
        throw SZMCPError.message("unknown tool: \(name)")
    }

    /// Shared helper for a tool definition; `properties` is the JSON-Schema arg map (empty = no args).
    /// `agentCallable` is host-side policy, NOT part of the MCP wire schema — `toolDefinitions(for:)`
    /// strips it before serving. A tool is agent-callable by default; declare `false` here (at the
    /// definition, the one source of truth) to withhold it from the agent surface for EVERY provider,
    /// the same way `debug_*` is withheld. That is why the Claude allowlist can be a derived mirror
    /// (`agentCallableToolNames`) rather than a hand-kept second list that drifts.
    nonisolated static func tool(_ name: String, _ description: String,
                                 properties: [String: Any] = [:], agentCallable: Bool = true) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties],
         "agentCallable": agentCallable]
    }

    /// Parse a tool's `scope` argument into a chat scope — absent defaults to the Director; anything
    /// that isn't "director"/"debug"/a node uuid is a tool error (surfaced to the agent), not a silent
    /// fall-through to the Director's transcript.
    func chatScope(_ arguments: [String: Any], tool: String, key: String = "scope") throws -> SZChatScope {
        let raw = arguments.string(key) ?? SZChatScope.directorKey
        guard let scope = SZChatScope(key: raw) else {
            throw SZMCPError.message("\(tool): unknown \(key) \"\(raw)\" — use a node uuid, \"director\", or \"debug\"")
        }
        return scope
    }

    /// JSON-encode a Codable value for a tool's text payload.
    func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Typed accessors over MCP `arguments` (JSONSerialization yields `NSNumber` for numbers).
extension [String: Any] {
    func string(_ key: String) -> String? { self[key] as? String }
    func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
    func uuid(_ key: String) -> UUID? { (self[key] as? String).flatMap(UUID.init(uuidString:)) }
    func uuidList(_ key: String) -> [UUID] {
        (self[key] as? [Any] ?? []).compactMap { ($0 as? String).flatMap(UUID.init(uuidString:)) }
    }
    func stringList(_ key: String) -> [String] { (self[key] as? [Any] ?? []).compactMap { $0 as? String } }
    func object(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
}
