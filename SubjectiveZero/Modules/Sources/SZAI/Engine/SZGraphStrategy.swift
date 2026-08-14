// SPDX-License-Identifier: AGPL-3.0-only
// The GRAPH Director strategy — THE orchestrator, and the first consumer of the whole
// rebuilt stack: a validated agent-pack library declares WHAT runs
// (graphs, briefs, steps), `SZThreadMachine` decides WHEN (events → commands), `SZGraphEngine`
// runs each traversal, and this file is the MOTOR between them — it executes the machine's
// commands in order and reports what it observed back as events. It fulfills the
// `SZOrchestrating` seam the host invokes at `startRun`.
//
// The split of labor, stated once:
//  - the MACHINE owns thread lifecycle (one open set, one settled reply, absorbing termination);
//  - the ENGINE owns one traversal (outcome routing, bounded edges, ok/error turns);
//  - THIS FILE only relays between them and the host context — it never routes, never retries,
//    never second-guesses an outcome. Every judgment lives in the pack or the machine.
import Foundation
import SZCore

/// Everything the graph strategy can refuse before or after driving a thread.
public enum SZGraphOrchestratorError: Error, CustomStringConvertible, Sendable {
    /// The pack library would not validate — the strategy never runs half-valid: every defect
    /// is listed so the author fixes the library in one round.
    case invalidPackLibrary(defects: [String])
    /// The seats resolved, but a seat's pack declares no graph for a kind the run needs.
    case missingGraph(agent: String, kind: SZMessageKind)
    /// The run's one traversal concluded on something other than `.ended` — surfaced as the
    /// run's failure with the graph's own words (see `Motor.conclude` for the mapping).
    case concluded(SZTraversalEnding)

    public var description: String {
        switch self {
        case .invalidPackLibrary(let defects):
            "the agent-pack library does not validate (\(defects.count) defect\(defects.count == 1 ? "" : "s")):\n"
                + defects.map { "  · \($0)" }.joined(separator: "\n")
        case .missingGraph(let agent, let kind):
            "agent '\(agent)' declares no graph handling '\(kind.rawValue)'"
        case .concluded(let ending):
            switch ending {
            case .failed(let reason): "the director run failed: \(reason)"
            case .declined(let reason): "the director graph declined the work: \(reason)"
            case .defect(let detail): "the director run hit a defect: \(detail)"
            case .ended: "the run ended"          // never thrown — `.ended` returns
            case .cancelled: "the run was cancelled"   // never thrown — maps to CancellationError
            }
        }
    }
}

public struct SZGraphDirectorStrategy: SZOrchestrating {
    /// The step-declaration seam (`SZStepProviding`-shaped): what each compiled step declared,
    /// for pack validation and for attaching declared outcomes to the graphs' step nodes.
    /// Injected as a closure so the host can put its keyed step runtime behind it while tests
    /// script declarations without a compiler.
    public typealias StepDeclarations =
        @Sendable (_ agent: String, _ step: String) async throws -> SZStepDeclarationInfo?

    let packsRoot: URL
    let steps: any SZStepRunning
    let router: any SZModelRouting
    let bounds: SZThreadMachine.Bounds
    /// The build STRATEGY this run asked for, verbatim (env > the persisted choice). It is
    /// no longer a graph name: it rides into the build facts as `runVariant`, and the
    /// director's own strategy step decides what it means — so an unknown name falls back
    /// inside the pack rather than being second-guessed here.
    let variant: String?
    let declarations: StepDeclarations
    let registry: SZProviderRegistry
    // The observation hooks — the host's RUNS-record feed, all defaulting to no-ops so
    // headless callers construct nothing. One traversal's life reaches its observer as
    // `onTraversal` (it began, with its identity), a stream of `onNote`s keyed by the
    // sighting's id, and exactly one `onConcluded`; a dispatch visit's live tally rides
    // traversal's settlement counts as its set's items land (the machine's own numbers),
    // and `onSettled` hands over each set's one settled reply verbatim.
    let onTraversal: @MainActor @Sendable (SZTraversalSighting) -> Void
    let onNote: @MainActor @Sendable (UUID, SZTraversalNote) -> Void
    let onConcluded: @MainActor @Sendable (UUID, SZTraversalEnding) -> Void
    let onSettled: @MainActor @Sendable (SZSettledSummary) -> Void
    /// One record per served step ask — the query service's journal, exposed live (the
    /// service also keeps the run's full list in memory; the host can persist from here).
    let onQuery: @MainActor @Sendable (SZQueryRecord) -> Void

