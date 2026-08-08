// SPDX-License-Identifier: AGPL-3.0-only
// The graph strategy's two SZTraversalHost adapters — how the engine's seams read the live
// `SZOrchestrationContext` the host already builds for the frozen strategies. One adapter per
// ROLE: the DIRECTOR-bound host projects the build facts and runs Director turns through the
// host's injected runner; an ITEM-bound host (one per dispatched order) projects that order's
// item facts and assembles each coding turn's request exactly as the frozen dispatch did.
//
// Facts documents follow the SZFacts spec field names (SZCore/AgentFacts) and are encoded with
// deterministic `.sortedKeys` bytes. They are LOCAL Encodable documents rather than the spec
// structs themselves for two honest reasons: the spec structs expose no public initializer
// (their memberwise init is internal to SZCore, and the generated region's grammar forbids
// declaring one), and the item document additionally carries `graphJSON` — the item briefs
// project the live graph, exactly as the equivalence gate stubbed it; the spec gains the field
// when the host projection lands.
import Foundation
import SZCore

/// The coding sessions one run collects, shared across its item hosts — what the strategy
/// returns so the host can chat-resume each node's agent, and what a `.message` turn resumes.
@MainActor
final class SZGraphRunSessions {
    private(set) var byNode: [SZNodeID: String] = [:]

    func record(_ sessionID: String, for node: SZNodeID) { byNode[node] = sessionID }
    func session(for node: SZNodeID) -> String? { byNode[node] }
}

/// `askModel` has no provider wiring yet — the steps this phase ships are pure conditions that
/// never ask, so an ask reaching a host is a defect and must read honestly in the trace.
struct SZAskUnwiredError: Error, CustomStringConvertible {
    let agent: String
    let step: String
    var description: String {
        "askModel is not wired to a provider yet — this phase ships condition steps only "
            + "(step '\(step)' of '\(agent)' asked)"
    }
}

/// Deterministic facts bytes: `.sortedKeys`, so the same world always projects the same
/// document (steps and briefs must never see hash-order jitter).
enum SZGraphFactsEncoding {
    static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The live graph as the facts carry it. "" is the honest absence (no project loaded) —
    /// `projectLoaded` names the condition; a template projecting `{{graph}}` then refuses.
    static func graphJSON(_ graph: SZGraph?) -> String {
        graph.map { json($0) } ?? ""
    }
}

// MARK: - The DIRECTOR-bound host

/// One director thread's traversal host: every read is rebuilt fresh from the live context, and
/// the motor injects the per-traversal values (round, steers) before each `startTraversal`.
@MainActor
final class SZDirectorTraversalHost: SZTraversalHost {
    private let context: SZOrchestrationContext
    private let renderer: SZBriefRenderer
    private let roundCap: Int
    private let onNote: @MainActor @Sendable (SZTraversalNote) -> Void
    private var round = 0
    private var steers: [String] = []

    init(context: SZOrchestrationContext, renderer: SZBriefRenderer, roundCap: Int,
         onNote: @escaping @MainActor @Sendable (SZTraversalNote) -> Void) {
        self.context = context
        self.renderer = renderer
        self.roundCap = roundCap
        self.onNote = onNote
    }

    /// Injected per traversal by the motor: which settled re-entry this is, and the steers the
    /// machine drained into its `startTraversal` command.
    func begin(round: Int, steers: [String]) {
        self.round = round
        self.steers = steers
    }

    /// The kind-gated facts document. A `.settled` re-entry serves the BUILD facts BY DESIGN:
    /// the facts spec declares no settled struct — a settled re-entry reasons over the same
    /// live build picture, one round later (`round` carries the difference).
    func factsJSON(kind: SZMessageKind) -> String {
        SZGraphFactsEncoding.json(buildFacts())
    }

    /// A dispatch's `[String]`-typed fact, resolved from the SAME projection `factsJSON`
    /// encodes — one home for the values, whichever door reads them.
    func itemsFact(named name: String, kind: SZMessageKind) -> [String] {
        let facts = buildFacts()
        switch name {
        case "workSet": return facts.workSet
        case "steers": return facts.steers
        default: return []   // the pack gate ties dispatches to catalogued [String] facts
        }
    }

