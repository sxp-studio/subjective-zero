// SPDX-License-Identifier: AGPL-3.0-only
// The graph model's gate: wire-format round-trips (the exactly-one-form rule) and one test
// per shape-defect category, each built by breaking a known-good graph in exactly one way.
import Testing
import Foundation
@testable import SZCore

/// A well-formed graph exercising the node forms and a bounded cycle: one door (a step),
/// one connected walk.
private func makeGraph() -> SZAgentGraph {
    SZAgentGraph(
        label: "Directed",
        nodes: [
            .init(id: "door", title: "On message", form: .step(name: "door")),
            .init(id: "plan", title: "Plan contracts", form: .turn(.init(brief: "decompose"))),
            .init(id: "work-left", form: .step(name: "work-left")),
            .init(id: "unblock", title: "Unblock", form: .turn(.init(brief: "unblock"))),
            .init(id: "implement", title: "Dispatch fleet", form: .dispatch(.init(to: "coding"))),
        ],
        edges: [
            .init(from: "door", outcome: "build", to: "plan"),
            .init(from: "plan", outcome: "ok", to: "work-left"),
            .init(from: "work-left", outcome: "yes", to: "implement"),
            .init(from: "work-left", outcome: "no", to: "unblock", maxTraversals: 2),
            .init(from: "unblock", outcome: "ok", to: "work-left"),
        ])
}

struct SZAgentGraphTests {

    // MARK: - Wire format

    @Test func aGraphRoundTripsThroughItsWireFormat() throws {
        let graph = makeGraph()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(graph)
        let decoded = try JSONDecoder().decode(SZAgentGraph.self, from: data)
        #expect(decoded == graph)
    }

    @Test func anOmittedSessionMeansSpawn() throws {
        let json = #"{"nodes": [{"id": "a", "turn": {"brief": "b"}}]}"#
        let graph = try JSONDecoder().decode(SZAgentGraph.self, from: Data(json.utf8))
        guard case .turn(let turn) = graph.nodes[0].form else {
            Issue.record("expected a turn node")
            return
        }
        #expect(turn.session == .spawn)
    }

