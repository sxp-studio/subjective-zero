// SPDX-License-Identifier: AGPL-3.0-only
// The graph model's gate: wire-format round-trips (including the entry sugar and the
// exactly-one-form rule) and one test per shape-defect category, each built by breaking a
// known-good graph in exactly one way.
import Testing
import Foundation
@testable import SZCore

/// A well-formed build graph exercising all three node forms and a bounded cycle.
private func makeBuildGraph() -> SZAgentGraph {
    SZAgentGraph(
        name: "build",
        kind: .build,
        label: "Directed",
        caps: .init(rounds: 2),
        entry: [.build: "plan", .settled: "work-left"],
        nodes: [
            .init(id: "plan", title: "Plan contracts", form: .turn(.init(brief: "prompts/decompose.md.mustache"))),
            .init(id: "work-left", form: .step(name: "work-left")),
            .init(id: "unblock", title: "Unblock", form: .turn(.init(brief: "prompts/unblock.md.mustache"))),
            .init(id: "implement", title: "Dispatch fleet", form: .dispatch(.init(to: "coding", items: "workSet"))),
        ],
        edges: [
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

    @Test func bareEntryStringMeansTheGraphsOwnKind() throws {
        let json = #"{"name": "chat", "kind": "chat", "entry": "reply", "nodes": [{"id": "reply", "turn": {"brief": "prompts/chat.md.mustache", "session": "message"}}]}"#
        let graph = try JSONDecoder().decode(SZAgentGraph.self, from: Data(json.utf8))
        #expect(graph.entry == [.chat: "reply"])
        #expect(graph.defects().isEmpty)
    }

    @Test func aNodeWithTwoFormsIsUnrepresentable() {
        let json = #"{"name": "x", "kind": "build", "entry": "a", "nodes": [{"id": "a", "step": "s", "turn": {"brief": "b.md.mustache"}}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SZAgentGraph.self, from: Data(json.utf8))
        }
    }

    @Test func aNodeWithNoFormIsUnrepresentable() {
        let json = #"{"name": "x", "kind": "build", "entry": "a", "nodes": [{"id": "a"}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SZAgentGraph.self, from: Data(json.utf8))
        }
    }

    @Test func anUnknownEntryKindIsRefusedAtDecode() {
        let json = #"{"name": "x", "kind": "build", "entry": {"run": "a"}, "nodes": [{"id": "a", "step": "s"}]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SZAgentGraph.self, from: Data(json.utf8))
        }
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

    @Test func entryNamingAnUnknownNode() {
        var graph = makeBuildGraph()
        graph.entry[.build] = "ghost"
        #expect(graph.defects().contains(.unknownEntry(kind: .build, node: "ghost")))
    }

    @Test func steerCanNeverBeAnEntry() {
        var graph = makeBuildGraph()
        graph.entry[.steer] = "plan"
        #expect(graph.defects().contains(.entryKindNotEnterable(.steer)))
    }

    @Test func aGraphMustEnterOnItsOwnKind() {
        var graph = makeBuildGraph()
        graph.entry[.build] = nil
        #expect(graph.defects().contains(.missingOwnEntry(.build)))
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
        graph.edges[2].maxTraversals = 0
        #expect(graph.defects().contains(.nonPositiveBound(from: "work-left", outcome: "no")))
    }

    @Test func aCycleMustCrossABoundedEdge() {
        var graph = makeBuildGraph()
        graph.edges[2].maxTraversals = nil   // work-left → unblock → work-left, now leashless
        let cycles = graph.defects().filter {
            if case .unboundedCycle = $0 { return true } else { return false }
        }
        #expect(cycles.count == 1)
    }

    @Test func allDefectsAreCollectedNotFirstError() {
        var graph = makeBuildGraph()
        graph.entry[.build] = "ghost"
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
