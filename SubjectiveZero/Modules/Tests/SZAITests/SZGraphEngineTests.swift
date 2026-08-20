// SPDX-License-Identifier: AGPL-3.0-only
// The traversal engine driven end-to-end through stub seams — the real engine, never a
// replica: the door step deciding the route, outcome routing, the turn's ok/error-only
// contract, the waiting dispatch, bounded edges as leashes, declined-is-not-failure,
// cancellation, and every defect arm.
import Testing
import Foundation
@testable import SZAI
@testable import SZCore

// MARK: - Stub seams

private let nodeA = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
private let nodeB = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!

@MainActor
private final class StubHost: SZTraversalServing {
    /// The delivery's facts — the run's work set is what a dispatch sends.
    var factsValue = SZFacts(message: "hello",
                             run: SZRun(workSet: [nodeA, nodeB], round: 0, roundCap: 0,
                                        steers: [], instruction: ""))
    var turnReports: [SZTurnReport] = []
    var turnsSeen: [SZTurnOrder] = []
    var notes: [SZTraversalNote] = []
    var askReply = "scripted-reply"
    var asksSeen: [(step: String, request: String)] = []
    var performed: [SZEffect] = []
    /// Everything the host was asked to DO, in arrival order — what pins effects-before-
    /// edge-routing (a perform must land before the next node's turn).
    var events: [String] = []

    func facts() -> SZFacts { factsValue }
    func render(template: String) throws -> String { "rendered:" + template }
    func runTurn(_ order: SZTurnOrder) async -> SZTurnReport {
        turnsSeen.append(order)
        events.append("turn:\(order.brief)")
        return turnReports.isEmpty ? SZTurnReport(failed: false) : turnReports.removeFirst()
    }
    func serveAsk(step: String, slot: String?, requestJSON: String) async throws -> String {
        asksSeen.append((step, requestJSON))
        return askReply
    }
    func perform(effect: SZEffect) async {
        performed.append(effect)
        events.append("perform:\(effect.rawValue)")
    }
    /// The fleet, scripted: each deliver consumes the next summary (nil = a host that
    /// cannot dispatch), relays the scripted tallies through `progress` first, and records
    /// what was sent.
    var summaries: [SZSettledSummary?] = []
    var progressTallies: [SZAgentGraphRun.Tally] = []
    var delivered: [(orders: [SZWorkOrder], seat: String)] = []
    func deliver(orders: [SZWorkOrder], to seat: String,
                 progress: @escaping @MainActor @Sendable (SZAgentGraphRun.Tally) -> Void)
        async -> SZSettledSummary? {
        delivered.append((orders, seat))
        events.append("deliver:\(seat):\(orders.map(\.node).joined(separator: ","))")
        for tally in progressTallies { progress(tally) }
        return summaries.isEmpty ? nil : summaries.removeFirst()
    }
    func note(_ note: SZTraversalNote) { notes.append(note) }
}

/// Scripted step answers, keyed by step name; missing key = a failure report. A step whose
/// key maps to `.ask` invokes the engine-provided ask closure and answers with its reply.
private final class StubSteps: SZStepRunning, @unchecked Sendable {
    enum Script: Sendable {
        case report(SZStepReport)
        /// One report per VISIT, in order; the last repeats past the script's end.
        case reports([SZStepReport])
        /// Call the ask closure with `request` and answer with whatever comes back.
        case ask(request: String)
    }

    private var scripts: [String: Script]

    init(answers: [String: SZStepReport]) {
        scripts = answers.mapValues { .report($0) }
    }

    init(scripts: [String: Script]) {
        self.scripts = scripts
    }

    func evaluate(agent: String, step: String, factsJSON: String,
                  ask: @escaping @Sendable (String) async throws -> String) async -> SZStepReport {
        switch scripts[step] {
        case .report(let report): return report
        case .reports(let queue):
            let head = queue.first ?? SZStepReport(failure: "script exhausted for \(step)")
            if queue.count > 1 { scripts[step] = .reports(Array(queue.dropFirst())) }
            return head
        case .ask(let request):
            do { return SZStepReport(outcome: try await ask(request)) }
            catch { return SZStepReport(failure: String(describing: error)) }
        case nil: return SZStepReport(failure: "no scripted answer for \(step)")
        }
    }
}

private let identityRouter = SZIdentityRouter(
    choice: SZModelChoice(providerID: "stub", model: nil, reasoningEffort: nil))

