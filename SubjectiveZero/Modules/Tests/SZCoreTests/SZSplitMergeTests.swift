// SPDX-License-Identifier: AGPL-3.0-only
// Split/merge as atomic graph transactions with contract reconciliation. Exercised through
// the `SZStore.splitNode`/`mergeNodes` ops (which wrap the pure `SZGraphSurgery` helpers), so both the
// SwiftUI editor and the `ui_*` MCP handlers inherit the tested behaviour. Deterministic + headless:
// asserts external wiring + render endpoint preservation, the internal boundary edge, drafted boundary
// contracts, chain validation, and a split→merge round-trip of the external boundary.
import Foundation
import Testing
@testable import SZCore

// MARK: - Fixtures

/// A src → N → sink pipeline with N generated (input "in" texture, output "out" texture display) and the
/// render endpoint on N.out — exercises external incoming + outgoing rewiring and the endpoint move.
@MainActor
private func pipelineStore() -> (store: SZStore, src: SZNodeID, n: SZNodeID, sink: SZNodeID) {
    let src = SZNode(
        kind: .generated, title: "Source", sfSymbol: "circle",
        contract: SZNodeContract(title: "Source", sfSymbol: "circle", summary: "src",
            outputs: [SZPort(name: "out", type: .texture)]),
        position: SZPoint(x: 0, y: 0))
    let n = SZNode(
        kind: .generated, title: "Grayscale Camera", sfSymbol: "camera",
        contract: SZNodeContract(title: "Grayscale Camera", sfSymbol: "camera", summary: "the effect",
            inputs: [SZPort(name: "in", type: .texture)],
            outputs: [SZPort(name: "out", type: .texture, display: true)],
            permissions: [.camera]),
        position: SZPoint(x: 200, y: 0))
    let sink = SZNode(
        kind: .generated, title: "Sink", sfSymbol: "square",
        contract: SZNodeContract(title: "Sink", sfSymbol: "square", summary: "sink",
            inputs: [SZPort(name: "in", type: .texture)]),
        position: SZPoint(x: 400, y: 0))
    var graph = SZGraph(nodes: [src, n, sink])
    graph.connections.append(SZConnection(from: SZPortRef(node: src.id, port: "out"),
        to: SZPortRef(node: n.id, port: "in"), kind: .data))
    graph.connections.append(SZConnection(from: SZPortRef(node: n.id, port: "out"),
        to: SZPortRef(node: sink.id, port: "in"), kind: .data))
    graph.ensureFlow(from: src.id, to: n.id)
    graph.ensureFlow(from: n.id, to: sink.id)
    graph.renderEndpoint = SZPortRef(node: n.id, port: "out")
    let store = SZStore()
    store.setProject(SZProject(name: "Pipeline", graph: graph))
    return (store, src.id, n.id, sink.id)
}

/// The canonical two-node grayscale camera: Camera (texture out) → Grayscale (texture in → out display),
/// render endpoint on Grayscale.output. Used for the merge boundary + round-trip tests.
@MainActor
private func grayscaleCameraStore() -> (store: SZStore, cam: SZNodeID, gray: SZNodeID) {
    let cam = SZNode(
        kind: .generated, title: "MacBook Camera", sfSymbol: "camera",
        contract: SZNodeContract(title: "MacBook Camera", sfSymbol: "camera", summary: "camera feed",
            outputs: [SZPort(name: "texture", type: .texture)], permissions: [.camera]),
        position: SZPoint(x: 0, y: 0))
    let gray = SZNode(
        kind: .generated, title: "Make Grayscale", sfSymbol: "circle.lefthalf.filled",
        contract: SZNodeContract(title: "Make Grayscale", sfSymbol: "circle.lefthalf.filled",
            summary: "luminance",
            inputs: [SZPort(name: "input", type: .texture)],
            outputs: [SZPort(name: "output", type: .texture, display: true)]),
        position: SZPoint(x: 200, y: 0))
    var graph = SZGraph(nodes: [cam, gray])
    graph.connections.append(SZConnection(from: SZPortRef(node: cam.id, port: "texture"),
        to: SZPortRef(node: gray.id, port: "input"), kind: .data))
    graph.ensureFlow(from: cam.id, to: gray.id)
    graph.renderEndpoint = SZPortRef(node: gray.id, port: "output")
    let store = SZStore()
    store.setProject(SZProject(name: "GrayscaleCamera", graph: graph))
    return (store, cam.id, gray.id)
}

