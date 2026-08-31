// SPDX-License-Identifier: AGPL-3.0-only
// A turn card's source pill: browsing a graph opens the mustache brief; a visit that RAN
// points at the prompt it sent, resolved by its turn id.
import Foundation
import Testing
import SZCore
@testable import SZUI

@MainActor
struct SZAgentGraphSentPromptTests {

    private let graph = SZAgentGraph(
        nodes: [
            SZAgentGraph.Node(id: "door", form: .step(name: "door")),
            SZAgentGraph.Node(id: "decompose", title: "Decompose",
                              form: .turn(.init(brief: "decompose"))),
        ],
        edges: [SZAgentGraph.Edge(from: "door", outcome: "work", to: "decompose")])

    @Test func browsingAGraphTheTurnPillOpensItsTemplate() throws {
        let node = try #require(graph.node("decompose"))
        #expect(SZAgentGraphLayout.face(of: node, in: graph).source
                == .brief(path: "prompts/decompose.md.mustache"))
    }

    @Test func aVisitThatRanATurnPointsAtThePromptItSent() throws {
        let turnID = UUID()
        let entry = SZAgentGraphRun.Entry(ordinal: 2, node: "decompose", phase: .done,
                                          outcome: "ok", turnID: turnID)
        #expect(SZAgentGraphLayout.runFace(for: entry, in: graph).source
                == .sentPrompt(turnID: turnID, template: "prompts/decompose.md.mustache"))
    }

    @Test func aVisitWithNoTurnKeepsTheTemplate() throws {
        // A record written before the stamp existed, or a visit that ran no turn at all: there is
        // no rendered prompt to point at, so the authored brief stands.
        let entry = SZAgentGraphRun.Entry(ordinal: 2, node: "decompose", phase: .done, outcome: "ok")
        #expect(SZAgentGraphLayout.runFace(for: entry, in: graph).source
                == .brief(path: "prompts/decompose.md.mustache"))
    }

    @Test func aStepVisitIsUnaffectedByItsTurnID() throws {
        // Only a brief source is swapped. A step's Swift is the same file whether it ran or not.
        let entry = SZAgentGraphRun.Entry(ordinal: 1, node: "door", phase: .done, outcome: "work",
                                          turnID: UUID())
        #expect(SZAgentGraphLayout.runFace(for: entry, in: graph).source == .step(name: "door"))
    }
}
