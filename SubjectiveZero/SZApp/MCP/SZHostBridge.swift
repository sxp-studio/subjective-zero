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

    /// MCP `tools/list` payload for one surface. Pure → `nonisolated` so the server needn't hop.
    nonisolated static func toolDefinitions(for surface: Surface = .full) -> [[String: Any]] {
        (surface.exposesDebugTools ? debugToolDefinitions : []) + agentToolDefinitions + uiToolDefinitions
    }

    /// Dispatch one `tools/call`, trying each surface in turn. Image tools (which return an inline image,
    /// not text) are tried first; the text surfaces stay `String?` and are wrapped in `.text`.
    func callTool(name: String, arguments: [String: Any], surface: Surface = .full) throws -> SZMCPToolResult {
        // Withheld, not merely unlisted: knowing the name from somewhere else must not be enough.
        guard !Self.debugToolNames.contains(name) || surface.exposesDebugTools else {
            throw SZMCPError.message("\(name) is not available to agents")
        }
        if let result = try handleImageTool(name: name, arguments: arguments) { return result }
        if let result = try handleDebugTool(name: name, arguments: arguments) { return .text(result) }
        if let result = try handleAgentTool(name: name, arguments: arguments) { return .text(result) }
        if let result = try handleUITool(name: name, arguments: arguments) { return .text(result) }
        throw SZMCPError.message("unknown tool: \(name)")
    }

    /// Shared helper for a tool definition; `properties` is the JSON-Schema arg map (empty = no args).
    nonisolated static func tool(_ name: String, _ description: String, properties: [String: Any] = [:]) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties]]
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