// MARK: - Split

@MainActor
@Test func splitReconcilesWiringEndpointAndBoundary() throws {
    let (store, src, n, sink) = pipelineStore()
    let pieces = try #require(store.splitNode(id: n, pieces: 2))
    #expect(pieces.count == 2)
    let p1 = pieces[0], p2 = pieces[1]
    let g = try #require(store.project?.graph)

    // N is gone; src + sink + 2 pieces remain.
    #expect(g.node(id: n) == nil)
    #expect(g.nodes.count == 4)
    #expect(g.node(id: p1)?.kind == .prompt)
    #expect(g.node(id: p2)?.kind == .prompt)
    #expect(g.node(id: p1)?.title == "Grayscale Camera (1/2)")   // structural placeholder label
    #expect(g.node(id: p1)?.prompt == nil)                       // host authors the seed prompt (Step 2)

    // External wiring preserved: incoming retargets to the first piece, outgoing to the last.
    let data = g.connections.filter { $0.kind == .data }
    #expect(data.contains { $0.from.node == src && $0.to.node == p1 && $0.to.port == "in" })
    #expect(data.contains { $0.from.node == p2 && $0.from.port == "out" && $0.to.node == sink })
    // Internal texture boundary edge between the pieces (data only — split creates no companion flow).
    #expect(data.contains { $0.from.node == p1 && $0.from.port == "output" && $0.to.node == p2 && $0.to.port == "input" })

    // Render endpoint moved to the last piece, port preserved.
    #expect(g.renderEndpoint == SZPortRef(node: p2, port: "out"))

    // Drafted boundary contracts.
    let c1 = try #require(g.node(id: p1)?.contract)
    let c2 = try #require(g.node(id: p2)?.contract)
    #expect(c1.inputs.map(\.name) == ["in"])                 // N's external inputs
    #expect(c1.outputs.map(\.name) == ["output"])            // internal texture boundary
    #expect(c1.outputs.first?.type == .texture)
    #expect(c1.permissions == [.camera])                     // source piece carries N's permissions
    #expect(c2.inputs.map(\.name) == ["input"])              // internal texture boundary
    #expect(c2.inputs.first?.type == .texture)
    #expect(c2.outputs.map(\.name) == ["out"])               // N's external outputs
    #expect(c2.outputs.first?.display == true)               // display flag preserved
    #expect(c2.permissions == nil)
}

@MainActor
@Test func splitRejectsMissingNodeAndUnderTwoPieces() {
    let (store, _, n, _) = pipelineStore()
    #expect(store.splitNode(id: SZNodeID(), pieces: 2) == nil)   // missing node
    #expect(store.splitNode(id: n, pieces: 1) == nil)            // < 2 pieces
    #expect(SZStore().splitNode(id: n, pieces: 2) == nil)        // no project loaded
}

// MARK: - Merge

@MainActor
@Test func mergeReconcilesExternalBoundaryDropsInternalAndMovesEndpoint() throws {
    let (store, cam, gray) = grayscaleCameraStore()
    let merged = try #require(store.mergeNodes(ids: [cam, gray]))
    let g = try #require(store.project?.graph)

    #expect(g.nodes.count == 1)
    let node = try #require(g.node(id: merged))
    #expect(node.kind == .prompt)
    #expect(node.title == "MacBook Camera + Make Grayscale")
    #expect(node.prompt == nil)                                  // host authors the seed prompt (Step 2)

    // Internal edges (data + flow) dropped; nothing external on either side → no connections remain.
    #expect(g.connections.isEmpty)

    // Boundary: a source→display chain has no external inputs; its sole output is the render endpoint.
    let c = try #require(node.contract)
    #expect(c.inputs.isEmpty)
    #expect(c.outputs.map(\.name) == ["output"])
    #expect(c.outputs.first?.display == true)
    #expect(c.permissions == [.camera])                  // union of constituents' permissions
    #expect(g.renderEndpoint == SZPortRef(node: merged, port: "output"))
}