    @Test func theDoorIsTheStepAtTheReservedID() throws {
        let json = #"""
        {"nodes": [{"id": "door", "step": "door"},
                   {"id": "reply", "turn": {"brief": "chat", "session": "resume"}}],
         "edges": [{"from": "door", "outcome": "answer", "to": "reply"}]}
        """#
        let graph = try JSONDecoder().decode(SZAgentGraph.self, from: Data(json.utf8))
        #expect(graph.door?.id == "door")
        #expect(graph.defects().isEmpty)
        guard case .turn(let turn) = graph.node("reply")?.form else {
            Issue.record("expected a turn node")
            return
        }
        #expect(turn.session == .resume)
    }

    @Test func aNodeWithTwoFormsIsUnrepresentable() {
        let json = #"{"nodes": [{"id": "a", "step": "s", "turn": {"brief": "b"}}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SZAgentGraph.self, from: Data(json.utf8))
        }
    }

    @Test func aNodeWithNoFormIsUnrepresentable() {
        let json = #"{"nodes": [{"id": "a"}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SZAgentGraph.self, from: Data(json.utf8))
        }
    }

    // MARK: - Shape defects, one per category

    @Test func theWellFormedGraphValidatesClean() {
        #expect(makeGraph().defects().isEmpty)
    }

    @Test func duplicateNodeIDs() {
        var graph = makeGraph()
        graph.nodes.append(.init(id: "plan", form: .step(name: "shadow")))
        #expect(graph.defects().contains(.duplicateNode(id: "plan")))
    }

    @Test func aDoorlessGraphIsRefused() {
        var graph = makeGraph()
        graph.nodes.removeAll { $0.id == "door" }
        graph.edges.removeAll { $0.from == "door" }
        #expect(graph.defects().contains(.noDoor))
    }

    @Test func aDoorThatIsNotAStepIsRefused() {
        // The entry is code the author opens and edits — a turn or dispatch cannot be it.
        var graph = makeGraph()
        let door = graph.nodes.firstIndex { $0.id == "door" }!
        graph.nodes[door].form = .turn(.init(brief: "chat"))
        #expect(graph.defects().contains(.doorNotStep))
    }

    @Test func nothingMayRouteBackIntoTheDoor() {
        // A message ARRIVES; it is never a destination.
        var graph = makeGraph()
        graph.edges.append(.init(from: "unblock", outcome: "error", to: "door"))
        #expect(graph.defects().contains(.edgeIntoDoor(from: "unblock")))
    }

    @Test func aNodeTheDoorCannotReachIsRefused() {
        // A lane with no way in is a load defect, not something to notice on a canvas.
        var graph = makeGraph()
        graph.nodes.append(.init(id: "orphan", form: .step(name: "orphan")))
        #expect(graph.defects().contains(.unreachable(nodes: ["orphan"])))
    }

    @Test func aSettledLoopMustBeLeashed() {
        // The retry shape: the dispatch's settled edge loops back, refused without its
        // leash like any other cycle.
        var graph = makeGraph()
        graph.edges.append(.init(from: "implement", outcome: "settled", to: "work-left",
                                 maxTraversals: 2))
        #expect(graph.defects().isEmpty)
        let leash = graph.edges.firstIndex { $0.from == "implement" }!
        graph.edges[leash].maxTraversals = nil
        #expect(graph.defects().contains { if case .unboundedCycle = $0 { true } else { false } })
    }

    @Test func danglingEdges() {
        var graph = makeGraph()
        graph.edges.append(.init(from: "plan", outcome: "error", to: "nowhere"))
        #expect(graph.defects().contains(.danglingEdge(from: "plan", to: "nowhere")))
    }

    @Test func aDispatchRoutesOnlyItsSettledOutcome() {
        var graph = makeGraph()
        graph.edges.append(.init(from: "implement", outcome: "sent", to: "plan"))
        #expect(graph.defects().contains(.edgeFromDispatch(node: "implement", outcome: "sent")))
    }

    @Test func aTurnOnlySpeaksOkOrError() {
        var graph = makeGraph()
        graph.edges.append(.init(from: "plan", outcome: "maybe", to: "work-left"))
        #expect(graph.defects().contains(.undeclaredOutcome(node: "plan", outcome: "maybe")))
    }

    @Test func boundsBelowOneAreRefused() {
        var graph = makeGraph()
        let leash = graph.edges.firstIndex { $0.from == "work-left" && $0.outcome == "no" }!
        graph.edges[leash].maxTraversals = 0
        #expect(graph.defects().contains(.nonPositiveBound(from: "work-left", outcome: "no")))
    }

    @Test func aSecondEdgeOnTheSameOutcomeIsRefused() {
        var graph = makeGraph()
        graph.edges.append(.init(from: "work-left", outcome: "yes", to: "unblock"))
        #expect(graph.defects().contains(.duplicateEdge(from: "work-left", outcome: "yes")))
    }

    @Test func aCycleMustCrossABoundedEdge() {
        var graph = makeGraph()
        // work-left → unblock → work-left, now leashless. Found by its ends rather than by
        // index: the door's edges lead the array, and an index would silently retarget.
        let leash = graph.edges.firstIndex { $0.from == "work-left" && $0.to == "unblock" }!
        graph.edges[leash].maxTraversals = nil
        let cycles = graph.defects().filter {
            if case .unboundedCycle = $0 { return true } else { return false }
        }
        #expect(cycles.count == 1)
    }

    @Test func allDefectsAreCollectedNotFirstError() {
        var graph = makeGraph()
        graph.nodes.append(.init(id: "orphan", form: .step(name: "orphan")))
        graph.edges.append(.init(from: "plan", outcome: "error", to: "nowhere"))
        graph.edges.append(.init(from: "implement", outcome: "sent", to: "plan"))
        #expect(graph.defects().count >= 3)
    }

    // MARK: - Lookup and derivations

    @Test func edgeLookupFollowsOutcomeAndAbsenceEndsTheTraversal() {
        let graph = makeGraph()
        #expect(graph.edge(from: "work-left", outcome: "yes")?.to == "implement")
        #expect(graph.edge(from: "work-left", outcome: "declined") == nil)
    }

    @Test func theRetryCapIsTheLargestSettledLeash() {
        var graph = makeGraph()
        #expect(graph.retryCap == 0)   // no dispatch loops yet
        graph.edges.append(.init(from: "implement", outcome: "settled", to: "work-left",
                                 maxTraversals: 3))
        #expect(graph.retryCap == 3)
    }
}
