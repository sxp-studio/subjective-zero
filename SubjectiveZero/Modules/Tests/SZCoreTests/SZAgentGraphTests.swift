// SPDX-License-Identifier: AGPL-3.0-only
// The graph model's gate: wire-format round-trips (including the retired-key refusals and
// the exactly-one-form rule) and one test per shape-defect category, each built by breaking
// a known-good graph in exactly one way.
import Testing
import Foundation
@testable import SZCore

/// A well-formed build graph exercising all four node forms and a bounded cycle. Its door
/// routes `build` and `settled` — the pair that used to draw as two disconnected fragments.
private func makeBuildGraph() -> SZAgentGraph {
    SZAgentGraph(
        name: "build",
        label: "Directed",
        caps: .init(rounds: 2),
        nodes: [
            .init(id: "message", title: "On message", form: .message(.init())),
            .init(id: "plan", title: "Plan contracts", form: .turn(.init(brief: "prompts/decompose.md.mustache"))),
            .init(id: "work-left", form: .step(name: "work-left")),
            .init(id: "unblock", title: "Unblock", form: .turn(.init(brief: "prompts/unblock.md.mustache"))),
            .init(id: "implement", title: "Dispatch fleet", form: .dispatch(.init(to: "coding", items: "workSet"))),
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

struct SZAgentGraphTests {

    // MARK: - Wire format

    @Test func aGraphRoundTripsThroughItsWireFormat() throws {
        let graph = makeBuildGraph()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(graph)
        let decoded = try JSONDecoder().decode(SZAgentGraph.self, from: data)
        #expect(decoded == graph)
    }

    @Test func anOmittedSessionMeansSpawn() throws {
        let json = #"{"name": "x", "nodes": [{"id": "a", "turn": {"brief": "b.md.mustache"}}]}"#
        let graph = try JSONDecoder().decode(SZAgentGraph.self, from: Data(json.utf8))
        guard case .turn(let turn) = graph.nodes[0].form else {
            Issue.record("expected a turn node")
            return
        }
        #expect(turn.session == .spawn)
    }

    @Test func theDoorsPortsAreTheGraphsRoutes() throws {
        let json = #"""
        {"name": "chat",
         "nodes": [{"id": "message", "onMessage": {}},
                   {"id": "reply", "turn": {"brief": "prompts/chat.md.mustache", "session": "message"}}],
         "edges": [{"from": "message", "outcome": "chat", "to": "reply"}]}
        """#
        let graph = try JSONDecoder().decode(SZAgentGraph.self, from: Data(json.utf8))
        // The entry map is not stored any more — it is READ OFF the door's out-edges, which
        // is exactly why the door draws and the map never could.
        #expect(graph.routes == [.chat: "reply"])
        #expect(graph.handles(.chat))
        #expect(!graph.handles(.build))
        #expect(graph.messageNode?.id == "message")
        #expect(graph.defects().isEmpty)
    }

    @Test func theRetiredEntryAndKindKeysAreRefusedByName() {
        // Not migrated, and not silently ignored either: a pack written for the entry-map
        // era would otherwise load and route nothing.
        for json in [#"{"name": "x", "kind": "build", "nodes": []}"#,
                     #"{"name": "x", "entry": "a", "nodes": []}"#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(SZAgentGraph.self, from: Data(json.utf8))
            }
        }
    }

    @Test func aNodeWithTwoFormsIsUnrepresentable() {
        let json = #"{"name": "x", "nodes": [{"id": "a", "step": "s", "turn": {"brief": "b.md.mustache"}}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SZAgentGraph.self, from: Data(json.utf8))
        }
    }

    @Test func aNodeWithNoFormIsUnrepresentable() {
        let json = #"{"name": "x", "nodes": [{"id": "a"}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SZAgentGraph.self, from: Data(json.utf8))
        }
    }

    @Test func aMessageNodeRoundTripsAsItsOwnForm() throws {
        let json = #"{"name": "x", "nodes": [{"id": "message", "onMessage": {}}]}"#
        let graph = try JSONDecoder().decode(SZAgentGraph.self, from: Data(json.utf8))
        guard case .message = graph.nodes[0].form else {
            Issue.record("expected a message node")
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let back = try JSONDecoder().decode(SZAgentGraph.self, from: encoder.encode(graph))
        #expect(back == graph)
    }

    // MARK: - Shape defects, one per category

    @Test func theWellFormedGraphValidatesClean() {
        #expect(makeBuildGraph().defects().isEmpty)
    }

    @Test func duplicateNodeIDs() {
        var graph = makeBuildGraph()
        graph.nodes.append(.init(id: "plan", form: .step(name: "shadow")))
        #expect(graph.defects().contains(.duplicateNode(id: "plan")))
    }

    @Test func aDoorlessGraphIsRefused() {
        var graph = makeBuildGraph()
        graph.nodes.removeAll { $0.id == "message" }
        graph.edges.removeAll { $0.from == "message" }
        #expect(graph.defects().contains(.noMessageNode))
    }

    @Test func aSecondDoorIsRefused() {
        var graph = makeBuildGraph()
        graph.nodes.append(.init(id: "side", form: .message(.init())))
        #expect(graph.defects().contains(.severalMessageNodes(ids: ["message", "side"])))
    }

    @Test func nothingMayRouteBackIntoTheDoor() {
        // A message ARRIVES; it is never a destination. Without this a graph could pretend
        // to loop through its own inbox.
        var graph = makeBuildGraph()
        graph.edges.append(.init(from: "unblock", outcome: "error", to: "message"))
        #expect(graph.defects().contains(.edgeIntoMessage(from: "unblock")))
    }

    @Test func steerCanNeverBeRouted() {
        // No rule of its own: `steer` simply is not in the door's declared outcome set.
        var graph = makeBuildGraph()
        graph.edges.append(.init(from: "message", outcome: "steer", to: "plan"))
        #expect(graph.defects().contains(.undeclaredOutcome(node: "message", outcome: "steer")))
    }

    @Test func aPortNamingSomethingThatIsNotAKindIsRefused() {
        var graph = makeBuildGraph()
        graph.edges.append(.init(from: "message", outcome: "whenever", to: "plan"))
        #expect(graph.defects().contains(.undeclaredOutcome(node: "message", outcome: "whenever")))
    }

    @Test func aNodeTheDoorCannotReachIsRefused() {
        // THE regression test for the two-disconnected-pieces complaint: a lane with no way
        // in is now a load defect, not something to notice on a canvas.
        var graph = makeBuildGraph()
        graph.nodes.append(.init(id: "orphan", form: .step(name: "orphan")))
        #expect(graph.defects().contains(.unreachable(nodes: ["orphan"])))
    }

    @Test func aNodeReachableFromTwoLanesIsRefused() {
        // Steps and briefs are typed to ONE kind's facts, so a node serving two lanes has
        // no checkable type — merging kinds into a file must not merge them into a node.
        var graph = makeBuildGraph()
        graph.edges.append(.init(from: "message", outcome: "chat", to: "plan"))
        #expect(graph.defects().contains(.laneImpure(node: "plan", lanes: ["build", "chat"])))
    }

    @Test func aSettledPortSharesTheBuildLane() {
        // `settled` folds into `build`, so the shipped shape — a build lane and its settled
        // re-entry meeting at `work-left` — is lane-PURE, not impure.
        let graph = makeBuildGraph()
        #expect(graph.kinds(reaching: "work-left") == [.build, .settled])
        #expect(graph.lanes(reaching: "work-left") == [.build])
        #expect(graph.defects().isEmpty)
    }

    @Test func danglingEdges() {
        var graph = makeBuildGraph()
        graph.edges.append(.init(from: "plan", outcome: "error", to: "nowhere"))
        #expect(graph.defects().contains(.danglingEdge(from: "plan", to: "nowhere")))
    }

    @Test func dispatchIsSendAndConclude() {
        var graph = makeBuildGraph()
        graph.edges.append(.init(from: "implement", outcome: "sent", to: "plan"))
        #expect(graph.defects().contains(.edgeFromDispatch(node: "implement")))
    }

    @Test func aTurnOnlySpeaksOkOrError() {
        var graph = makeBuildGraph()
        graph.edges.append(.init(from: "plan", outcome: "maybe", to: "work-left"))
        #expect(graph.defects().contains(.undeclaredOutcome(node: "plan", outcome: "maybe")))
    }

    @Test func boundsBelowOneAreRefused() {
        var graph = makeBuildGraph()
        let leash = graph.edges.firstIndex { $0.from == "work-left" && $0.outcome == "no" }!
        graph.edges[leash].maxTraversals = 0
        #expect(graph.defects().contains(.nonPositiveBound(from: "work-left", outcome: "no")))
    }

    @Test func aSecondEdgeOnTheSameOutcomeIsRefused() {
        var graph = makeBuildGraph()
        graph.edges.append(.init(from: "work-left", outcome: "yes", to: "unblock"))
        #expect(graph.defects().contains(.duplicateEdge(from: "work-left", outcome: "yes")))
    }

    @Test func roundsBelowOneAreRefused() {
        var graph = makeBuildGraph()
        graph.caps = .init(rounds: 0)
        #expect(graph.defects().contains(.nonPositiveRounds(0)))
    }

    @Test func aCycleMustCrossABoundedEdge() {
        var graph = makeBuildGraph()
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
        var graph = makeBuildGraph()
        graph.nodes.append(.init(id: "orphan", form: .step(name: "orphan")))
        graph.edges.append(.init(from: "plan", outcome: "error", to: "nowhere"))
        graph.edges.append(.init(from: "implement", outcome: "sent", to: "plan"))
        #expect(graph.defects().count >= 3)
    }

    // MARK: - Lookup

    @Test func edgeLookupFollowsOutcomeAndAbsenceEndsTheTraversal() {
        let graph = makeBuildGraph()
        #expect(graph.edge(from: "work-left", outcome: "yes")?.to == "implement")
        #expect(graph.edge(from: "work-left", outcome: "declined") == nil)
    }
}
