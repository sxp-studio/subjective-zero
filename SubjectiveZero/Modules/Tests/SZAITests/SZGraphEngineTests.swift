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

    func factsJSON(kind: SZMessageKind) -> String { facts }
    func itemsFact(named name: String, kind: SZMessageKind) -> [String] { items }
    func renderBrief(agent: String, template: String, kind: SZMessageKind) throws -> String {
        briefPrefix + template
    }
    func runTurn(_ order: SZTurnOrder) async -> SZTurnReport {
        turnsSeen.append(order)
        return turnReports.isEmpty ? SZTurnReport(failed: false) : turnReports.removeFirst()
    }
    func serveAsk(agent: String, step: String, requestJSON: String) async throws -> String {
        throw CancellationError()
    }
    func note(_ note: SZTraversalNote) { notes.append(note) }
}

/// Scripted step answers, keyed by step name; missing key = a failure report.
private struct StubSteps: SZStepRunning {
    let answers: [String: SZStepReport]
    func evaluate(agent: String, step: String, factsJSON: String,
                  ask: @escaping @Sendable (String) async throws -> String) async -> SZStepReport {
        answers[step] ?? SZStepReport(failure: "no scripted answer for \(step)")
    }
}

private let identityRouter = SZIdentityRouter(
    choice: SZModelChoice(providerID: "stub", model: nil, reasoningEffort: nil))