@MainActor
@Test func mergeRewiresExternalNeighboursToTheMergedNode() throws {
    // src → A → B → sink: merging [A, B] keeps src→M and M→sink, drops the internal A→B edge.
    let src = SZNode(kind: .generated, title: "Src", contract: SZNodeContract(
        title: "Src", sfSymbol: "s", summary: "", outputs: [SZPort(name: "out", type: .texture)]),
        position: SZPoint(x: 0, y: 0))
    let a = SZNode(kind: .generated, title: "A", contract: SZNodeContract(
        title: "A", sfSymbol: "a", summary: "",
        inputs: [SZPort(name: "in", type: .texture)], outputs: [SZPort(name: "out", type: .texture)]),
        position: SZPoint(x: 100, y: 0))
    let b = SZNode(kind: .generated, title: "B", contract: SZNodeContract(
        title: "B", sfSymbol: "b", summary: "",
        inputs: [SZPort(name: "in", type: .texture)], outputs: [SZPort(name: "out", type: .texture)]),
        position: SZPoint(x: 200, y: 0))
    let sink = SZNode(kind: .generated, title: "Sink", contract: SZNodeContract(
        title: "Sink", sfSymbol: "k", summary: "", inputs: [SZPort(name: "in", type: .texture)]),
        position: SZPoint(x: 300, y: 0))
    var graph = SZGraph(nodes: [src, a, b, sink])
    for (f, fp, t, tp) in [(src.id, "out", a.id, "in"), (a.id, "out", b.id, "in"), (b.id, "out", sink.id, "in")] {
        graph.connections.append(SZConnection(from: SZPortRef(node: f, port: fp), to: SZPortRef(node: t, port: tp), kind: .data))
    }
    let store = SZStore()
    store.setProject(SZProject(name: "ABchain", graph: graph))

    let m = try #require(store.mergeNodes(ids: [a.id, b.id]))
    let g = try #require(store.project?.graph)
    #expect(g.nodes.count == 3)                                   // src, M, sink
    let data = g.connections.filter { $0.kind == .data }
    #expect(data.contains { $0.from.node == src.id && $0.to.node == m && $0.to.port == "in" })
    #expect(data.contains { $0.from.node == m && $0.from.port == "out" && $0.to.node == sink.id })
    #expect(!data.contains { $0.from.node == a.id || $0.to.node == a.id || $0.from.node == b.id || $0.to.node == b.id })
    let c = try #require(g.node(id: m)?.contract)
    #expect(c.inputs.map(\.name) == ["in"])
    #expect(c.outputs.map(\.name) == ["out"])
}

@MainActor
@Test func mergePreservesUnconnectedControlKnobs() throws {
    // A → B. A has an unconnected "mirror" knob (+ texture output); B's "input" is fed by A (internal).
    // Merging keeps A's knob (with its type/ui/default) and drops B's internal input.
    let a = SZNode(kind: .generated, title: "Camera", contract: SZNodeContract(
        title: "Camera", sfSymbol: "c", summary: "",
        inputs: [SZPort(name: "mirror", type: .bool, ui: SZPortUI(kind: .toggle), def: .bool(true))],
        outputs: [SZPort(name: "texture", type: .texture)]),
        position: SZPoint(x: 0, y: 0))
    let b = SZNode(kind: .generated, title: "Gray", contract: SZNodeContract(
        title: "Gray", sfSymbol: "g", summary: "",
        inputs: [SZPort(name: "input", type: .texture)],
        outputs: [SZPort(name: "output", type: .texture, display: true)]),
        position: SZPoint(x: 200, y: 0))
    var graph = SZGraph(nodes: [a, b])
    graph.connections.append(SZConnection(from: SZPortRef(node: a.id, port: "texture"),
        to: SZPortRef(node: b.id, port: "input"), kind: .data))
    graph.renderEndpoint = SZPortRef(node: b.id, port: "output")
    let store = SZStore(); store.setProject(SZProject(name: "Knobs", graph: graph))

    let m = try #require(store.mergeNodes(ids: [a.id, b.id]))
    let c = try #require(store.project?.graph.node(id: m)?.contract)
    #expect(c.inputs.map(\.name) == ["mirror"])          // knob preserved, internal "input" dropped
    #expect(c.inputs.first?.type == .bool)
    #expect(c.inputs.first?.def == .bool(true))           // default preserved
    #expect(c.inputs.first?.ui?.kind == .toggle)          // control preserved
    #expect(c.outputs.map(\.name) == ["output"])
    #expect(c.outputs.first?.display == true)
}

