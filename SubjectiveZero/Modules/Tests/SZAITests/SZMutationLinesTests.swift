// SPDX-License-Identifier: AGPL-3.0-only
// The reconcile brief's `{{mutations}}` section: one line per journal entry led by its actor
// (USER / DIRECTOR / EXTERNAL / the Coding Agent's node title), the empty-delta line, the burst
// folding + line cap that keep a long run readable, and the token being known to the renderer
// and the pack gate.
import Foundation
import Testing
import SZCore
@testable import SZAI

private let plasmaID = SZNodeID()
private let graph = SZGraph(nodes: [
    SZNode(id: plasmaID, kind: .generated, title: "Plasma", position: SZPoint(x: 0, y: 0)),
])

@Test func mutationLinesNameTheActorAndTheSubjects() {
    let lines = SZDirectorPrompt.mutationLines([
        SZGraphMutation(actor: .user, kind: "connected", subjects: ["Plasma.output → Left face.input"]),
        SZGraphMutation(actor: .agent(plasmaID), kind: "toggled display", subjects: ["→ Plasma.output"]),
        SZGraphMutation(actor: .director, kind: "removed node", subjects: ["Blur", "Sharpen"]),
        SZGraphMutation(actor: .agent(SZNodeID()), kind: "re-prompted", subjects: ["Gone"]),
    ], graph: graph)
    let expected = [
        "- USER connected Plasma.output → Left face.input",
        "- Coding Agent (Plasma) toggled display → Plasma.output",
        "- DIRECTOR removed node Blur, Sharpen",
    ]
    #expect(lines.hasPrefix(expected.joined(separator: "\n")))
    // A node no longer in the graph falls back to its short id — never a crash, never a blank.
    #expect(lines.contains("- Coding Agent (") && lines.hasSuffix(") re-prompted Gone"))
}

@Test func anUnattributedCallerIsExternalNeverTheDirector() {
    #expect(SZDirectorPrompt.mutationLines(
        [SZGraphMutation(actor: .external, kind: "connected", subjects: ["A.out → B.in"])], graph: nil)
        == "- EXTERNAL connected A.out → B.in")
}

@Test func aBurstOfTheSameEditFoldsToItsLatestState() {
    let nudges = (1...5).map {
        SZGraphMutation(actor: .user, kind: "set default", subjects: ["Plasma.amount = 0.\($0)"])
    }
    let lines = SZDirectorPrompt.mutationLines(nudges + [
        SZGraphMutation(actor: .user, kind: "connected", subjects: ["A.out → B.in"]),
        // The same port again, but no longer consecutive — a separate decision, its own line.
        SZGraphMutation(actor: .user, kind: "set default", subjects: ["Plasma.amount = 0.9"]),
    ], graph: graph)
    #expect(lines == """
    - USER set default Plasma.amount = 0.5 (×5)
    - USER connected A.out → B.in
    - USER set default Plasma.amount = 0.9
    """)
}

@Test func aLongDeltaKeepsTheNewestLinesAndCountsTheRest() {
    let cap = SZDirectorPrompt.mutationLineCap
    let many = (0..<(cap + 7)).map {
        SZGraphMutation(actor: .user, kind: "connected", subjects: ["A\($0).out → B.in"])
    }
    let lines = SZDirectorPrompt.mutationLines(many, graph: nil).components(separatedBy: "\n")
    #expect(lines.count == cap + 1)
    #expect(lines.first == "- (… and 7 earlier edits)")
    #expect(lines[1] == "- USER connected A7.out → B.in")
    #expect(lines.last == "- USER connected A\(cap + 6).out → B.in")
}

@Test func anEmptyDeltaSaysSo() {
    #expect(SZDirectorPrompt.mutationLines([], graph: nil) == "- (nothing changed since your last turn)")
}

@Test func theRendererFillsTheMutationsToken() throws {
    let r = SZBriefRenderer { _, _ in "## Changes\n{{mutations}}\n" }
    let world = SZWorld(graph: graph, mutations: [
        SZGraphMutation(actor: .user, kind: "connected", subjects: ["A.out → B.in"]),
    ])
    let out = try r.render(agent: "director", template: "reconcile", message: "", world: world)
    #expect(out == "## Changes\n- USER connected A.out → B.in\n")
    #expect(try r.render(agent: "director", template: "reconcile", message: "", world: SZWorld())
            == "## Changes\n- (nothing changed since your last turn)\n")
    #expect(SZBriefRenderer.knownTokens.contains("mutations"))
}