    public init(
        packsRoot: URL,
        steps: any SZStepRunning,
        router: any SZModelRouting,
        bounds: SZThreadMachine.Bounds,
        variant: String? = nil,
        declarations: @escaping StepDeclarations,
        registry: SZProviderRegistry = .shared,
        onTraversal: @escaping @MainActor @Sendable (SZTraversalSighting) -> Void = { _ in },
        onNote: @escaping @MainActor @Sendable (UUID, SZTraversalNote) -> Void = { _, _ in },
        onConcluded: @escaping @MainActor @Sendable (UUID, SZTraversalEnding) -> Void = { _, _ in },
        onSettled: @escaping @MainActor @Sendable (SZSettledSummary) -> Void = { _ in },
        onQuery: @escaping @MainActor @Sendable (SZQueryRecord) -> Void = { _ in }
    ) {
        self.packsRoot = packsRoot
        self.steps = steps
        self.router = router
        self.bounds = bounds
        self.variant = variant
        self.declarations = declarations
        self.registry = registry
        self.onTraversal = onTraversal
        self.onNote = onNote
        self.onConcluded = onConcluded
        self.onSettled = onSettled
        self.onQuery = onQuery
    }

    @MainActor
    @discardableResult
    public func run(_ context: SZOrchestrationContext) async throws -> [SZNodeID: String] {
        // Load + validate the WHOLE library before anything runs — a defective pack root throws
        // loudly with every defect listed; a half-valid library never dispatches a token.
        let loaded = SZAgentPackLoader.load(root: packsRoot)
        var defects = loaded.defects
        defects += await SZAgentPackLoader.validate(
            packs: loaded.packs, steps: DeclarationRelay(declarations: declarations))
        guard defects.isEmpty else {
            throw SZGraphOrchestratorError.invalidPackLibrary(
                defects: defects.map(\.description).sorted())
        }
        // Seats resolve after validation by construction (unfilled/contested are defects) —
        // the guard stays for the honest error, not as a live branch.
        guard let directorID = loaded.seats.director, let codingID = loaded.seats.coding,
              let directorPack = loaded.packs.first(where: { $0.id == directorID }),
              let codingPack = loaded.packs.first(where: { $0.id == codingID }) else {
            throw SZGraphOrchestratorError.invalidPackLibrary(defects: ["the seats did not resolve"])
        }
        guard let buildGraph = directorPack.graph(routing: .build) else {
            throw SZGraphOrchestratorError.missingGraph(agent: directorPack.id, kind: .build)
        }
        guard let workGraph = codingPack.graph(routing: .work) else {
            throw SZGraphOrchestratorError.missingGraph(agent: codingPack.id, kind: .work)
        }
        let motor = Motor(
            strategy: self, context: context,
            director: Role(agent: directorPack.id, graph: buildGraph,
                           attachments: try await attachments(of: directorPack, graph: buildGraph)),
            coding: Role(agent: codingPack.id, graph: workGraph,
                         attachments: try await attachments(of: codingPack, graph: workGraph)))
        return try await motor.run()
    }

    /// Declared outcomes per step node, attached at load — what the engine checks a step's
    /// answer against. Validation already proved every wired outcome is declared.
    private func attachments(of pack: SZAgentPack,
                             graph: SZAgentGraph) async throws -> [String: SZStepAttachment] {
        var attached: [String: SZStepAttachment] = [:]
        for node in graph.nodes {
            guard case .step(let name) = node.form else { continue }
            if let info = try await declarations(pack.id, name) {
                attached[node.id] = SZStepAttachment(outcomes: Set(info.outcomes))
            }
        }
        return attached
    }

