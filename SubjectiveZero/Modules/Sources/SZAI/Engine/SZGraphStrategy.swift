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
    let declarations: StepDeclarations
    let registry: SZProviderRegistry
    /// The trace hook — the host's future run-record feed; default no-op.
    let onNote: @MainActor @Sendable (SZTraversalNote) -> Void
    /// The settled-reply hook — the dispatch card's tally source when the record work lands.
    let onSettled: @MainActor @Sendable (SZSettledSummary) -> Void

    public init(
        packsRoot: URL,
        steps: any SZStepRunning,
        router: any SZModelRouting,
        bounds: SZThreadMachine.Bounds,
        declarations: @escaping StepDeclarations,
        registry: SZProviderRegistry = .shared,
        onNote: @escaping @MainActor @Sendable (SZTraversalNote) -> Void = { _ in },
        onSettled: @escaping @MainActor @Sendable (SZSettledSummary) -> Void = { _ in }
    ) {
        self.packsRoot = packsRoot
        self.steps = steps
        self.router = router
        self.bounds = bounds
        self.declarations = declarations
        self.registry = registry
        self.onNote = onNote
        self.onSettled = onSettled
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
        guard let buildGraph = directorPack.graph(handling: .build) else {
            throw SZGraphOrchestratorError.missingGraph(agent: directorPack.id, kind: .build)
        }
        guard let itemGraph = codingPack.graph(handling: .item) else {
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
        private let sessions = SZGraphRunSessions()
        private let directorHost: SZDirectorTraversalHost
        private var machine: SZThreadMachine

        init(strategy: SZGraphDirectorStrategy, context: SZOrchestrationContext,
             director: Role, coding: Role) {
            self.strategy = strategy
            self.context = context
            self.director = director
            self.coding = coding
            self.renderer = SZBriefRenderer(packRoot: strategy.packsRoot)
            self.machine = SZThreadMachine(bounds: strategy.bounds)
            // The same resolution the machine performs at `opened`, restated for the facts'
            // roundCap (the machine keeps its own private).
            let roundCap = min(director.graph.caps?.rounds ?? strategy.bounds.defaultRounds,
                               strategy.bounds.roundCeiling)
            self.directorHost = SZDirectorTraversalHost(
                context: context, renderer: renderer, roundCap: roundCap, onNote: strategy.onNote)
        }

        func run() async throws -> [SZNodeID: String] {
            var queue = machine.handle(.opened(
                kind: .build,
                graphRounds: director.graph.caps?.rounds,
                handlesSettled: director.graph.entry[.settled] != nil))
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
                    let engine = SZGraphEngine(
                        agent: director.agent, graph: director.graph,
                        attachments: director.attachments, host: directorHost,
                        steps: strategy.steps, router: strategy.router)
                    let result = await engine.run(kind: kind)
                    queue += machine.handle(.traversalConcluded(
                        Self.ending(of: result.conclusion), dispatch: dispatchIntent(of: result)))

                case .deliverItems(let setID, _, let orders):
                    // The target seat's one holder is the prebuilt coding role (the pack gate
                    // resolved the dispatch's seat and its item handling at load).
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
                case .amendTally:
                    continue   // the run record consumes tallies next phase; the arm stays explicit
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
            var deliveries: [(order: SZDispatchOrder, engine: SZGraphEngine?)] = []
            for order in orders {
                guard let nodeID = SZNodeID(uuidString: order.node) else {
                    deliveries.append((order, nil))
                    continue
                }
                let host = SZItemTraversalHost(
                    context: context, renderer: renderer, order: order, nodeID: nodeID,
                    sessions: sessions, registry: strategy.registry, onNote: strategy.onNote)
                deliveries.append((order, SZGraphEngine(
                    agent: coding.agent, graph: coding.graph, attachments: coding.attachments,
                    host: host, steps: strategy.steps, router: strategy.router)))
            }
            enum Land: Sendable {
                case settled(node: String, outcome: String)
                case watchdog
            }
            // Split the deliveries on the actor BEFORE the group: an order naming a non-node
            // settles instantly with the real reason (never waits out the watchdog to say what
            // is known now); the rest become the group's children.
            var runnable: [(node: String, engine: SZGraphEngine)] = []
            for delivery in deliveries {
                let node = delivery.order.node
                followOn += machine.handle(.itemDelivered(node: node, setID: setID))
                if let engine = delivery.engine {
                    runnable.append((node, engine))
                } else {
                    followOn += machine.handle(.itemSettled(
                        node: node, setID: setID,
                        outcome: "defect: '\(node)' is not a node id"))
                }
            }
            let children = runnable
            await withTaskGroup(of: Land.self) { group in
                for child in children {
                    group.addTask {
                        // The engine is MainActor-isolated; the child hops for each node step
                        // and parks off-actor for the long awaits (the provider subprocess).
                        let result = await child.engine.run(kind: .item)
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
                    switch land {
                    case .settled(let node, let outcome):
                        followOn += machine.handle(.itemSettled(node: node, setID: setID,
                                                                outcome: outcome))
                    case .watchdog:
                        followOn += machine.handle(.watchdogFired(setID: setID))
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

        /// Engine conclusion → the machine's traversal-ending vocabulary, class-preserving:
        /// a refusal stays a refusal, a defect stays a defect.
        private static func ending(of conclusion: SZTraversalConclusion) -> SZTraversalEnding {
            switch conclusion {
            case .ended: .ended
            case .failed(_, let detail): .failed(reason: detail)
            case .cancelled: .cancelled
            case .declined(_, let reason): .declined(reason: reason ?? "no reason given")
            case .defect(_, let detail): .defect(detail: detail)
            }
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