@MainActor
@Test func mergeRejectsNonChains() {
    let (store, cam, _) = grayscaleCameraStore()
    #expect(store.mergeNodes(ids: [cam]) == nil)                 // < 2 nodes
    #expect(store.mergeNodes(ids: [cam, SZNodeID()]) == nil)     // unknown node
    #expect(SZStore().mergeNodes(ids: [cam, cam]) == nil)        // no project loaded

    // Two unconnected nodes are not a chain.
    let x = SZNode(kind: .prompt, title: "X", position: SZPoint(x: 0, y: 0))
    let y = SZNode(kind: .prompt, title: "Y", position: SZPoint(x: 10, y: 0))
    let s2 = SZStore(); s2.setProject(SZProject(name: "Disconnected", graph: SZGraph(nodes: [x, y])))
    #expect(s2.mergeNodes(ids: [x.id, y.id]) == nil)

    // A fork (a → b, a → c) over {a, b, c} is not linear.
    let a = SZNode(kind: .prompt, title: "A", position: SZPoint(x: 0, y: 0))
    let b = SZNode(kind: .prompt, title: "B", position: SZPoint(x: 10, y: 0))
    let cc = SZNode(kind: .prompt, title: "C", position: SZPoint(x: 10, y: 50))
    var fg = SZGraph(nodes: [a, b, cc])
    fg.connections.append(SZConnection(from: SZPortRef(node: a.id, port: "o"), to: SZPortRef(node: b.id, port: "i"), kind: .data))
    fg.connections.append(SZConnection(from: SZPortRef(node: a.id, port: "o"), to: SZPortRef(node: cc.id, port: "i"), kind: .data))
    let s3 = SZStore(); s3.setProject(SZProject(name: "Fork", graph: fg))
    #expect(s3.mergeNodes(ids: [a.id, b.id, cc.id]) == nil)
}

// MARK: - Round-trip

@MainActor
@Test func splitThenMergeRoundTripsTheExternalBoundary() throws {
    let (store, src, n, sink) = pipelineStore()
    let pieces = try #require(store.splitNode(id: n, pieces: 2))
    let m = try #require(store.mergeNodes(ids: pieces))
    let g = try #require(store.project?.graph)

    // Back to src → M → sink with M owning the original external boundary + endpoint.
    #expect(g.nodes.count == 3)
    let data = g.connections.filter { $0.kind == .data }
    #expect(data.contains { $0.from.node == src && $0.to.node == m && $0.to.port == "in" })
    #expect(data.contains { $0.from.node == m && $0.from.port == "out" && $0.to.node == sink })
    #expect(data.filter { $0.from.node == m || $0.to.node == m }.count == 2)   // exactly the two external edges
    let c = try #require(g.node(id: m)?.contract)
    #expect(c.inputs.map(\.name) == ["in"])
    #expect(c.outputs.map(\.name) == ["out"])
    #expect(c.outputs.first?.display == true)
    #expect(c.permissions == [.camera])
    #expect(g.renderEndpoint == SZPortRef(node: m, port: "out"))
}