    /// The loader's `SZStepProviding` seam over the injected declarations closure.
    private struct DeclarationRelay: SZStepProviding {
        let declarations: StepDeclarations
        func declaration(agent: String, step: String) async throws -> SZStepDeclarationInfo? {
            try await declarations(agent, step)
        }
    }

    /// One seat's runnable half: the agent id, the graph a delivery enters, and its step
    /// nodes' attached declarations.
    struct Role {
        let agent: String
        let graph: SZAgentGraph
        let attachments: [String: SZStepAttachment]
    }
}

// MARK: - The motor

extension SZGraphDirectorStrategy {
    /// The engine's fleet-side host: the run is ONE traversal now, and this class exists
    /// to (a) build the director's engine and (b) fulfil the `deliver` seam that engine's
    /// dispatch node awaits — supervising each set through `SZThreadMachine` and running
    /// the item traversals in a task group raced by the machine's watchdog. It never
    /// routes, never retries, never second-guesses an outcome: every judgment lives in
    /// the pack or the machine.
    @MainActor
    private final class Motor {
        private let strategy: SZGraphDirectorStrategy
        private let context: SZOrchestrationContext
        private let director: Role
        private let coding: Role
        private let renderer: SZBriefRenderer
        private let queries: SZQueryService
        private let sessions = SZGraphRunSessions()
        private let directorHost: SZDirectorTraversalHost
        private var machine: SZThreadMachine
        /// The run's one director sighting — boxed only because the host is built in
        /// `init` (before `self` exists) and its note closure needs the id.
        private let directorSighting = SightingBox()
        /// Steers raised while a fleet was out, drained continuously and folded into the
        /// traversal's NEXT brief render via `directorHost.begin`.
        private var pendingSteers: [String] = []

        @MainActor
        private final class SightingBox { var id = UUID() }

        init(strategy: SZGraphDirectorStrategy, context: SZOrchestrationContext,
             director: Role, coding: Role) {
            self.strategy = strategy
            self.context = context
            self.director = director
            self.coding = coding
            self.renderer = SZBriefRenderer(packRoot: strategy.packsRoot)
            // ONE query service per run: every host's `serveAsk` funnels through it, so the
            // journal is the run's whole ask history. The context's executor (tests) wins;
            // nil runs the routed provider directly — production's path.
            self.queries = SZQueryService(
                renderer: renderer, router: strategy.router, registry: strategy.registry,
                cacheDirectory: context.cacheDirectory, runner: context.runner,
                executor: context.queryExecutor, onRecord: strategy.onQuery)
            self.machine = SZThreadMachine(bounds: strategy.bounds)
            // The reconcile brief's {{cap}}: the settled edge's leash IS the retry budget,
            // so the cap the prose states is read off the graph, one home.
            let roundCap = Self.retryCap(of: director.graph)
            let box = directorSighting
            let note = strategy.onNote
            self.directorHost = SZDirectorTraversalHost(
                context: context, renderer: renderer, roundCap: roundCap,
                graphName: director.graph.name, queries: queries,
                runVariant: strategy.variant ?? "",
                onNote: { note(box.id, $0) })
        }

        /// The largest leash on any dispatch node's settled edge — what the reconcile
        /// brief's {{cap}} reads. 0 when no dispatch loops (procedural never reconciles,
        /// so the value is never rendered).
        private static func retryCap(of graph: SZAgentGraph) -> Int {
            graph.edges.filter { edge in
                guard edge.outcome == "settled",
                      case .dispatch = graph.node(edge.from)?.form else { return false }
                return true
            }.compactMap(\.maxTraversals).max() ?? 0
        }

        func run() async throws -> [SZNodeID: String] {
            directorHost.begin(round: 0, steers: [])
            directorHost.fleet = { [weak self] orders, seat, progress in
                await self?.deliver(orders: orders, to: seat, progress: progress) ?? nil
            }
            strategy.onTraversal(SZTraversalSighting(
                id: directorSighting.id, agent: director.agent,
                graphName: director.graph.name, kind: .build))
            let engine = SZGraphEngine(
                agent: director.agent, graph: director.graph,
                attachments: director.attachments, host: directorHost,
                steps: strategy.steps, router: strategy.router)
            let result = await engine.run(kind: .build)
            strategy.onConcluded(directorSighting.id, SZTraversalEnding(result.conclusion))
            return try conclude(result.conclusion)
        }

