// SPDX-License-Identifier: AGPL-3.0-only
// The traversal engine driven end-to-end through stub seams — the real engine, never a
// replica: outcome routing, the turn's ok/error-only contract, dispatch send-and-conclude,
// bounded edges as leashes, declined-is-not-failure, cancellation, and every defect arm.
import Testing
import Foundation
@testable import SZAI
@testable import SZCore

// MARK: - Stub seams

@MainActor
private final class StubHost: SZTraversalHost {
    var facts = #"{"stub": true}"#
    var items: [String] = []
    var turnReports: [SZTurnReport] = []
    var turnsSeen: [SZTurnOrder] = []
    var notes: [SZTraversalNote] = []
    var briefPrefix = "rendered:"
    var askReply = "scripted-reply"
    var asksSeen: [(step: String, kind: SZMessageKind, facts: String, request: String)] = []
    var performed: [(effect: String, kind: SZMessageKind)] = []
    /// Everything the host was asked to DO, in arrival order — what pins effects-before-
    /// edge-routing (a perform must land before the next node's turn).
    var events: [String] = []

    /// Which lane each facts read was made in — what pins the settled→build fold.
    var factsKindsSeen: [SZMessageKind] = []

    func factsJSON(kind: SZMessageKind) -> String {
        factsKindsSeen.append(kind)
        return facts
    }
    func itemsFact(named name: String, kind: SZMessageKind) -> [String] { items }
    func renderBrief(agent: String, template: String, kind: SZMessageKind) throws -> String {
        briefPrefix + template
    }
    func runTurn(_ order: SZTurnOrder) async -> SZTurnReport {
        turnsSeen.append(order)
        events.append("turn:\(order.brief)")
        return turnReports.isEmpty ? SZTurnReport(failed: false) : turnReports.removeFirst()
    }
    func serveAsk(agent: String, step: String, kind: SZMessageKind, factsJSON: String,
                  requestJSON: String) async throws -> String {
        asksSeen.append((step, kind, factsJSON, requestJSON))
        return askReply
    }
    func perform(effect: String, kind: SZMessageKind) async {
        performed.append((effect, kind))
        events.append("perform:\(effect)")
    }
    func note(_ note: SZTraversalNote) { notes.append(note) }
}

/// Scripted step answers, keyed by step name; missing key = a failure report. A step whose
/// key maps to `.ask` invokes the engine-provided ask closure and answers with its reply.
private struct StubSteps: SZStepRunning {
    enum Script: Sendable {
        case report(SZStepReport)
        /// Call the ask closure with `request` and answer with whatever comes back.
        case ask(request: String)
    }

    let scripts: [String: Script]

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
        case .ask(let request):
            do { return SZStepReport(outcome: try await ask(request)) }
            catch { return SZStepReport(failure: String(describing: error)) }
        case nil: return SZStepReport(failure: "no scripted answer for \(step)")
        }
    }
}

private let identityRouter = SZIdentityRouter(
    choice: SZModelChoice(providerID: "stub", model: nil, reasoningEffort: nil))

/// plan(turn) → work-left(step yes/no) → implement(dispatch); no→unblock(turn) loops back
/// across a bounded edge. The same shape the P2 scratch packs proved through the gate.
private func makeBuildGraph() -> SZAgentGraph {
    SZAgentGraph(
        name: "build",
        nodes: [
            .init(id: "message", form: .message(.init())),
            .init(id: "plan", form: .turn(.init(brief: "prompts/decompose.md.mustache"))),
            .init(id: "work-left", form: .step(name: "work-left")),
            .init(id: "unblock", form: .turn(.init(brief: "prompts/unblock.md.mustache"))),
            .init(id: "implement", form: .dispatch(.init(to: "coding", items: "workSet"))),
        ],
        edges: [
            .init(from: "message", outcome: "build", to: "plan"),
            .init(from: "message", outcome: "settled", to: "work-left"),
            .init(from: "plan", outcome: "ok", to: "work-left"),
            .init(from: "work-left", outcome: "yes", to: "implement"),
            .init(from: "work-left", outcome: "no", to: "unblock", maxTraversals: 2),
            .init(from: "unblock", outcome: "ok", to: "work-left"),
        ])
}

