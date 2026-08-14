// SPDX-License-Identifier: AGPL-3.0-only
// The RUNS list's naming rules: the agent title joins against the same `planAgents` the
// Plan view browses (degrading to the raw pack id), and the row's context line is the
// record's OWN door ruling — the first trace entry's outcome.
import Foundation
import Testing
import SZCore
@testable import SZUI

private let library = SZAgentGraphNaming(agents: [
    SZAgentGraphPlanAgent(
        id: "director", title: "Director", symbol: "eyeglasses",
        graph: SZAgentGraph(
            label: "Director",
            nodes: [SZAgentGraph.Node(id: "door", form: .step(name: "door")),
                    SZAgentGraph.Node(id: "a", form: .step(name: "a"))],
            edges: [.init(from: "door", outcome: "build", to: "a")]),
        seat: "director"),
])

private func run(agent: String, trace: [SZAgentGraphRun.Entry] = []) -> SZAgentGraphRun {
    SZAgentGraphRun(id: UUID(), agent: agent, trace: trace)
}

@Test func aKnownRecordReadsAsItsAgentTitle() {
    #expect(library.agentTitle(run(agent: "director")) == "Director")
}

@Test func anAgentTheLibraryNoLongerCarriesReadsAsItsPackID() {
    // An archived record whose pack was replaced — the row still says something true.
    #expect(library.agentTitle(run(agent: "retired")) == "retired")
}

@Test func theContextLineIsTheDoorsOwnRuling() {
    let ruled = run(agent: "director", trace: [
        .init(ordinal: 1, node: "door", phase: .done, outcome: "answer"),
    ])
    #expect(SZAgentGraphNaming.doorRuling(ruled) == "answer")
    // The door still deciding (or a truncated record) reads as an honest ellipsis.
    let deciding = run(agent: "director", trace: [
        .init(ordinal: 1, node: "door", phase: .running),
    ])
    #expect(SZAgentGraphNaming.doorRuling(deciding) == "…")
    #expect(SZAgentGraphNaming.doorRuling(run(agent: "director")) == "…")
}