        // MARK: - The deliver seam (what the dispatch node awaits)

        /// One dispatch set, supervised end to end: the machine mints it, every order's
        /// item traversal runs concurrently, each landing feeds `itemSettled`, and the
        /// machine's watchdog races the group. Returns the set's one summary — or nil on
        /// stop, which the engine's cancellation boundary turns into `.cancelled`.
        private func deliver(orders workOrders: [SZWorkOrder], to seat: String,
                             progress: @escaping @MainActor @Sendable (SZAgentGraphRun.Tally) -> Void)
            async -> SZSettledSummary? {
            // The Director's authored notes drained AT THE SEND, so a note authored during
            // the traversal rides the orders it aimed at (the machine stamps them in).
            var notes: [String: String] = [:]
            for (node, text) in context.takeDirectorMessages() {
                notes[node.uuidString] = text
            }
            let minted = machine.handle(.dispatched(SZDispatchIntent(
                target: seat, items: workOrders.map(\.node), notes: notes)))
            var orders: [SZDispatchOrder] = []
            var deadline: Duration?
            var setID: Int?
            for command in minted {
                switch command {
                case .deliverItems(let id, _, let sent): setID = id; orders = sent
                case .armWatchdog(_, let after): deadline = after
                default: break
                }
            }
            guard let setID else {
                // An empty dispatch (the gate before it should prevent this) settles
                // instantly and honestly rather than parking the traversal.
                return SZSettledSummary(setID: 0, from: seat, outcomes: [:],
                                        round: machine.round)
            }
            // The same moment the frozen dispatch granted freshly-declared entitlements:
            // before the fleet runs, so a promoted node's setup sees its permission.
            await context.grantPermissions()

            // Engines are built on the actor; the group's children capture Sendables only.
            var deliveries: [(order: SZDispatchOrder, engine: SZGraphEngine?, sighting: UUID)] = []
            for order in orders {
                let sighting = UUID()
                guard let nodeID = SZNodeID(uuidString: order.node) else {
                    deliveries.append((order, nil, sighting))
                    continue
                }
                // Each item traversal announces itself and keys its notes to its own
                // sighting — parallel items interleave on the main actor, and the id is
                // what un-shuffles them into per-record traces.
                let note = strategy.onNote
                let host = SZWorkTraversalHost(
                    context: context, renderer: renderer, order: order, nodeID: nodeID,
                    sessions: sessions, registry: strategy.registry,
                    graphName: coding.graph.name, queries: queries,
                    onNote: { note(sighting, $0) })
                deliveries.append((order, SZGraphEngine(
                    agent: coding.agent, graph: coding.graph, attachments: coding.attachments,
                    host: host, steps: strategy.steps, router: strategy.router), sighting))
            }
            enum Land: Sendable {
                case settled(node: String, outcome: String)
                case watchdog
            }
            // Split the deliveries on the actor BEFORE the group: an order naming a
            // non-node settles instantly with the real reason (never waits out the
            // watchdog to say what is known now); the rest become the group's children.
            var summary: SZSettledSummary?
            func absorb(_ commands: [SZThreadMachine.Command]) {
                for command in commands {
                    switch command {
                    case .amendTally(_, let settled, let total, let failed):
                        // Relayed the moment each item lands — the dispatch card counts
                        // up while the fleet works instead of jumping to its final value.
                        progress(SZAgentGraphRun.Tally(settled: settled, total: total,
                                                       failed: failed))
                    case .settled(let landed):
                        summary = landed
                        strategy.onSettled(landed)
                    case .deliverItems, .armWatchdog, .cancelItems:
                        break   // delivery/timers/cancellation live in this function's group
                    }
                }
            }
            var runnable: [(node: String, sighting: UUID, engine: SZGraphEngine)] = []
            for delivery in deliveries {
                let node = delivery.order.node
                absorb(machine.handle(.workDelivered(node: node, setID: setID)))
                if let engine = delivery.engine {
                    strategy.onTraversal(SZTraversalSighting(
                        id: delivery.sighting, agent: coding.agent,
                        graphName: coding.graph.name, kind: .work, work: node))
                    runnable.append((node, delivery.sighting, engine))
                } else {
                    absorb(machine.handle(.workSettled(
                        node: node, setID: setID,
                        outcome: "defect: '\(node)' is not a node id")))
                }
            }
            if runnable.isEmpty {
                // Every order settled synchronously — the group would hold only the
                // sleeping watchdog, stalling a set that already closed.
                return finish(summary)
            }
            let children = runnable
            let concluded = strategy.onConcluded
            await withTaskGroup(of: Land.self) { group in
                for child in children {
                    group.addTask {
                        // The engine is MainActor-isolated; the child hops for each node
                        // step and parks off-actor for the long awaits (the provider).
                        let result = await child.engine.run(kind: .work)
                        await concluded(child.sighting, SZTraversalEnding(result.conclusion))
                        return .settled(node: child.node,
                                        outcome: Self.workOutcome(of: result.conclusion))
                    }
                }
                if let deadline {
                    group.addTask {
                        try? await Task.sleep(for: deadline)
                        // Fed even when cancelled at set closure — a closed set absorbs
                        // it, so correctness never depends on the cancel landing.
                        return .watchdog
                    }
                }
                for await land in group {
                    // A stop: sweep the set and bail — the engine's cancellation boundary
                    // owns the traversal's ending; no summary is synthesized.
                    if Task.isCancelled {
                        absorb(machine.handle(.stopRequested))
                        group.cancelAll()
                        continue
                    }
                    // Steers the fleet raised while out (coding agents' messages to the
                    // Director) fold into the traversal's NEXT brief — drained
                    // continuously so nothing waits for the set to close.
                    pendingSteers += context.takeDirectorInbox()
                    switch land {
                    case .settled(let node, let outcome):
                        absorb(machine.handle(.workSettled(node: node, setID: setID,
                                                           outcome: outcome)))
                    case .watchdog:
                        absorb(machine.handle(.watchdogFired(setID: setID)))
                    }
                    // The set closed (collected, synthesized, or stopped): cancel what
                    // remains — the stragglers the machine ordered cancelled and the
                    // sleeping watchdog. Their late lands are fed and absorbed.
                    if case .awaitingFleet = machine.state {} else { group.cancelAll() }
                }
            }
            return finish(summary)
        }

