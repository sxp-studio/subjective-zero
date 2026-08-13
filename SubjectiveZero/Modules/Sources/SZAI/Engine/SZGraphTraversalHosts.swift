// SPDX-License-Identifier: AGPL-3.0-only
// The engine's SZTraversalHost adapters, one per ROLE. The DIRECTOR- and ITEM-bound hosts
// read the live `SZOrchestrationContext` the host builds at `startRun`: the director host
// projects the build facts and runs Director turns through the host's injected runner; an
// item host (one per dispatched order) projects that order's item facts and assembles each
// coding turn's request exactly as the previous dispatch did. The CHAT-bound host serves a
// single delivered chat turn instead — closure-injected (no run, no context), because the
// app builds it per delivery.
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
    private let graphName: String
    private let queries: SZQueryService
    private let onNote: @MainActor @Sendable (SZTraversalNote) -> Void
    /// The strategy the run asked for, passed through to the facts verbatim. The HOST does
    /// not validate it — the graph's strategy step decides what a name means, so an unknown
    /// one falls back in the pack rather than being refused here.
    private let runVariant: String
    private var round = 0
    private var steers: [String] = []

    init(context: SZOrchestrationContext, renderer: SZBriefRenderer, roundCap: Int,
         graphName: String, queries: SZQueryService, runVariant: String = "",
         onNote: @escaping @MainActor @Sendable (SZTraversalNote) -> Void) {
        self.context = context
        self.renderer = renderer
        self.roundCap = roundCap
        self.graphName = graphName
        self.queries = queries
        self.runVariant = runVariant
        self.onNote = onNote
    }

    /// Injected per traversal by the motor: which settled re-entry this is, and the steers the
    /// machine drained into its `startTraversal` command.
    func begin(round: Int, steers: [String]) {
        self.round = round
        self.steers = steers
    }

    /// The facts document. Always the BUILD facts: this host serves the build lane, and a
    /// settled re-entry reasons over the same live picture one round later (`round` carries
    /// the difference) — which is exactly what `SZMessageKind.lane` folds.
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
        // No settled fold here any more: the engine hands every seam the LANE, and
        // `SZMessageKind.lane` is its one home.
        try renderer.render(agent: agent, template: template, kind: kind,
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

    /// One step ask, served through the query service (render → route → complete → journal).
    func serveAsk(agent: String, step: String, kind: SZMessageKind, factsJSON: String,
                  requestJSON: String) async throws -> String {
        try await queries.serve(agent: agent, graph: graphName, step: step, kind: kind,
                                factsJSON: factsJSON, requestJSON: requestJSON)
    }

    /// One validated step effect, relayed to the host's lane.
    func perform(effect: String, kind: SZMessageKind) async {
        await context.performEffect(effect, kind)
    }

    func note(_ note: SZTraversalNote) { onNote(note) }

    // MARK: - Facts assembly

    /// The build projection, spec-shaped (see the header for why it is a local document).
    private struct BuildFactsDocument: Encodable {
        var unimplemented: [String]
        var workSet: [String]
        var nodeStatuses: [String: String]
        var buildErrors: [String: String]
        var round: Int
        var roundCap: Int
        var briefed: Bool
        var projectLoaded: Bool
        var graphJSON: String
        var steers: [String]
        var runVariant: String
    }

    private func buildFacts() -> BuildFactsDocument {
        // The work set: every node needing implementation, scoped to the run's
        // captured set when the host provides one — authoritative even when empty, in graph
        // order so multi-node projections stay deterministic without inventing a new order.
        let graph = context.store.project?.graph
        let candidates = (graph?.nodes ?? []).filter(\.needsImplementation).map(\.id)
        let scoped = context.workSet().map { set in candidates.filter(set.contains) } ?? candidates
        var statuses: [String: String] = [:]
        for (node, status) in context.nodeStatus() { statuses[node.uuidString] = status }
        return BuildFactsDocument(
            // Today the evidence list IS the scoped work set (needsImplementation covers
            // unimplemented-or-broken source; empty prompts never enter the set). The two
            // facts diverge when compile diagnostics join the projection.
            unimplemented: scoped.map(\.uuidString),
            workSet: scoped.map(\.uuidString),
            nodeStatuses: statuses,
            buildErrors: [:],   // not projected: no host surface publishes per-node diagnostics yet
            round: round,
            roundCap: roundCap,
            // Round 0 carries the host's flag (a chat-triggered run was already briefed by that
            // chat turn); any later round means the opening traversal has run.
            briefed: round == 0 ? context.directorAlreadyBriefed : true,
            projectLoaded: context.store.project != nil,
            graphJSON: SZGraphFactsEncoding.graphJSON(graph),
            steers: steers,
            runVariant: runVariant)
    }
}