/// door(step) → plan(turn) → work-left(step yes/no) → implement(dispatch); no→unblock(turn)
/// loops back across a bounded edge — the shipped build lane's shape.
private func makeBuildGraph() -> SZAgentGraph {
    SZAgentGraph(
        nodes: [
            .init(id: SZAgentGraph.doorID, form: .step(name: "door")),
            .init(id: "plan", form: .turn(.init(brief: "decompose"))),
            .init(id: "work-left", form: .step(name: "work-left")),
            .init(id: "unblock", form: .turn(.init(brief: "unblock"))),
            .init(id: "implement", form: .dispatch(.init(to: "coding"))),
        ],
        edges: [
            .init(from: SZAgentGraph.doorID, outcome: "build", to: "plan"),
            .init(from: "plan", outcome: "ok", to: "work-left"),
            .init(from: "work-left", outcome: "yes", to: "implement"),
            .init(from: "work-left", outcome: "no", to: "unblock", maxTraversals: 2),
            .init(from: "unblock", outcome: "ok", to: "work-left"),
        ])
}

private let buildAttachments = [
    SZAgentGraph.doorID: SZStepAttachment(outcomes: ["build", "answer"]),
    "work-left": SZStepAttachment(outcomes: ["yes", "no"]),
]

/// Every step scripted for the plain build path: the door routes build, the gate says yes.
private func buildScripts(workLeft: StubSteps.Script = .report(SZStepReport(outcome: "yes")))
    -> [String: StubSteps.Script] {
    ["door": .report(SZStepReport(outcome: "build")), "work-left": workLeft]
}

@MainActor
private func makeEngine(graph: SZAgentGraph = makeBuildGraph(),
                        attachments: [String: SZStepAttachment] = buildAttachments,
                        host: StubHost, steps: StubSteps) -> SZGraphEngine {
    SZGraphEngine(agent: "director", graph: graph, attachments: attachments,
                  host: host, steps: steps, router: identityRouter)
}

// MARK: - Tests

@MainActor
struct SZGraphEngineTests {

