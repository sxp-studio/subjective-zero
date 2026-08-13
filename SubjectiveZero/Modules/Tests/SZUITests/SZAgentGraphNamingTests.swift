// SPDX-License-Identifier: AGPL-3.0-only
// The RUNS list's naming rule: a record carries a pack id and a graph STEM, and the rows
// display an agent title and the graph's authored LABEL. The join is against the same
// `planAgents` the Plan view browses, so this is the one place it can rot — and the two
// degradation paths (an agent the library dropped, a graph with no label) are the whole
// reason the rule is a value rather than two inline lookups.
import Foundation
import Testing
import SZCore
@testable import SZUI

private func graph(_ name: String, label: String?) -> SZAgentGraph {
    SZAgentGraph(name: name, label: label,
                 nodes: [SZAgentGraph.Node(id: "message", form: .message(.init())),
                         SZAgentGraph.Node(id: "a", form: .step(name: "a"))],
                 edges: [.init(from: "message", outcome: "build", to: "a")])
}

private let library = SZAgentGraphNaming(agents: [
    SZAgentGraphPlanAgent(
        id: "director", title: "Director", symbol: "eyeglasses",
        graphs: [.init(name: "agentic", graph: graph("agentic", label: "Agentic")),
                 .init(name: "bare", graph: graph("bare", label: nil))],
        defaultGraphName: "agentic", seat: "director"),
])

private func run(agent: String, graphName: String) -> SZAgentGraphRun {
    SZAgentGraphRun(id: UUID(), agent: agent, graphName: graphName, kind: .build)
}

@Test func aKnownRecordReadsAsItsAgentAndTheGraphsLabel() {
    let record = run(agent: "director", graphName: "agentic")
    #expect(library.agentTitle(record) == "Director")
    #expect(library.graphLabel(record) == "Agentic")
}

@Test func anAgentTheLibraryNoLongerCarriesReadsAsItsPackID() {
    // An archived record whose pack was replaced — the row still says something true.
    let record = run(agent: "retired", graphName: "agentic")
    #expect(library.agentTitle(record) == "retired")
    #expect(library.graphLabel(record) == "agentic")
}

@Test func aGraphTheLibraryNoLongerCarriesReadsAsItsStem() {
    let record = run(agent: "director", graphName: "deleted")
    #expect(library.agentTitle(record) == "Director")
    #expect(library.graphLabel(record) == "deleted")
}

@Test func aGraphWithNoAuthoredLabelReadsAsItsStem() {
    // `label` is optional in the model; a pack that omits it must still name its rows.
    #expect(library.graphLabel(run(agent: "director", graphName: "bare")) == "bare")
}
