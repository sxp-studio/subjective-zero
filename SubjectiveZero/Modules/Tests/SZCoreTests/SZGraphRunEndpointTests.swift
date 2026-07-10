// SPDX-License-Identifier: AGPL-3.0-only
// Which node a finished run should put on screen. The MCP surface can't set this up — a draft prompt node
// exposes only flow sockets, so an upstream data edge can't be drawn until the node is implemented — so
// the rule is pinned here, on the graph, where it is pure.
import Testing
@testable import SZCore

private func texNode(_ title: String, display: Bool = true, inputs: [String] = []) -> SZNode {
    var node = SZNode(kind: .generated, title: title, position: SZPoint(x: 0, y: 0))
    node.contract = SZNodeContract(
        title: title, sfSymbol: "circle", summary: "",
        inputs: inputs.map { SZPort(name: $0, type: .texture) },
        outputs: [SZPort(name: "output", type: .texture, display: display ? true : nil)])
    return node
}

private func data(_ from: SZNode, _ to: SZNode) -> SZConnection {
    SZConnection(from: SZPortRef(node: from.id, port: "output"),
                 to: SZPortRef(node: to.id, port: "input"), kind: .data)
}

@Test func aStandaloneNodeTheRunBuiltTakesTheViewport() {
    let teal = texNode("Teal Fill")
    var graph = SZGraph()
    graph.nodes = [texNode("Animated Gradient"), teal]   // the gradient predates the run
    let ref = graph.runRenderEndpoint(workSet: [teal.id])
    #expect(ref == SZPortRef(node: teal.id, port: "output"))
}

/// The case the demo would have hit: a node spliced upstream of an existing composite is the run's last
/// node but not the graph's output. Showing it would hide the result it feeds.
@Test func aNodeBuiltUpstreamOfAnExistingOutputDoesNotTakeTheViewport() {
    let blur = texNode("Blur")
    let composite = texNode("Composite", inputs: ["input"])
    var graph = SZGraph()
    graph.nodes = [composite, blur]
    graph.connections = [data(blur, composite)]
    #expect(graph.runRenderEndpoint(workSet: [blur.id]) == nil)   // composite isn't ours to claim
}

@Test func aChainBuiltByTheRunShowsItsLastStage() {
    let first = texNode("Stage 1")
    let last = texNode("Stage 2", inputs: ["input"])
    var graph = SZGraph()
    graph.nodes = [first, last]
    graph.connections = [data(first, last)]
    let ref = graph.runRenderEndpoint(workSet: [first.id, last.id])
    #expect(ref?.node == last.id)
}

@Test func amongSeveralSinksTheNewestWins() {
    let older = texNode("Older")
    let newer = texNode("Newer")
    var graph = SZGraph()
    graph.nodes = [older, newer]   // append order == creation order
    #expect(graph.runRenderEndpoint(workSet: [older.id, newer.id])?.node == newer.id)
}

@Test func nodesOutsideTheRunAreNeverAdopted() {
    let mine = texNode("Mine")
    let theirs = texNode("Theirs")
    var graph = SZGraph()
    graph.nodes = [mine, theirs]
    #expect(graph.runRenderEndpoint(workSet: [mine.id])?.node == mine.id)
    #expect(graph.runRenderEndpoint(workSet: [])  == nil)
}

/// `draftContractsFromFlow` gives a drawn node a texture contract BEFORE the run, so a node whose agent
/// timed out still declares an `output` it cannot render. Adopting it would swap the user's viewport for a
/// black one. Only a node promoted to `.generated` — i.e. one whose source compiled — may be shown.
@Test func aNodeThatNeverCompiledIsNotAdoptedEvenThoughItDeclaresATextureOutput() {
    var drafted = SZNode(kind: .prompt, title: "Timed out", position: SZPoint(x: 0, y: 0))
    drafted.contract = SZNodeContract(title: "Timed out", sfSymbol: "circle", summary: "",
                                      outputs: [SZPort(name: "output", type: .texture, display: true)])
    var graph = SZGraph()
    graph.nodes = [drafted]
    #expect(graph.runRenderEndpoint(workSet: [drafted.id]) == nil)

    // …and a run that half-succeeded shows the node that actually compiled.
    let built = texNode("Built")
    graph.nodes = [drafted, built]
    #expect(graph.runRenderEndpoint(workSet: [drafted.id, built.id])?.node == built.id)
}

@Test func aRunThatBuiltNothingRenderableAdoptsNothing() {
    var node = SZNode(kind: .generated, title: "Analysis", position: SZPoint(x: 0, y: 0))
    node.contract = SZNodeContract(title: "Analysis", sfSymbol: "circle", summary: "",
                                   outputs: [SZPort(name: "level", type: .float)])
    var graph = SZGraph()
    graph.nodes = [node]
    #expect(graph.runRenderEndpoint(workSet: [node.id]) == nil)
    // A contract-less draft is likewise unrenderable.
    var draft = SZGraph()
    draft.nodes = [SZNode(kind: .prompt, title: "Draft", position: SZPoint(x: 0, y: 0))]
    #expect(draft.runRenderEndpoint(workSet: [draft.nodes[0].id]) == nil)
}

/// Flow edges are authoring intent, not dataflow — a flow-connected node is still a data sink. The edge
/// must leave the node we expect to win, or a missing `.kind == .data` filter would go unnoticed.
@Test func flowEdgesDoNotDisqualifyASink() {
    let a = texNode("A"), b = texNode("B")
    var graph = SZGraph()
    graph.nodes = [a, b]                                     // b is newest, so b should win
    graph.connections = [SZConnection(from: SZPortRef(node: b.id, port: ""),
                                      to: SZPortRef(node: a.id, port: ""), kind: .flow)]
    #expect(graph.runRenderEndpoint(workSet: [a.id, b.id])?.node == b.id)
}

@Test func anUndisplayedTextureOutputIsStillShown() {
    // The teal-fill agent named its output "fill" and set no `display` flag; it must still be adoptable.
    var node = SZNode(kind: .generated, title: "Teal", position: SZPoint(x: 0, y: 0))
    node.contract = SZNodeContract(title: "Teal", sfSymbol: "circle", summary: "",
                                   outputs: [SZPort(name: "fill", type: .texture)])
    var graph = SZGraph()
    graph.nodes = [node]
    #expect(graph.runRenderEndpoint(workSet: [node.id]) == SZPortRef(node: node.id, port: "fill"))
}

@Test func aDisplayMarkedOutputIsPreferredOverAnotherTexture() {
    var node = SZNode(kind: .generated, title: "Two", position: SZPoint(x: 0, y: 0))
    node.contract = SZNodeContract(title: "Two", sfSymbol: "circle", summary: "",
                                   outputs: [SZPort(name: "aux", type: .texture),
                                             SZPort(name: "main", type: .texture, display: true)])
    var graph = SZGraph()
    graph.nodes = [node]
    #expect(graph.runRenderEndpoint(workSet: [node.id])?.port == "main")
}