// MARK: - The CHAT-bound host

/// One DIRECTOR chat turn's traversal host. A chat is ONE traversal — the resuming fork, the
/// turn, the route-reply ruling — so the app runs it straight through `SZGraphEngine`,
/// WITHOUT the thread machine: the machine owns THREADS (dispatch sets, one settled reply,
/// rounds), and a chat graph dispatches nothing, so a machine here would wrap a single
/// `startTraversal` in commands nothing consumes. Public because the app constructs it at
/// delivery time (unlike the run hosts, which only the strategy's motor builds).
///
/// The `draftedWork` fact is the delivery-time mechanism restated: the needs-implementation
/// node set is SNAPSHOTTED here, at construction (before the turn), and every `factsJSON`
/// read diffs the live graph against it — so route-reply, evaluating AFTER the turn with its
/// own freshly-pinned snapshot, sees exactly what THIS turn drafted. Pre-existing drafts
/// never read as this turn's work.
@MainActor
public final class SZChatTraversalHost: SZTraversalHost {
    private let message: String
    private let resuming: Bool
    private let nodeSeed: String?
    /// Delivery context the FACTS cannot carry: a node-anchored chat's current contract and
    /// source, which the host reads off disk per delivery. Without this the coding pack's
    /// node-chat brief throws `missingDelivery` on `{{contract}}`/`{{source}}`.
    private let delivery: SZBriefDelivery
    private let renderer: SZBriefRenderer
    private let graphName: String
    private let queries: SZQueryService
    private let liveGraph: @MainActor () -> SZGraph?
    private let turn: @MainActor (SZTurnOrder) async -> SZTurnReport
    private let effect: @MainActor (String, SZMessageKind) async -> Void
    private let onNote: @MainActor (SZTraversalNote) -> Void
    /// The node ids needing implementation at DELIVERY — what `draftedWork` diffs against.
    private let draftSnapshot: Set<SZNodeID>

    public init(message: String, resuming: Bool, nodeSeed: String? = nil,
                delivery: SZBriefDelivery = SZBriefDelivery(),
                renderer: SZBriefRenderer, graphName: String, queries: SZQueryService,
                liveGraph: @escaping @MainActor () -> SZGraph?,
                turn: @escaping @MainActor (SZTurnOrder) async -> SZTurnReport,
                effect: @escaping @MainActor (String, SZMessageKind) async -> Void,
                onNote: @escaping @MainActor (SZTraversalNote) -> Void = { _ in }) {
        self.message = message
        self.resuming = resuming
        self.nodeSeed = nodeSeed
        self.delivery = delivery
        self.renderer = renderer
        self.graphName = graphName
        self.queries = queries
        self.liveGraph = liveGraph
        self.turn = turn
        self.effect = effect
        self.onNote = onNote
        self.draftSnapshot = Self.needingImplementation(liveGraph())
    }

    private static func needingImplementation(_ graph: SZGraph?) -> Set<SZNodeID> {
        Set((graph?.nodes ?? []).filter(\.needsImplementation).map(\.id))
    }

    /// The chat projection, spec-shaped plus `graphJSON` (the chat briefs re-project the
    /// live graph — see the file header for why the document is local).
    private struct ChatFactsDocument: Encodable {
        var sentMessage: String
        var resuming: Bool
        var draftedWork: Bool
        var nodeSeed: String?
        var graphJSON: String
    }

