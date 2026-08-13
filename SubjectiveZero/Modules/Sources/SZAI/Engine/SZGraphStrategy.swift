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
    /// The thread concluded on something other than `.ended` — surfaced as the run's failure
    /// with the machine's own words (see `Motor.conclude` for the mapping rationale).
    case concluded(SZThreadConclusion)

    public var description: String {
        switch self {
        case .invalidPackLibrary(let defects):
            "the agent-pack library does not validate (\(defects.count) defect\(defects.count == 1 ? "" : "s")):\n"
                + defects.map { "  · \($0)" }.joined(separator: "\n")
        case .missingGraph(let agent, let kind):
            "agent '\(agent)' declares no graph handling '\(kind.rawValue)'"
        case .concluded(let conclusion):
            switch conclusion {
            case .failed(let reason): "the director thread failed: \(reason)"
            case .declined(let reason): "the director graph declined the work: \(reason)"
            case .defect(let detail): "the director thread hit a defect: \(detail)"
            case .roundCeiling(let round): "the host round ceiling ended the thread at round \(round)"
            case .ended: "the thread ended"          // never thrown — `.ended` returns
            case .cancelled: "the thread was cancelled"   // never thrown — maps to CancellationError
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
    // sighting's id, and exactly one `onConcluded`; `onTally` amends a dispatching
    // traversal's settlement counts as its set's items land (the machine's own numbers),
    // and `onSettled` hands over each set's one settled reply verbatim.
    let onTraversal: @MainActor @Sendable (SZTraversalSighting) -> Void
    let onNote: @MainActor @Sendable (UUID, SZTraversalNote) -> Void
    let onConcluded: @MainActor @Sendable (UUID, SZTraversalEnding) -> Void
    let onTally: @MainActor @Sendable (UUID, _ settled: Int, _ total: Int, _ failed: Int) -> Void
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
        onTally: @escaping @MainActor @Sendable (UUID, Int, Int, Int) -> Void = { _, _, _, _ in },
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
        self.onTally = onTally
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
        guard let itemGraph = codingPack.graph(routing: .item) else {
            throw SZGraphOrchestratorError.missingGraph(agent: codingPack.id, kind: .item)
        }
        let motor = Motor(
            strategy: self, context: context,
            director: Role(agent: directorPack.id, graph: buildGraph,
                           attachments: try await attachments(of: directorPack, graph: buildGraph)),
            coding: Role(agent: codingPack.id, graph: itemGraph,
                         attachments: try await attachments(of: codingPack, graph: itemGraph)))
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
    /// The machine's motor: executes the returned commands in order and feeds what it observed
    /// back as events — that is the machine's entire contract, and this class adds nothing to
    /// it. One instance per run; the command queue is a plain array because everything here is
    /// MainActor-sequential (concurrency lives only inside one set's item delivery).
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
        /// The CURRENT director traversal's sighting id, boxed: the director host is built
        /// once in `init` (before `self` exists) but observed per traversal, so its note
        /// closure reads the box the motor restamps at each `startTraversal`.
        private let directorSighting = SightingBox()
        /// Dispatch set → the sighting of the traversal that SENT it, so a tally amendment
        /// lands on the record of the sender (which sealed long before the set settles).
        private var sendingBySet: [Int: UUID] = [:]

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
            // The same resolution the machine performs at `opened`, restated for the facts'
            // roundCap (the machine keeps its own private).
            let roundCap = min(director.graph.caps?.rounds ?? strategy.bounds.defaultRounds,
                               strategy.bounds.roundCeiling)
            let box = directorSighting
            let note = strategy.onNote
            self.directorHost = SZDirectorTraversalHost(
                context: context, renderer: renderer, roundCap: roundCap,
                graphName: director.graph.name, queries: queries,
                runVariant: strategy.variant ?? "",
                onNote: { note(box.id, $0) })
        }

        func run() async throws -> [SZNodeID: String] {
            var queue = machine.handle(.opened(
                kind: .build,
                graphRounds: director.graph.caps?.rounds,
                handlesSettled: director.graph.handles(.settled)))
            var index = 0
            while index < queue.count {
                // The Stop path: cancelling the run task becomes a `stopRequested` event, so
                // the machine — not the motor — decides how a stop settles. Absorbing after
                // conclusion, so checking every iteration is idempotent.
                if Task.isCancelled {
                    queue += machine.handle(.stopRequested)
                }
                let command = queue[index]
                index += 1
                switch command {
                case .startTraversal(let kind, let round, let steers):
                    // A traversal queued by a world a stop has since ended is skipped — the
                    // machine already shipped the ending with the stop's commands.
                    guard case .traversing = machine.state else { continue }
                    directorHost.begin(round: round, steers: steers)
                    // Announce the traversal before it runs — its notes key to this id.
                    directorSighting.id = UUID()
                    strategy.onTraversal(SZTraversalSighting(
                        id: directorSighting.id, agent: director.agent,
                        graphName: director.graph.name, kind: kind))
                    let engine = SZGraphEngine(
                        agent: director.agent, graph: director.graph,
                        attachments: director.attachments, host: directorHost,
                        steps: strategy.steps, router: strategy.router)
                    let result = await engine.run(kind: kind)
                    let ending = Self.ending(of: result.conclusion)
                    strategy.onConcluded(directorSighting.id, ending)
                    queue += machine.handle(.traversalConcluded(
                        ending, dispatch: dispatchIntent(of: result)))

                case .deliverItems(let setID, _, let orders):
                    // The same guard `.startTraversal` carries: a stop can conclude the
                    // thread while this command still sits in the queue, and delivering
                    // then would grant entitlements (a system dialog AFTER Stop) and open
                    // records that seal cancelled the instant they exist.
                    guard case .awaitingFleet = machine.state else { continue }
                    // The target seat's one holder is the prebuilt coding role (the pack gate
                    // resolved the dispatch's seat and its item handling at load).
                    // A set is minted by the traversal that just concluded — remember its
                    // sighting so the set's later tally amendments land on that record.
                    sendingBySet[setID] = directorSighting.id
                    // The set's watchdog rides the same command list — pick it up here so it
                    // races the delivery instead of waiting behind it.
                    let deadline = queue[index...].lazy.compactMap { command -> Duration? in
                        if case .armWatchdog(let armed, let after) = command, armed == setID {
                            return after
                        }
                        return nil
                    }.first
                    queue += await deliver(orders: orders, setID: setID, watchdog: deadline)

                case .armWatchdog:
                    continue   // consumed by `deliverItems` above (raced inside the delivery)
                case .cancelItems:
                    continue   // items are children of the delivery's task group — cancelled there
                case .amendTally(let setID, let settled, let total, let failed):
                    // The machine's live count for the set — on every settle and timeout —
                    // relayed to the SENDING traversal's record (the sanctioned post-seal
                    // amend: the sender concluded long before its set settles).
                    if let sender = sendingBySet[setID] {
                        strategy.onTally(sender, settled, total, failed)
                    }
                case .deliverSettled(let summary):
                    // The settled re-entry reads LIVE context (build facts by design), so the
                    // reply itself only feeds the observer hook here.
                    strategy.onSettled(summary)
                case .cancelTraversal:
                    // The motor is sequential: a traversal in flight is the one being awaited,
                    // and the run task's cancellation already propagates into it (the engine
                    // concludes `.cancelled` at its next node boundary). Nothing to cancel here.
                    continue
                case .conclude(let conclusion, _):
                    return try conclude(conclusion)
                }
            }
            // Unreachable by the machine's contract (every thread emits exactly one conclude);
            // refusing to guess beats returning half-truth.
            throw SZGraphOrchestratorError.concluded(.defect(detail: "the machine never concluded"))
        }

        // MARK: - Command execution

        /// One dispatch set, delivered: every order's item traversal runs concurrently, each
        /// landing feeds `itemSettled`, and the machine's watchdog races the group. Returns the
        /// follow-on commands the fed events produced (the settled reply + re-entry, or the
        /// thread's conclusion).
        private func deliver(orders: [SZDispatchOrder], setID: Int,
                             watchdog deadline: Duration?) async -> [SZThreadMachine.Command] {
            // The same moment the frozen dispatch granted freshly-declared entitlements: before
            // the fleet runs, so a promoted node's setup sees its permission determined.
            await context.grantPermissions()
            var followOn: [SZThreadMachine.Command] = []
            // Engines are built on the actor; the group's children capture only Sendable values.
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
                let host = SZItemTraversalHost(
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
            // Split the deliveries on the actor BEFORE the group: an order naming a non-node
            // settles instantly with the real reason (never waits out the watchdog to say what
            // is known now); the rest become the group's children.
            var runnable: [(node: String, sighting: UUID, engine: SZGraphEngine)] = []
            for delivery in deliveries {
                let node = delivery.order.node
                followOn += machine.handle(.itemDelivered(node: node, setID: setID))
                if let engine = delivery.engine {
                    strategy.onTraversal(SZTraversalSighting(
                        id: delivery.sighting, agent: coding.agent,
                        graphName: coding.graph.name, kind: .item, item: node))
                    runnable.append((node, delivery.sighting, engine))
                } else {
                    followOn += machine.handle(.itemSettled(
                        node: node, setID: setID,
                        outcome: "defect: '\(node)' is not a node id"))
                }
            }
            // Nothing runnable (every order settled synchronously): the group would hold
            // only the sleeping watchdog, and the drain loop cannot cancel it until it
            // yields — a 17-minute stall for a set that already closed.
            guard !runnable.isEmpty else { return followOn }
            let children = runnable
            let concluded = strategy.onConcluded
            await withTaskGroup(of: Land.self) { group in
                for child in children {
                    group.addTask {
                        // The engine is MainActor-isolated; the child hops for each node step
                        // and parks off-actor for the long awaits (the provider subprocess).
                        let result = await child.engine.run(kind: .item)
                        await concluded(child.sighting, Self.ending(of: result.conclusion))
                        return .settled(node: child.node,
                                        outcome: Self.itemOutcome(of: result.conclusion))
                    }
                }
                if let deadline {
                    group.addTask {
                        try? await Task.sleep(for: deadline)
                        // Fed even when cancelled at set closure — a closed set absorbs it, so
                        // correctness never depends on the cancel landing (the machine's rule).
                        return .watchdog
                    }
                }
                for await land in group {
                    // Steers the fleet raised while out (coding agents' messages to the
                    // Director) fold into the NEXT traversal's brief — drained continuously so
                    // nothing waits for the set to close.
                    for steer in context.takeDirectorInbox() {
                        followOn += machine.handle(.absorbSteer(steer))
                    }
                    let landed: [SZThreadMachine.Command]
                    switch land {
                    case .settled(let node, let outcome):
                        landed = machine.handle(.itemSettled(node: node, setID: setID,
                                                             outcome: outcome))
                    case .watchdog:
                        landed = machine.handle(.watchdogFired(setID: setID))
                    }
                    // Tallies are relayed HERE, as each item lands — the dispatch card
                    // counts up while the fleet works. Draining them at the end (with the
                    // rest of the follow-on queue) would jump the card from nothing to its
                    // final value, which is what the live amend exists to avoid.
                    for command in landed {
                        if case .amendTally(let set, let settled, let total, let failed) = command,
                           let sender = sendingBySet[set] {
                            strategy.onTally(sender, settled, total, failed)
                        } else {
                            followOn.append(command)
                        }
                    }
                    // The set closed (collected, synthesized, or stopped): cancel what remains —
                    // the stragglers the machine ordered cancelled and the sleeping watchdog.
                    // Their late lands are fed and absorbed.
                    if case .awaitingFleet = machine.state {} else { group.cancelAll() }
                }
            }
            return followOn
        }

        /// The thread's one ending, mapped to the seam's contract. The frozen path throws
        /// whenever the run cannot do its job (unknown provider, no project); a thread that
        /// failed / declined / defected / hit the ceiling is the graph-world equivalent, so it
        /// throws with the machine's own words — and a stop maps to `CancellationError`, the
        /// same shape a cancelled provider turn surfaces from the frozen strategies. Only
        /// `.ended` returns the run's sessions.
        private func conclude(_ conclusion: SZThreadConclusion) throws -> [SZNodeID: String] {
            switch conclusion {
            case .ended:
                return sessions.byNode
            case .cancelled:
                throw CancellationError()
            case .failed, .declined, .defect, .roundCeiling:
                throw SZGraphOrchestratorError.concluded(conclusion)
            }
        }

        // MARK: - Observation mapping

        /// A concluding traversal's dispatch decision, with the Director's authored notes
        /// drained AT THE SEND so a note authored during the traversal rides the orders it
        /// aimed at (the machine stamps them into the orders).
        private func dispatchIntent(of result: SZTraversalResult) -> SZDispatchIntent? {
            guard let target = result.sentTarget else { return nil }
            var notes: [String: String] = [:]
            for (node, text) in context.takeDirectorMessages() {
                notes[node.uuidString] = text
            }
            return SZDispatchIntent(target: target, items: result.sent.map(\.node), notes: notes)
        }

        /// Engine conclusion → the machine's traversal-ending vocabulary. One home:
        /// `SZTraversalEnding.init(_:)`, so every caller maps identically.
        private nonisolated static func ending(of conclusion: SZTraversalConclusion) -> SZTraversalEnding {
            SZTraversalEnding(conclusion)
        }

        /// An item traversal's conclusion as its terminal outcome string — the dispatch card's
        /// rule reads anything not `ok`-prefixed as a failure, so every non-ended class carries
        /// its detail. Nonisolated: computed by the delivery's off-actor children.
        private nonisolated static func itemOutcome(of conclusion: SZTraversalConclusion) -> String {
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