private let workLeftAttachment = ["work-left": SZStepAttachment(outcomes: ["yes", "no"])]

@MainActor
private func makeEngine(graph: SZAgentGraph = makeBuildGraph(),
                        attachments: [String: SZStepAttachment] = workLeftAttachment,
                        host: StubHost, steps: StubSteps) -> SZGraphEngine {
    SZGraphEngine(agent: "director", graph: graph, attachments: attachments,
                  host: host, steps: steps, router: identityRouter)
}

// MARK: - Tests

@MainActor
struct SZGraphEngineTests {

    @Test func aBuildTraversalRoutesTurnThenStepThenDispatch() async throws {
        let host = StubHost()
        host.items = ["node-a", "node-b"]
        let engine = makeEngine(host: host,
                                steps: StubSteps(answers: ["work-left": SZStepReport(outcome: "yes")]))
        let result = await engine.run(kind: .build)

        #expect(result.conclusion == .ended(node: "implement", outcome: "sent"))
        #expect(result.sent == [SZItemOrder(node: "node-a"), SZItemOrder(node: "node-b")])
        // The turn went out rendered, with the router's choice attached.
        #expect(host.turnsSeen.count == 1)
        #expect(host.turnsSeen[0].brief == "rendered:prompts/decompose.md.mustache")
        #expect(host.turnsSeen[0].choice.providerID == "stub")
        // The trace saw every node run and settle — starting at the DOOR, whose outcome is
        // the delivered kind, so the trace opens by saying what arrived.
        #expect(host.notes.first == SZTraversalNote(ordinal: 1, node: "message", phase: .running))
        #expect(host.notes.contains(SZTraversalNote(ordinal: 1, node: "message", phase: .done,
                                                    outcome: "build")))
        #expect(host.notes.contains(SZTraversalNote(ordinal: 3, node: "work-left", phase: .done, outcome: "yes")))
    }

    @Test func settledReEntersThroughTheDoorsOwnPort() async throws {
        let host = StubHost()
        let engine = makeEngine(host: host,
                                steps: StubSteps(answers: ["work-left": SZStepReport(outcome: "yes")]))
        let result = await engine.run(kind: .settled)
        // In by the `settled` port to work-left, straight to dispatch — no decompose turn
        // on a re-entry. The reply IS a message, so it uses the same door as the build.
        #expect(host.notes.first?.node == "message")
        #expect(host.notes.contains(SZTraversalNote(ordinal: 1, node: "message", phase: .done,
                                                    outcome: "settled")))
        #expect(result.conclusion == .ended(node: "implement", outcome: "sent"))
        #expect(host.turnsSeen.isEmpty)
    }

    @Test func aSettledTraversalReasonsInTheBuildLane() async throws {
        // The regression guard for the lane fold: `SZEffectCatalog.cases(kind: "settled")`
        // is EMPTY, so handing the seams the delivered kind instead of its lane would
        // refuse a settled traversal's `captureStatuses` as an unknown effect.
        let host = StubHost()
        let engine = makeEngine(
            attachments: ["work-left": SZStepAttachment(outcomes: ["yes"])],
            host: host,
            steps: StubSteps(answers: ["work-left": SZStepReport(outcome: "yes",
                                                                 effects: ["captureStatuses"])]))
        let result = await engine.run(kind: .settled)
        #expect(result.conclusion == .ended(node: "implement", outcome: "sent"))
        #expect(host.performed.map(\.effect) == ["captureStatuses"])
        // Performed under BUILD, the lane a settled reply reasons in.
        #expect(host.performed.map(\.kind) == [.build])
        // And the facts it read were the build lane's, not a settled document.
        #expect(host.factsKindsSeen.allSatisfy { $0 == .build })
    }

    @Test func anUnroutedKindDefectsAtTheDoorBeforeAnyWorkRuns() async throws {
        let host = StubHost()
        let engine = makeEngine(host: host, steps: StubSteps(answers: [:]))
        let result = await engine.run(kind: .chat)
        guard case .defect(let node, let detail) = result.conclusion else {
            Issue.record("expected a defect, got \(result.conclusion)")
            return
        }
        // The door is a real visit now, so the defect is ATTRIBUTED to it and the trace
        // shows the message arriving and failing — rather than a traversal with no notes
        // at all, which used to leave a routing bug with nothing to point at.
        #expect(node == "message")
        #expect(detail.contains("chat"))
        #expect(host.notes.map(\.node) == ["message", "message"])
        #expect(host.notes.last?.phase == .failed)
        // Nothing behind the door ran.
        #expect(!host.notes.contains { $0.node != "message" })
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
        let engine = makeEngine(graph: graph, host: host, steps: StubSteps(answers: [:]))
        let result = await engine.run(kind: .build)
        // Two retries ride the leash; the third failure must stay a FAILURE — an exhausted
        // error edge cannot launder it into a successful ending.
        #expect(result.conclusion == .failed(node: "plan", detail: "attempt 3 died"))
        #expect(host.turnsSeen.count == 3)
    }

    @Test func anExhaustedDeclinedLeashStaysARefusal() async throws {
        var graph = makeBuildGraph()
        graph.nodes.append(.init(id: "gate", form: .step(name: "gate")))
        graph.nodes.append(.init(id: "clarify", form: .turn(.init(brief: "prompts/clarify.md.mustache"))))
        graph.edges.append(.init(from: "message", outcome: "request", to: "gate"))
        graph.edges.append(.init(from: "gate", outcome: "declined", to: "clarify", maxTraversals: 1))
        graph.edges.append(.init(from: "clarify", outcome: "ok", to: "gate"))
        let host = StubHost()
        let engine = makeEngine(
            graph: graph,
            attachments: ["gate": SZStepAttachment(outcomes: ["declined", "ok"])],
            host: host,
            steps: StubSteps(answers: ["gate": SZStepReport(outcome: "declined")]))
        let result = await engine.run(kind: .request)
        #expect(result.conclusion == .declined(node: "gate", reason: nil))
    }

    @Test func aDispatchReportsItsTargetInTheResult() async throws {
        let host = StubHost()
        host.items = ["node-a"]
        let engine = makeEngine(host: host,
                                steps: StubSteps(answers: ["work-left": SZStepReport(outcome: "yes")]))
        let result = await engine.run(kind: .build)
        #expect(result.sentTarget == "coding")
    }

    @Test func aFailedTurnWithNoErrorEdgeFailsTheTraversalWithItsDetail() async throws {
        let host = StubHost()
        host.turnReports = [SZTurnReport(failed: true, detail: "the provider died")]
        let engine = makeEngine(host: host, steps: StubSteps(answers: [:]))
        let result = await engine.run(kind: .build)
        #expect(result.conclusion == .failed(node: "plan", detail: "the provider died"))
    }

    @Test func aFailedTurnWithAnErrorEdgeRoutesRecovery() async throws {
        var graph = makeBuildGraph()
        graph.edges.append(.init(from: "plan", outcome: "error", to: "work-left"))
        let host = StubHost()
        host.turnReports = [SZTurnReport(failed: true, detail: "flaky")]
        let engine = makeEngine(graph: graph, host: host,
                                steps: StubSteps(answers: ["work-left": SZStepReport(outcome: "yes")]))
        let result = await engine.run(kind: .build)
        #expect(result.conclusion == .ended(node: "implement", outcome: "sent"))
    }

    @Test func aBoundedEdgeLeashesItsLoopThenEndsOnTheOutcome() async throws {
        let host = StubHost()
        // work-left answers no forever; the no-edge is bounded at 2 → unblock runs twice,
        // then the third `no` ends the traversal on its own outcome.
        let engine = makeEngine(host: host,
                                steps: StubSteps(answers: ["work-left": SZStepReport(outcome: "no")]))
        let result = await engine.run(kind: .build)
        #expect(result.conclusion == .ended(node: "work-left", outcome: "no"))
        #expect(host.turnsSeen.count == 3)   // plan + unblock ×2
    }

    @Test func anOutcomeOutsideTheDeclaredSetIsADefect() async throws {
        let host = StubHost()
        let engine = makeEngine(host: host,
                                steps: StubSteps(answers: ["work-left": SZStepReport(outcome: "perhaps")]))
        let result = await engine.run(kind: .settled)
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
                                steps: StubSteps(answers: ["work-left": SZStepReport(failure: "swiftc missing")]))
        let result = await engine.run(kind: .settled)
        #expect(result.conclusion == .defect(node: "work-left", detail: "swiftc missing"))
    }

    @Test func aCancelledStepConcludesCancelledNotDefect() async throws {
        let host = StubHost()
        let engine = makeEngine(host: host,
                                steps: StubSteps(answers: ["work-left": SZStepReport(cancelled: true)]))
        let result = await engine.run(kind: .settled)
        #expect(result.conclusion == .cancelled(node: "work-left"))
    }

    @Test func declinedWithNoEdgeIsARefusalNotAFailure() async throws {
        var graph = makeBuildGraph()
        graph.nodes.append(.init(id: "gate", form: .step(name: "gate")))
        graph.edges.append(.init(from: "message", outcome: "request", to: "gate"))
        let host = StubHost()
        let engine = makeEngine(
            graph: graph,
            attachments: ["gate": SZStepAttachment(outcomes: ["declined", "ok"])],
            host: host,
            steps: StubSteps(answers: ["gate": SZStepReport(outcome: "declined")]))
        let result = await engine.run(kind: .request)
        #expect(result.conclusion == .declined(node: "gate", reason: nil))
    }

    @Test func anUnrenderableBriefIsADefectNamingTheTemplate() async throws {
        @MainActor
        final class ThrowingHost: SZTraversalHost {
            struct Broken: Error {}
            func factsJSON(kind: SZMessageKind) -> String { "{}" }
            func itemsFact(named name: String, kind: SZMessageKind) -> [String] { [] }
            func renderBrief(agent: String, template: String, kind: SZMessageKind) throws -> String { throw Broken() }
            func runTurn(_ order: SZTurnOrder) async -> SZTurnReport { SZTurnReport(failed: false) }
            func serveAsk(agent: String, step: String, kind: SZMessageKind, factsJSON: String,
                          requestJSON: String) async throws -> String { throw CancellationError() }
            func perform(effect: String, kind: SZMessageKind) async {}
            func note(_ note: SZTraversalNote) {}
        }
        let engine = SZGraphEngine(agent: "director", graph: makeBuildGraph(),
                                   attachments: workLeftAttachment, host: ThrowingHost(),
                                   steps: StubSteps(answers: [:]), router: identityRouter)
        let result = await engine.run(kind: .build)
        guard case .defect(let node, let detail) = result.conclusion else {
            Issue.record("expected a defect, got \(result.conclusion)")
            return
        }
        #expect(node == "plan")
        #expect(detail.contains("decompose.md.mustache"))
    }

    @Test func anAskingStepGetsTheGraphKindAndThePinnedFacts() async throws {
        let host = StubHost()
        host.askReply = "yes"
        // Entered as `.settled`, the ask still carries the GRAPH's own kind (build) and the
        // exact facts bytes the evaluation was handed — the pinned-snapshot contract.
        let engine = makeEngine(host: host,
                                steps: StubSteps(scripts: ["work-left": .ask(request: #"{"template": "classify"}"#)]))
        let result = await engine.run(kind: .settled)
        #expect(result.conclusion == .ended(node: "implement", outcome: "sent"))
        #expect(host.asksSeen.count == 1)
        let ask = try #require(host.asksSeen.first)
        #expect(ask.step == "work-left")
        #expect(ask.kind == .build)
        #expect(ask.facts == host.facts)
        #expect(ask.request == #"{"template": "classify"}"#)
    }

    @Test func stepEffectsPerformBeforeEdgeRouting() async throws {
        var graph = makeBuildGraph()
        // Route the effect-emitting step onward to a TURN, so the order pin has an
        // observable "next node" to land after.
        graph.nodes.append(.init(id: "gate", form: .step(name: "gate")))
        // Re-point the build port at the gate — the door is where a lane starts now.
        graph.edges.removeAll { $0.from == "message" && $0.outcome == "build" }
        graph.edges.append(.init(from: "message", outcome: "build", to: "gate"))
        graph.edges.append(.init(from: "gate", outcome: "go", to: "plan"))
        let host = StubHost()
        host.items = ["node-a"]
        let engine = makeEngine(
            graph: graph,
            attachments: workLeftAttachment.merging(["gate": SZStepAttachment(outcomes: ["go"])]) { a, _ in a },
            host: host,
            steps: StubSteps(scripts: [
                "gate": .report(SZStepReport(outcome: "go", effects: ["captureStatuses"])),
                "work-left": .report(SZStepReport(outcome: "yes")),
            ]))
        let result = await engine.run(kind: .build)
        #expect(result.conclusion == .ended(node: "implement", outcome: "sent"))
        #expect(host.performed.map(\.effect) == ["captureStatuses"])
        #expect(host.performed.first?.kind == .build)
        // The pinned order: the effect performed BEFORE anything routed onward ran.
        #expect(host.events == ["perform:captureStatuses", "turn:rendered:prompts/decompose.md.mustache"])
    }

    @Test func anUnknownEffectIsADefectNamingItAndNothingPerforms() async throws {
        let host = StubHost()
        let engine = makeEngine(host: host,
                                steps: StubSteps(scripts: [
                                    "work-left": .report(SZStepReport(outcome: "yes", effects: ["explode"])),
                                ]))
        let result = await engine.run(kind: .settled)
        guard case .defect(let node, let detail) = result.conclusion else {
            Issue.record("expected a defect, got \(result.conclusion)")
            return
        }
        #expect(node == "work-left")
        #expect(detail.contains("explode"))
        #expect(host.performed.isEmpty)
    }

    @Test func anEffectFromAnotherKindsSetIsADefect() async throws {
        // `requestBuild` is a CHAT effect — declared, but not in the build kind's set, so a
        // build-graph step requesting it is a defect, not a perform.
        let host = StubHost()
        let engine = makeEngine(host: host,
                                steps: StubSteps(scripts: [
                                    "work-left": .report(SZStepReport(outcome: "yes", effects: ["requestBuild"])),
                                ]))
        let result = await engine.run(kind: .settled)
        guard case .defect(_, let detail) = result.conclusion else {
            Issue.record("expected a defect, got \(result.conclusion)")
            return
        }
        #expect(detail.contains("requestBuild"))
        #expect(detail.contains("build"))
        #expect(host.performed.isEmpty)
    }

    @Test func cancellationAtANodeBoundaryConcludesCancelled() async throws {
        let host = StubHost()
        let engine = makeEngine(host: host,
                                steps: StubSteps(answers: ["work-left": SZStepReport(outcome: "yes")]))
        let traversal = Task { await engine.run(kind: .build) }
        traversal.cancel()
        let result = await traversal.value
        guard case .cancelled = result.conclusion else {
            Issue.record("expected .cancelled, got \(result.conclusion)")
            return
        }
    }
}