        /// The set is over: advance the traversal's world — the round the reconcile brief
        /// states, and the steers its {{inbox}} folds — before the engine walks on.
        private func finish(_ summary: SZSettledSummary?) -> SZSettledSummary? {
            let drained = pendingSteers
            pendingSteers = []
            directorHost.begin(round: machine.round, steers: drained)
            return summary
        }

        /// The run's one ending, mapped to the seam's contract: `.ended` returns the
        /// sessions, a stop maps to `CancellationError` (the same shape a cancelled
        /// provider turn surfaces), and everything else throws with the graph's words.
        private func conclude(_ conclusion: SZTraversalConclusion) throws -> [SZNodeID: String] {
            switch conclusion {
            case .ended:
                return sessions.byNode
            case .cancelled:
                throw CancellationError()
            case .failed, .declined, .defect:
                throw SZGraphOrchestratorError.concluded(SZTraversalEnding(conclusion))
            }
        }

        /// A work traversal's conclusion as its terminal outcome string — the dispatch
        /// card's rule reads anything not `ok`-prefixed as a failure, so every non-ended
        /// class carries its detail. Nonisolated: computed by the delivery's children.
        private nonisolated static func workOutcome(of conclusion: SZTraversalConclusion) -> String {
            switch conclusion {
            case .ended: "ok"
            case .failed(_, let detail): "error: \(detail)"
            case .cancelled: "cancelled"
            case .declined(_, let reason): reason.map { "declined: \($0)" } ?? "declined"
            case .defect(_, let detail): "defect: \(detail)"
            }
        }
    }
}