    public func factsJSON(kind: SZMessageKind) -> String {
        let graph = liveGraph()
        return SZGraphFactsEncoding.json(ChatFactsDocument(
            sentMessage: message,
            resuming: resuming,
            // Growth since delivery = THIS turn drafted (or re-briefed) work.
            draftedWork: !Self.needingImplementation(graph).subtracting(draftSnapshot).isEmpty,
            nodeSeed: nodeSeed,
            graphJSON: SZGraphFactsEncoding.graphJSON(graph)))
    }

    public func itemsFact(named name: String, kind: SZMessageKind) -> [String] {
        []   // no [String]-typed chat fact exists; the pack gate keeps dispatches off chat graphs
    }

    /// The chat briefs through the SAME renderer path the equivalence gate pins — the pack's
    /// chat templates against the live projection, byte-identical to the retired direct
    /// render calls.
    public func renderBrief(agent: String, template: String, kind: SZMessageKind) throws -> String {
        try renderer.render(agent: agent, template: template, kind: kind,
                            factsJSON: factsJSON(kind: kind), delivery: delivery)
    }

    /// One chat turn through the injected runner — the app's delivery machinery (recap,
    /// attachments, session resume, streaming, claims) all lives behind this closure.
    public func runTurn(_ order: SZTurnOrder) async -> SZTurnReport {
        await turn(order)
    }

    /// One step ask, served through the query service (render → route → complete → journal).
    public func serveAsk(agent: String, step: String, kind: SZMessageKind, factsJSON: String,
                         requestJSON: String) async throws -> String {
        try await queries.serve(agent: agent, graph: graphName, step: step, kind: kind,
                                factsJSON: factsJSON, requestJSON: requestJSON)
    }

    /// One validated step effect (`requestBuild`), relayed to the app's lane.
    public func perform(effect name: String, kind: SZMessageKind) async {
        await effect(name, kind)
    }

    public func note(_ note: SZTraversalNote) { onNote(note) }
}

// MARK: - The ITEM-bound host

/// One dispatched order's traversal host. Request assembly in `runTurn` carries every field a
/// coding turn launches with (working dir, package/cache dirs, MCP port + allowlist,
/// generation settings, the coding budgets); the session captured from the result is what a
/// `.message` turn resumes.
@MainActor
final class SZItemTraversalHost: SZTraversalHost {
    private let context: SZOrchestrationContext
    private let renderer: SZBriefRenderer
    private let order: SZDispatchOrder
    private let nodeID: SZNodeID
    private let sessions: SZGraphRunSessions
    private let registry: SZProviderRegistry
    private let graphName: String
    private let queries: SZQueryService
    private let onNote: @MainActor @Sendable (SZTraversalNote) -> Void

    init(context: SZOrchestrationContext, renderer: SZBriefRenderer, order: SZDispatchOrder,
         nodeID: SZNodeID, sessions: SZGraphRunSessions, registry: SZProviderRegistry,
         graphName: String, queries: SZQueryService,
         onNote: @escaping @MainActor @Sendable (SZTraversalNote) -> Void) {
        self.context = context
        self.renderer = renderer
        self.order = order
        self.nodeID = nodeID
        self.sessions = sessions
        self.registry = registry
        self.graphName = graphName
        self.queries = queries
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
            // captured for it (the reconcile resume); a `.spawn` turn starts cold.
            resumeSessionID: turn.session == .message ? sessions.session(for: nodeID) : nil,
            model: turn.choice.model,
            reasoningEffort: turn.choice.reasoningEffort,
            fastMode: context.generationSettings.fastMode ?? false,
            timeout: SZAgentTurnBudgets.codingTimeout,
            inactivityTimeout: SZAgentTurnBudgets.codingInactivityTimeout)
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

    /// One step ask, served through the query service (render → route → complete → journal).
    func serveAsk(agent: String, step: String, kind: SZMessageKind, factsJSON: String,
                  requestJSON: String) async throws -> String {
        try await queries.serve(agent: agent, graph: graphName, step: step, kind: kind,
                                factsJSON: factsJSON, requestJSON: requestJSON)
    }

    /// One validated step effect, relayed to the host's lane.
    func perform(effect: String, kind: SZMessageKind) async {
        await context.performEffect(effect, kind)
    }

    func note(_ note: SZTraversalNote) { onNote(note) }
}