    func renderBrief(agent: String, template: String, kind: SZMessageKind) throws -> String {
        // A settled re-entry renders under the graph's own kind — the renderer's stated
        // contract ("`settled` re-enters under its graph's own kind").
        try renderer.render(agent: agent, template: template,
                            kind: kind == .settled ? .build : kind,
                            factsJSON: factsJSON(kind: kind),
                            delivery: SZBriefDelivery(instruction: context.instruction))
    }

    /// One Director turn through the host's injected runner (streamed into the Director tab).
    /// No runner attached (tests / headless) → the turn honestly fails; a wired `error` edge
    /// may route recovery, an unwired one ends the traversal failed.
    func runTurn(_ order: SZTurnOrder) async -> SZTurnReport {
        guard let directorTurn = context.directorTurn else {
            return SZTurnReport(failed: true, detail: "no Director turn runner is attached")
        }
        do {
            let result = try await directorTurn(order.brief)
            return SZTurnReport(failed: result.outcome.failed, detail: result.outcome.message)
        } catch {
            return SZTurnReport(failed: true, detail: String(describing: error))
        }
    }

    func serveAsk(agent: String, step: String, requestJSON: String) async throws -> String {
        throw SZAskUnwiredError(agent: agent, step: step)
    }

    func note(_ note: SZTraversalNote) { onNote(note) }

    // MARK: - Facts assembly

    /// The build projection, spec-shaped (see the header for why it is a local document).
    private struct BuildFactsDocument: Encodable {
        var workLeft: Int
        var workSet: [String]
        var nodeStatuses: [String: String]
        var buildErrors: [String: String]
        var round: Int
        var roundCap: Int
        var briefed: Bool
        var projectLoaded: Bool
        var graphJSON: String
        var steers: [String]
    }

    private func buildFacts() -> BuildFactsDocument {
        // The work set, reimplemented minimally from the previous strategies' derivation (the
        // frozen code stays uncalled): every node needing implementation, scoped to the run's
        // captured set when the host provides one — authoritative even when empty, in graph
        // order so multi-node projections stay deterministic without inventing a new order.
        let graph = context.store.project?.graph
        let candidates = (graph?.nodes ?? []).filter(\.needsImplementation).map(\.id)
        let scoped = context.workSet().map { set in candidates.filter(set.contains) } ?? candidates
        var statuses: [String: String] = [:]
        for (node, status) in context.nodeStatus() { statuses[node.uuidString] = status }
        return BuildFactsDocument(
            workLeft: scoped.count,
            workSet: scoped.map(\.uuidString),
            nodeStatuses: statuses,
            buildErrors: [:],   // compile diagnostics join the projection with the record work (next phase)
            round: round,
            roundCap: roundCap,
            // Round 0 carries the host's flag (a chat-triggered run was already briefed by that
            // chat turn); any later round means the opening traversal has run.
            briefed: round == 0 ? context.directorAlreadyBriefed : true,
            projectLoaded: context.store.project != nil,
            graphJSON: SZGraphFactsEncoding.graphJSON(graph),
            steers: steers)
    }
}

// MARK: - The ITEM-bound host

/// One dispatched order's traversal host. Request assembly in `runTurn` mirrors the frozen
/// procedural dispatch field-for-field (working dir, package/cache dirs, MCP port + allowlist,
/// generation settings, the coding budgets) so a graph-dispatched coding turn launches exactly
/// like a legacy one; the session captured from the result is what a `.message` turn resumes.
@MainActor
final class SZItemTraversalHost: SZTraversalHost {
    private let context: SZOrchestrationContext
    private let renderer: SZBriefRenderer
    private let order: SZDispatchOrder
    private let nodeID: SZNodeID
    private let sessions: SZGraphRunSessions
    private let registry: SZProviderRegistry
    private let onNote: @MainActor @Sendable (SZTraversalNote) -> Void