/// plan(turn) → work-left(step yes/no) → implement(dispatch); no→unblock(turn) loops back
/// across a bounded edge. The same shape the P2 scratch packs proved through the gate.
private func makeBuildGraph() -> SZAgentGraph {
    SZAgentGraph(
        name: "build", kind: .build,
        entry: [.build: "plan", .settled: "work-left"],
        nodes: [
            .init(id: "plan", form: .turn(.init(brief: "prompts/decompose.md.mustache"))),
            .init(id: "work-left", form: .step(name: "work-left")),
            .init(id: "unblock", form: .turn(.init(brief: "prompts/unblock.md.mustache"))),
            .init(id: "implement", form: .dispatch(.init(to: "coding", items: "workSet"))),
        ],
        edges: [
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

        #expect(result.conclusion == .ended(step: "implement", outcome: "sent"))
        #expect(result.sent == [SZItemOrder(node: "node-a"), SZItemOrder(node: "node-b")])
        // The turn went out rendered, with the router's choice attached.
        #expect(host.turnsSeen.count == 1)
        #expect(host.turnsSeen[0].brief == "rendered:prompts/decompose.md.mustache")
        #expect(host.turnsSeen[0].choice.providerID == "stub")
        // The trace saw every node run and settle.
        #expect(host.notes.contains(SZTraversalNote(ordinal: 2, node: "work-left", phase: .done, outcome: "yes")))
    }

    @Test func settledReEntersAtItsOwnEntry() async throws {
        let host = StubHost()
        let engine = makeEngine(host: host,
                                steps: StubSteps(answers: ["work-left": SZStepReport(outcome: "yes")]))
        let result = await engine.run(kind: .settled)
        // Entry at work-left, straight to dispatch — no decompose turn on a re-entry.
        #expect(result.conclusion == .ended(step: "implement", outcome: "sent"))
        #expect(host.turnsSeen.isEmpty)
    }

    @Test func aForeignKindEndsUnhandledBeforeAnyNodeRuns() async throws {
        let host = StubHost()
        let engine = makeEngine(host: host, steps: StubSteps(answers: [:]))
        let result = await engine.run(kind: .chat)
        #expect(result.conclusion == .ended(step: "", outcome: "unhandled"))
        #expect(host.notes.isEmpty)
    }

    @Test func aFailedTurnWithNoErrorEdgeFailsTheTraversalWithItsDetail() async throws {
        let host = StubHost()
        host.turnReports = [SZTurnReport(failed: true, detail: "the provider died")]
        let engine = makeEngine(host: host, steps: StubSteps(answers: [:]))
        let result = await engine.run(kind: .build)
        #expect(result.conclusion == .failed(step: "plan", detail: "the provider died"))
    }

    @Test func aFailedTurnWithAnErrorEdgeRoutesRecovery() async throws {
        var graph = makeBuildGraph()
        graph.edges.append(.init(from: "plan", outcome: "error", to: "work-left"))
        let host = StubHost()
        host.turnReports = [SZTurnReport(failed: true, detail: "flaky")]
        let engine = makeEngine(graph: graph, host: host,
                                steps: StubSteps(answers: ["work-left": SZStepReport(outcome: "yes")]))
        let result = await engine.run(kind: .build)
        #expect(result.conclusion == .ended(step: "implement", outcome: "sent"))
    }

    @Test func aBoundedEdgeLeashesItsLoopThenEndsOnTheOutcome() async throws {
        let host = StubHost()
        // work-left answers no forever; the no-edge is bounded at 2 → unblock runs twice,
        // then the third `no` ends the traversal on its own outcome.
        let engine = makeEngine(host: host,
                                steps: StubSteps(answers: ["work-left": SZStepReport(outcome: "no")]))
        let result = await engine.run(kind: .build)
        #expect(result.conclusion == .ended(step: "work-left", outcome: "no"))
        #expect(host.turnsSeen.count == 3)   // plan + unblock ×2
    }

    @Test func anOutcomeOutsideTheDeclaredSetIsADefect() async throws {
        let host = StubHost()
        let engine = makeEngine(host: host,
                                steps: StubSteps(answers: ["work-left": SZStepReport(outcome: "perhaps")]))
        let result = await engine.run(kind: .settled)
        guard case .defect(let step, let detail) = result.conclusion else {
            Issue.record("expected a defect, got \(result.conclusion)")
            return
        }
        #expect(step == "work-left")
        #expect(detail.contains("perhaps"))
    }

    @Test func aStepFailureIsADefectCarryingTheReason() async throws {
        let host = StubHost()
        let engine = makeEngine(host: host,
                                steps: StubSteps(answers: ["work-left": SZStepReport(failure: "swiftc missing")]))
        let result = await engine.run(kind: .settled)
        #expect(result.conclusion == .defect(step: "work-left", detail: "swiftc missing"))
    }

    @Test func aCancelledStepConcludesCancelledNotDefect() async throws {
        let host = StubHost()
        let engine = makeEngine(host: host,
                                steps: StubSteps(answers: ["work-left": SZStepReport(cancelled: true)]))
        let result = await engine.run(kind: .settled)
        #expect(result.conclusion == .cancelled(step: "work-left"))
    }

    @Test func declinedWithNoEdgeIsARefusalNotAFailure() async throws {
        var graph = makeBuildGraph()
        graph.nodes.append(.init(id: "gate", form: .step(name: "gate")))
        graph.entry[.request] = "gate"
        let host = StubHost()
        let engine = makeEngine(
            graph: graph,
            attachments: ["gate": SZStepAttachment(outcomes: ["declined", "ok"])],
            host: host,
            steps: StubSteps(answers: ["gate": SZStepReport(outcome: "declined")]))
        let result = await engine.run(kind: .request)
        #expect(result.conclusion == .declined(step: "gate", reason: nil))
    }

    @Test func anUnrenderableBriefIsADefectNamingTheTemplate() async throws {
        @MainActor
        final class ThrowingHost: SZTraversalHost {
            struct Broken: Error {}
            func factsJSON(kind: SZMessageKind) -> String { "{}" }
            func itemsFact(named name: String, kind: SZMessageKind) -> [String] { [] }
            func renderBrief(agent: String, template: String, kind: SZMessageKind) throws -> String { throw Broken() }
            func runTurn(_ order: SZTurnOrder) async -> SZTurnReport { SZTurnReport(failed: false) }
            func serveAsk(agent: String, step: String, requestJSON: String) async throws -> String { throw CancellationError() }
            func note(_ note: SZTraversalNote) {}
        }
        let engine = SZGraphEngine(agent: "director", graph: makeBuildGraph(),
                                   attachments: workLeftAttachment, host: ThrowingHost(),
                                   steps: StubSteps(answers: [:]), router: identityRouter)
        let result = await engine.run(kind: .build)
        guard case .defect(let step, let detail) = result.conclusion else {
            Issue.record("expected a defect, got \(result.conclusion)")
            return
        }
        #expect(step == "plan")
        #expect(detail.contains("decompose.md.mustache"))
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