    @Test func aBuildTraversalAwaitsItsFleetAndEndsAtTheUnwiredSettled() async throws {
        let host = StubHost()
        host.summaries = [SZSettledSummary(setID: 1, from: "coding",
                                           outcomes: [nodeA.uuidString: "ok",
                                                      nodeB.uuidString: "ok"], round: 1)]
        let engine = makeEngine(host: host, steps: StubSteps(scripts: buildScripts()))
        let result = await engine.run()

        // The dispatch WAITED: the summary landed inside the traversal, and — with no
        // settled edge wired in this fixture — settlement IS the honest ending.
        #expect(result.conclusion == .ended(node: "implement", outcome: "settled"))
        #expect(host.delivered.count == 1)
        #expect(host.delivered[0].seat == "coding")
        // The orders are the run's work set — the only dispatchable list.
        #expect(host.delivered[0].orders == [SZWorkOrder(node: nodeA.uuidString),
                                             SZWorkOrder(node: nodeB.uuidString)])
        // The turn went out rendered, with the router's choice attached.
        #expect(host.turnsSeen.count == 1)
        #expect(host.turnsSeen[0].brief == "rendered:decompose")
        #expect(host.turnsSeen[0].choice.providerID == "stub")
        // The trace saw every node run and settle — entry 1 is the DOOR, whose outcome
        // says what its code decided — and the dispatch entry carries the fleet's tally.
        #expect(host.notes.first == SZTraversalNote(ordinal: 1, node: SZAgentGraph.doorID,
                                                    phase: .running))
        #expect(host.notes.contains(SZTraversalNote(ordinal: 1, node: SZAgentGraph.doorID,
                                                    phase: .done, outcome: "build")))
        #expect(host.notes.contains(SZTraversalNote(ordinal: 3, node: "work-left",
                                                    phase: .done, outcome: "yes")))
        let landing = host.notes.last { $0.node == "implement" && $0.phase == .done }
        #expect(landing?.tally == SZAgentGraphRun.Tally(settled: 2, total: 2, failed: 0))
    }

    @Test func aSettledEdgeRoutesTheTraversalOnwardAfterTheFleet() async throws {
        // The retry shape: implement ─settled→ work-left (leashed). Fleet 1 lands, the gate
        // still sees work, the loop re-dispatches; fleet 2 lands, the gate says no, end.
        var graph = makeBuildGraph()
        graph.edges.append(.init(from: "implement", outcome: "settled", to: "work-left",
                                 maxTraversals: 2))
        let host = StubHost()
        host.summaries = [
            SZSettledSummary(setID: 1, from: "coding",
                             outcomes: [nodeA.uuidString: "error: red"], round: 1),
            SZSettledSummary(setID: 2, from: "coding",
                             outcomes: [nodeA.uuidString: "ok"], round: 2),
        ]
        let steps = StubSteps(scripts: buildScripts(workLeft: .reports([
            SZStepReport(outcome: "yes"),   // before fleet 1
            SZStepReport(outcome: "yes"),   // after fleet 1 — still unresolved
            SZStepReport(outcome: "no"),    // after fleet 2 — done
        ])))
        let engine = makeEngine(graph: graph, host: host, steps: steps)
        let result = await engine.run()
        // One message, ONE traversal, both fleets inside it.
        #expect(host.delivered.count == 2)
        #expect(result.conclusion == .ended(node: "work-left", outcome: "no"))
        // The trace shows the dispatch VISITED twice — the loop unrolled, per visit.
        #expect(host.notes.filter { $0.node == "implement" && $0.phase == .done }.count == 2)
    }

    @Test func theDispatchProgressNotesCarryTheLiveTally() async throws {
        let host = StubHost()
        host.progressTallies = [SZAgentGraphRun.Tally(settled: 1, total: 2, failed: 0)]
        host.summaries = [SZSettledSummary(setID: 1, from: "coding",
                                           outcomes: [nodeA.uuidString: "ok",
                                                      nodeB.uuidString: "ok"], round: 1)]
        let engine = makeEngine(host: host, steps: StubSteps(scripts: buildScripts()))
        _ = await engine.run()
        // Mid-fleet the card still reads RUNNING, tally attached — that is the band's
        // "these agents are working right now".
        #expect(host.notes.contains(SZTraversalNote(
            ordinal: 4, node: "implement", phase: .running,
            tally: SZAgentGraphRun.Tally(settled: 1, total: 2, failed: 0))))
    }

    @Test func aHostWithNoFleetMakesADispatchAnHonestDefect() async throws {
        let host = StubHost()   // summaries empty → deliver returns nil
        let engine = makeEngine(host: host, steps: StubSteps(scripts: buildScripts()))
        let result = await engine.run()
        guard case .defect(let node, let detail) = result.conclusion else {
            Issue.record("expected a defect, got \(result.conclusion)"); return
        }
        #expect(node == "implement")
        #expect(detail.contains("cannot dispatch"))
    }

    @Test func aDoorOutcomeWithNoEdgeEndsTheTraversalAtTheDoor() async throws {
        // The door ruled a route nothing wires — an ordinary ending, attributed to the
        // door, with nothing behind it run (the shipped director's `implement` ack shape).
        let host = StubHost()
        let engine = makeEngine(host: host,
                                steps: StubSteps(scripts: [
                                    "door": .report(SZStepReport(outcome: "answer")),
                                ]))
        let result = await engine.run()
        #expect(result.conclusion == .ended(node: SZAgentGraph.doorID, outcome: "answer"))
        #expect(host.turnsSeen.isEmpty)
        #expect(host.delivered.isEmpty)
        #expect(!host.notes.contains { $0.node != SZAgentGraph.doorID })
    }

    @Test func aDoorlessGraphIsARefusedDefect() async throws {
        // Validation refuses this at load; the engine still refuses to guess an entry.
        let graph = SZAgentGraph(nodes: [.init(id: "plan", form: .turn(.init(brief: "b")))],
                                 edges: [])
        let host = StubHost()
        let engine = makeEngine(graph: graph, host: host, steps: StubSteps(answers: [:]))
        let result = await engine.run()
        guard case .defect(_, let detail) = result.conclusion else {
            Issue.record("expected a defect, got \(result.conclusion)"); return
        }
        #expect(detail.contains("door"))
    }

    @Test func anExhaustedErrorLeashStillFailsTheTraversal() async throws {
        var graph = makeBuildGraph()
        graph.edges.append(.init(from: "plan", outcome: "error", to: "plan", maxTraversals: 2))
        let host = StubHost()
        host.turnReports = [
            SZTurnReport(failed: true, detail: "attempt 1 died"),
            SZTurnReport(failed: true, detail: "attempt 2 died"),
            SZTurnReport(failed: true, detail: "attempt 3 died"),
        ]
        let engine = makeEngine(graph: graph, host: host, steps: StubSteps(scripts: buildScripts()))
        let result = await engine.run()
        // Two retries ride the leash; the third failure must stay a FAILURE — an exhausted
        // error edge cannot launder it into a successful ending.
        #expect(result.conclusion == .failed(node: "plan", detail: "attempt 3 died"))
        #expect(host.turnsSeen.count == 3)
    }

    @Test func aFailedTurnWithNoErrorEdgeFailsTheTraversalWithItsDetail() async throws {
        let host = StubHost()
        host.turnReports = [SZTurnReport(failed: true, detail: "the provider died")]
        let engine = makeEngine(host: host, steps: StubSteps(scripts: buildScripts()))
        let result = await engine.run()
        #expect(result.conclusion == .failed(node: "plan", detail: "the provider died"))
    }

    @Test func aFailedTurnWithAnErrorEdgeRoutesRecovery() async throws {
        var graph = makeBuildGraph()
        graph.edges.append(.init(from: "plan", outcome: "error", to: "work-left"))
        let host = StubHost()
        host.turnReports = [SZTurnReport(failed: true, detail: "flaky")]
        host.summaries = [SZSettledSummary(setID: 1, from: "coding", outcomes: [:], round: 1)]
        let engine = makeEngine(graph: graph, host: host, steps: StubSteps(scripts: buildScripts()))
        let result = await engine.run()
        #expect(result.conclusion == .ended(node: "implement", outcome: "settled"))
    }

    @Test func aBoundedEdgeLeashesItsLoopThenEndsOnTheOutcome() async throws {
        let host = StubHost()
        // work-left answers no forever; the no-edge is bounded at 2 → unblock runs twice,
        // then the third `no` ends the traversal on its own outcome.
        let engine = makeEngine(host: host,
                                steps: StubSteps(scripts: buildScripts(
                                    workLeft: .report(SZStepReport(outcome: "no")))))
        let result = await engine.run()
        #expect(result.conclusion == .ended(node: "work-left", outcome: "no"))
        #expect(host.turnsSeen.count == 3)   // plan + unblock ×2
    }

    @Test func anOutcomeOutsideTheDeclaredSetIsADefect() async throws {
        let host = StubHost()
        let engine = makeEngine(host: host,
                                steps: StubSteps(scripts: buildScripts(
                                    workLeft: .report(SZStepReport(outcome: "perhaps")))))
        let result = await engine.run()
        guard case .defect(let node, let detail) = result.conclusion else {
            Issue.record("expected a defect, got \(result.conclusion)")
            return
        }
        #expect(node == "work-left")
        #expect(detail.contains("perhaps"))
    }

    @Test func aStepFailureIsADefectCarryingTheReason() async throws {
        let host = StubHost()
        let engine = makeEngine(host: host,
                                steps: StubSteps(scripts: buildScripts(
                                    workLeft: .report(SZStepReport(failure: "swiftc missing")))))
        let result = await engine.run()
        #expect(result.conclusion == .defect(node: "work-left", detail: "swiftc missing"))
    }

    @Test func aCancelledStepConcludesCancelledNotDefect() async throws {
        let host = StubHost()
        let engine = makeEngine(host: host,
                                steps: StubSteps(scripts: buildScripts(
                                    workLeft: .report(SZStepReport(cancelled: true)))))
        let result = await engine.run()
        #expect(result.conclusion == .cancelled(node: "work-left"))
    }

    @Test func declinedWithNoEdgeIsARefusalNotAFailure() async throws {
        var graph = makeBuildGraph()
        graph.nodes.append(.init(id: "gate", form: .step(name: "gate")))
        graph.edges.append(.init(from: SZAgentGraph.doorID, outcome: "answer", to: "gate"))
        let host = StubHost()
        let engine = makeEngine(
            graph: graph,
            attachments: buildAttachments.merging(
                ["gate": SZStepAttachment(outcomes: ["declined", "ok"])]) { a, _ in a },
            host: host,
            steps: StubSteps(scripts: [
                "door": .report(SZStepReport(outcome: "answer")),
                "gate": .report(SZStepReport(outcome: "declined")),
            ]))
        let result = await engine.run()
        #expect(result.conclusion == .declined(node: "gate", reason: nil))
    }

    @Test func anExhaustedDeclinedLeashStaysARefusal() async throws {
        var graph = makeBuildGraph()
        graph.nodes.append(.init(id: "gate", form: .step(name: "gate")))
        graph.nodes.append(.init(id: "clarify", form: .turn(.init(brief: "clarify"))))
        graph.edges.append(.init(from: SZAgentGraph.doorID, outcome: "answer", to: "gate"))
        graph.edges.append(.init(from: "gate", outcome: "declined", to: "clarify", maxTraversals: 1))
        graph.edges.append(.init(from: "clarify", outcome: "ok", to: "gate"))
        let host = StubHost()
        let engine = makeEngine(
            graph: graph,
            attachments: buildAttachments.merging(
                ["gate": SZStepAttachment(outcomes: ["declined", "ok"])]) { a, _ in a },
            host: host,
            steps: StubSteps(scripts: [
                "door": .report(SZStepReport(outcome: "answer")),
                "gate": .report(SZStepReport(outcome: "declined")),
            ]))
        let result = await engine.run()
        #expect(result.conclusion == .declined(node: "gate", reason: nil))
    }

    @Test func anUnrenderableBriefIsADefectNamingTheTemplate() async throws {
        @MainActor
        final class ThrowingHost: SZTraversalServing {
            struct Broken: Error {}
            func facts() -> SZFacts { SZFacts(message: "") }
            func render(template: String) throws -> String { throw Broken() }
            func runTurn(_ order: SZTurnOrder) async -> SZTurnReport { SZTurnReport(failed: false) }
            func serveAsk(step: String, slot: String?, requestJSON: String) async throws -> String {
                throw CancellationError()
            }
            func perform(effect: SZEffect) async {}
            func deliver(orders: [SZWorkOrder], to seat: String,
                         progress: @escaping @MainActor @Sendable (SZAgentGraphRun.Tally) -> Void)
                async -> SZSettledSummary? { nil }
            func note(_ note: SZTraversalNote) {}
        }
        let engine = SZGraphEngine(agent: "director", graph: makeBuildGraph(),
                                   attachments: buildAttachments, host: ThrowingHost(),
                                   steps: StubSteps(scripts: buildScripts()),
                                   router: identityRouter)
        let result = await engine.run()
        guard case .defect(let node, let detail) = result.conclusion else {
            Issue.record("expected a defect, got \(result.conclusion)")
            return
        }
        #expect(node == "plan")
        #expect(detail.contains("decompose"))
    }

    @Test func anAskingStepReachesTheServeSeamWithItsRequest() async throws {
        let host = StubHost()
        host.askReply = "yes"
        host.summaries = [SZSettledSummary(setID: 1, from: "coding", outcomes: [:], round: 1)]
        // The ask carries the step's own name and request; the delivery guarantees the
        // pinned snapshot on its side of the seam.
        let engine = makeEngine(host: host,
                                steps: StubSteps(scripts: buildScripts(
                                    workLeft: .ask(request: #"{"template": "classify"}"#))))
        let result = await engine.run()
        #expect(result.conclusion == .ended(node: "implement", outcome: "settled"))
        #expect(host.asksSeen.count == 1)
        let ask = try #require(host.asksSeen.first)
        #expect(ask.step == "work-left")
        #expect(ask.request == #"{"template": "classify"}"#)
    }

    @Test func stepEffectsPerformBeforeEdgeRouting() async throws {
        // The door itself requests the effect — the shipped director's `requestBuild`
        // shape, here routed onward so the order pin has an observable "next node".
        let host = StubHost()
        host.summaries = [SZSettledSummary(setID: 1, from: "coding", outcomes: [:], round: 1)]
        let engine = makeEngine(
            host: host,
            steps: StubSteps(scripts: buildScripts()
                .merging(["door": .report(SZStepReport(outcome: "build",
                                                       effects: ["requestBuild"]))]) { _, b in b }))
        let result = await engine.run()
        #expect(result.conclusion == .ended(node: "implement", outcome: "settled"))
        #expect(host.performed == [.requestBuild])
        // The pinned order: the effect performed BEFORE anything routed onward ran, and
        // the dispatch's delivery came last — after the routed turn.
        #expect(host.events == ["perform:requestBuild",
                                "turn:rendered:decompose",
                                "deliver:coding:\(nodeA.uuidString),\(nodeB.uuidString)"])
    }

    @Test func anUnknownEffectIsADefectNamingItAndNothingPerforms() async throws {
        let host = StubHost()
        let engine = makeEngine(host: host,
                                steps: StubSteps(scripts: buildScripts(
                                    workLeft: .report(SZStepReport(outcome: "yes",
                                                                   effects: ["explode"])))))
        let result = await engine.run()
        guard case .defect(let node, let detail) = result.conclusion else {
            Issue.record("expected a defect, got \(result.conclusion)")
            return
        }
        #expect(node == "work-left")
        #expect(detail.contains("explode"))
        #expect(host.performed.isEmpty)
    }

    @Test func cancellationAtANodeBoundaryConcludesCancelled() async throws {
        let host = StubHost()
        let engine = makeEngine(host: host, steps: StubSteps(scripts: buildScripts()))
        let traversal = Task { await engine.run() }
        traversal.cancel()
        let result = await traversal.value
        guard case .cancelled = result.conclusion else {
            Issue.record("expected .cancelled, got \(result.conclusion)")
            return
        }
    }
}
