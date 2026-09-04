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
        (agentToolDefinitions + uiToolDefinitions + bindingToolDefinitions)
            .filter { ($0["agentCallable"] as? Bool) == false }
            .compactMap { $0["name"] as? String })

    /// The production tool names a spawned agent MAY call — the `.agent` surface minus the withheld
    /// set (never `debug_*`). Definition order preserved for a stable allowlist string. This is what
    /// the Claude provider's `--allowedTools` mirrors (plumbed via `SZAgentRunRequest.allowedMCPTools`),
    /// so a NEW tool is reachable by construction and the allowlist can never go stale.
    nonisolated static let agentCallableToolNames: [String] =
        (agentToolDefinitions + uiToolDefinitions + bindingToolDefinitions)
            .filter { ($0["agentCallable"] as? Bool) != false }
            .compactMap { $0["name"] as? String }

    /// MCP `tools/list` payload for one surface. Pure → `nonisolated` so the server needn't hop.
    /// The `.full` test bus keeps everything; the `.agent` bus drops both `debug_*` (via
    /// `exposesDebugTools`) and any `agentCallable: false` tool. The `agentCallable` key is host-side
    /// policy, not wire schema, so it is stripped from every returned definition.
    nonisolated static func toolDefinitions(for surface: Surface = .full) -> [[String: Any]] {
        let debug = surface.exposesDebugTools ? debugToolDefinitions : []
        let agentAndUI = (agentToolDefinitions + uiToolDefinitions + bindingToolDefinitions).filter {
            surface == .full || ($0["agentCallable"] as? Bool) != false
        }
        return (debug + agentAndUI).map { def in
            var def = def; def["agentCallable"] = nil; return def
        }
    }

    /// Tool names that touch NO main-actor host state and run OFF the main actor —
    /// `SZMCPServer` dispatches these before its MainActor hop, so a long tool (a full
    /// pack compile pass) can never wedge the app. Membership is a promise: a listed
    /// tool may read only nonisolated statics and its own arguments.
    nonisolated static let offMainToolNames: Set<String> = ["debug_check_pack", "agent_check_path"]

    /// The off-main dispatch lane: the same withholding rails as `callTool`, then the
    /// tool as plain async work on the calling connection's task.
    nonisolated func callOffMainTool(name: String, arguments: [String: Any],
                                     surface: Surface) async throws -> SZMCPToolResult {
        let arguments = Self.omittingNulls(arguments)
        guard !Self.debugToolNames.contains(name) || surface.exposesDebugTools else {
            throw SZMCPError.message("\(name) is not available to agents")
        }
        guard !Self.agentWithheldToolNames.contains(name) || surface == .full else {
            throw SZMCPError.message("\(name) is not available to agents")
        }
        switch name {
        case "debug_check_pack": return .text(await Self.debugCheckPack(arguments))
        // A stat can block for seconds on a stalled network mount; off-main it can never wedge the app.
        case "agent_check_path": return .text(try Self.agentCheckPath(arguments))
        default: throw SZMCPError.message("unknown off-main tool: \(name)")
        }
    }

    /// Dispatch one `tools/call`, trying each surface in turn. Image tools (which return an inline image,
    /// not text) are tried first; the text surfaces stay `String?` and are wrapped in `.text`.
    /// The server's entry: every tool, on main. The two that await the renderer (its compile gate and
    /// its capture) are served first; everything else dispatches without suspending.
    func call(name: String, arguments: [String: Any], surface: Surface = .full,
              forcedContext: SZTraceContext? = nil,
              caller: SZClaimToken? = nil,
              callerScope: SZChatScope? = nil) async throws -> SZMCPToolResult {
        let (arguments, traceContext) = try admit(name: name, arguments: arguments, surface: surface,
                                                  forcedContext: forcedContext)
        return try await SZToolCaller.$claim.withValue(caller) {
        try await SZToolCaller.$scope.withValue(callerScope) {
        try await SZTrace.$context.withValue(traceContext) {
            try await SZTrace.span(SZTurnStage.mcpTool, detail: name, closing: closing(name: name, trace: traceContext)) {
                if let result = try await handleAsyncAgentTool(name: name, arguments: arguments) { return result }
                return try dispatch(name: name, arguments: arguments)
            }
        }
        }
        }
    }

    /// The tools that never suspend, for callers already on main (tests, mostly). Same rails as `call`.
    func callTool(name: String, arguments: [String: Any], surface: Surface = .full,
                  forcedContext: SZTraceContext? = nil,
                  caller: SZClaimToken? = nil,
                  callerScope: SZChatScope? = nil) throws -> SZMCPToolResult {
        let (arguments, traceContext) = try admit(name: name, arguments: arguments, surface: surface,
                                                  forcedContext: forcedContext)
        return try SZToolCaller.$claim.withValue(caller) {
        try SZToolCaller.$scope.withValue(callerScope) {
        try SZTrace.$context.withValue(traceContext) {
            try SZTrace.span(SZTurnStage.mcpTool, detail: name, closing: closing(name: name, trace: traceContext)) {
                try dispatch(name: name, arguments: arguments)
            }
        }
        }
        }
    }

    /// The span's close: the result's context weight, and its text filed under the turn.
    private func closing(name: String, trace: SZTraceContext?) -> (SZMCPToolResult) -> (detail: String?, addedTokens: Int?) {
        { [host] result in
            // The span closes with the RESULT's approximate context weight (chars/4): every tool
            // result feeds straight back into the agent's context, and these payloads — library
            // reads, doc pages, compile output — are most of what a turn's "in" count is made of.
            // The payload TEXT is filed under the turn's debug capture, so "what did this action
            // add" is inspectable as content, not just a number.
            if let trace, case .text(let text) = result {
                host.recordToolPayload(turnID: trace.turnID, tool: name, result: text)
            }
            return (detail: name, addedTokens: Self.contextWeight(of: result))
        }
    }

    private func dispatch(name: String, arguments: [String: Any]) throws -> SZMCPToolResult {
        if let result = try handleDebugTool(name: name, arguments: arguments) { return .text(result) }
        if let result = try handleAgentTool(name: name, arguments: arguments) { return .text(result) }
        if let result = try handleUITool(name: name, arguments: arguments) { return .text(result) }
        if let result = try handleBindingTool(name: name, arguments: arguments) { return .text(result) }
        throw SZMCPError.message("unknown tool: \(name)")
    }

    /// The gate every call passes: the withheld names, then the trace context the handlers nest under.
    private func admit(name: String, arguments: [String: Any], surface: Surface,
                       forcedContext: SZTraceContext?) throws -> (arguments: [String: Any], trace: SZTraceContext?) {
        let arguments = Self.omittingNulls(arguments)
        // Withheld, not merely unlisted: knowing the name from somewhere else must not be enough.
        guard !Self.debugToolNames.contains(name) || surface.exposesDebugTools else {
            throw SZMCPError.message("\(name) is not available to agents")
        }
        // Same rule for production tools flagged `agentCallable: false` — the `.full` test bus alone reaches them.
        guard !Self.agentWithheldToolNames.contains(name) || surface == .full else {
            throw SZMCPError.message("\(name) is not available to agents")
        }
        // Trace: WHO does this call belong to? A per-turn listener KNOWS (its port is the caller's
        // identity — `forcedContext`); the standing AGENT bus falls back to the host's attribution
        // rule. The `.full` test bus gets no fallback: a driving/debugging client poking tools
        // mid-turn would satisfy "sole in-flight turn" and pollute that agent's breakdown.
        // The MCP server's MainActor.run hop inherits no task-locals, so the bridge binds its own —
        // and binding even a nil context deliberately SHADOWS anything ambient, so an
        // unattributable call drops rather than misfiles. Every fence inside any handler (compile,
        // promote, future tools) nests under this span automatically. debug_* is the observer, not
        // the observed. `span` records thrown handlers too — a failing call still took time.
        // The caller's claim rides the same way as the trace context: bound (even when nil — an
        // unidentified call must SHADOW any ambient identity, never inherit one) so the mutation
        // fence downstream can tell a turn touching its own held node from a bystander.
        let traceContext = Self.debugToolNames.contains(name)
            ? nil : (forcedContext ?? (surface == .agent ? host.traceContext(for: arguments) : nil))
        return (arguments, traceContext)
    }

    /// Arguments with every JSON `null` VALUE dropped, at any depth — the one place "absent" is
    /// decided, for every tool.
    ///
    /// A client that materializes its declared-but-unused optional properties as `null` sends
    /// `{"node": null}` for the argument-less call, and `arguments["node"] != nil` (or any accessor
    /// reaching for `NSNull`) then answers a question the caller never asked. Handlers must not each
    /// remember to special-case it. Array ELEMENTS are left alone: a null inside a list is a shape
    /// fact (arity, an unparseable entry) the coercions still have to refuse.
    nonisolated static func omittingNulls(_ arguments: [String: Any]) -> [String: Any] {
        arguments.compactMapValues { value -> Any? in
            if value is NSNull { return nil }
            if let nested = value as? [String: Any] { return omittingNulls(nested) }
            if let list = value as? [Any] {
                return list.map { ($0 as? [String: Any]).map(omittingNulls) ?? $0 }
            }
            return value
        }
    }

    /// ~tokens a tool result adds to the caller's context: text at the chars/4 rule of thumb;
    /// an image at its base64 length/4 (rough, but honest about being the payload's scale).
    private nonisolated static func contextWeight(of result: SZMCPToolResult) -> Int {
        switch result {
        case .text(let text): return text.count / 4
        case .image(let base64): return base64.count / 4
        }
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

    /// The ONE shape a tool's JSON payload takes: pretty, key-sorted, slashes unescaped. An agent
    /// reads these, and one tool answering in a different shape than its neighbours is a trap — so
    /// both encoders below spell the same three options (their option types differ; a test pins the
    /// two paths byte-equal).
    nonisolated static let jsonFormatting: JSONEncoder.OutputFormatting =
        [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    nonisolated static let jsonWriting: JSONSerialization.WritingOptions =
        [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]

    /// JSON-encode a Codable value for a tool's text payload.
    func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = Self.jsonFormatting
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The same shape for a payload already decoded into a dictionary (an annotated `agent_read_*`
    /// answer), so the annotated and fallback paths cannot drift. `fallback` covers a value
    /// `JSONSerialization` refuses.
    func encodeJSON(_ json: [String: Any], fallback: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: Self.jsonWriting)
        else { return fallback }
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