    init(context: SZOrchestrationContext, renderer: SZBriefRenderer, order: SZDispatchOrder,
         nodeID: SZNodeID, sessions: SZGraphRunSessions, registry: SZProviderRegistry,
         onNote: @escaping @MainActor @Sendable (SZTraversalNote) -> Void) {
        self.context = context
        self.renderer = renderer
        self.order = order
        self.nodeID = nodeID
        self.sessions = sessions
        self.registry = registry
        self.onNote = onNote
    }

    /// The item projection, spec-shaped plus `graphJSON` (see the header).
    private struct ItemFactsDocument: Encodable {
        var attempt: Int
        var senderNote: String?
        var blocker: String?
        var resumeSession: String?
        var graphJSON: String
    }

    func factsJSON(kind: SZMessageKind) -> String {
        SZGraphFactsEncoding.json(ItemFactsDocument(
            attempt: order.attempt,
            senderNote: order.senderNote,
            blocker: context.nodeStatus()[nodeID],
            // Resume rides the session map at request assembly, not the facts, until the host
            // projection lands — the brief never needs the id, only the transport does.
            resumeSession: nil,
            graphJSON: SZGraphFactsEncoding.graphJSON(context.store.project?.graph)))
    }

    func itemsFact(named name: String, kind: SZMessageKind) -> [String] {
        []   // no [String]-typed item fact exists; the pack gate keeps dispatches off item graphs
    }

    func renderBrief(agent: String, template: String, kind: SZMessageKind) throws -> String {
        // The delivery is built exactly as the equivalence gate built the coding fixtures:
        // the target node id, the preserve-behavior flag for staged pieces, and the inlined
        // library index when the host prefetched one (the renderer owns preserve-never-inlines).
        try renderer.render(agent: agent, template: template, kind: kind,
                            factsJSON: factsJSON(kind: kind),
                            delivery: SZBriefDelivery(
                                item: nodeID.uuidString,
                                preserveBehavior: context.stagedPieces().contains(nodeID),
                                libraryIndex: context.libraryIndexText))
    }

    func runTurn(_ turn: SZTurnOrder) async -> SZTurnReport {
        let workingDirectory = context.cacheDirectory.appending(path: "agent/\(nodeID.uuidString)")
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let request = SZAgentRunRequest(
            prompt: turn.brief,
            workingDirectory: workingDirectory,
            packageDirectory: context.projectURL,
            cacheDirectory: context.cacheDirectory,
            mcpServerPort: context.mcpPort,
            allowedMCPTools: context.allowedMCPTools,
            // A `.message` turn continues the node's own conversation — the session this run
            // captured for it (the frozen reconcile's resume); a `.spawn` turn starts cold.
            resumeSessionID: turn.session == .message ? sessions.session(for: nodeID) : nil,
            model: turn.choice.model,
            reasoningEffort: turn.choice.reasoningEffort,
            fastMode: context.generationSettings.fastMode ?? false,
            timeout: SZProceduralDirectorStrategy.codingTimeout,
            inactivityTimeout: SZProceduralDirectorStrategy.codingInactivityTimeout)
        guard let provider = registry.provider(id: turn.choice.providerID) else {
            return SZTurnReport(
                failed: true,
                detail: SZOrchestratorError.unknownProvider(turn.choice.providerID).description)
        }
        do {
            // Stream into the node's tab when the host injected a runner; run the provider
            // directly otherwise (tests) — the frozen dispatch's exact split.
            let result: SZAgentRunResult
            if let turnRunner = context.turnRunner {
                result = try await turnRunner(nodeID, request, provider)
            } else {
                result = try await provider.run(request, runner: context.runner)
            }
            // Persist the transcript for inspection, where the frozen path wrote it.
            try? result.process.output.write(
                to: workingDirectory.appending(path: "agent-output.log"),
                atomically: true, encoding: .utf8)
            if let sessionID = result.outcome.sessionID {
                sessions.record(sessionID, for: nodeID)
            }
            return SZTurnReport(failed: result.outcome.failed, detail: result.outcome.message)
        } catch {
            return SZTurnReport(failed: true, detail: String(describing: error))
        }
    }

    func serveAsk(agent: String, step: String, requestJSON: String) async throws -> String {
        throw SZAskUnwiredError(agent: agent, step: step)
    }

    func note(_ note: SZTraversalNote) { onNote(note) }
}
