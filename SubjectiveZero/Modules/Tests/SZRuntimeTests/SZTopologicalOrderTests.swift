// SPDX-License-Identifier: AGPL-3.0-only
// Topological order is derived from DATA edges only — flow is a transient authoring annotation
// (drawing intent), not a runtime ordering construct, so the scheduler must ignore it.
import Testing
import SZCore
@testable import SZRuntime

private func node(_ id: SZNodeID) -> SZNode {
    SZNode(id: id, kind: .generated, title: "n", position: SZPoint(x: 0, y: 0))
}

@Test func topologicalOrderIgnoresFlowEdges() {
    let a = SZNodeID(), b = SZNodeID()
    // Data edge a → b forces a first; a contrary flow edge b → a must NOT override it.
    let graph = SZGraph(
        nodes: [node(a), node(b)],
        connections: [
            SZConnection(from: SZPortRef(node: a, port: "output"), to: SZPortRef(node: b, port: "input"), kind: .data),
            SZConnection(from: SZPortRef(node: b, port: "flow"), to: SZPortRef(node: a, port: "flow"), kind: .flow),
        ])
    #expect(SZScheduler.topologicalOrder(graph) == [a, b])
}

@Test func flowOnlyCycleDoesNotWedgeScheduling() {
    let a = SZNodeID(), b = SZNodeID()
    // A flow cycle a ⇄ b carries no data — with flow ignored there are no constraints, so topo succeeds.
    let graph = SZGraph(
        nodes: [node(a), node(b)],
        connections: [
            SZConnection(from: SZPortRef(node: a, port: "flow"), to: SZPortRef(node: b, port: "flow"), kind: .flow),
            SZConnection(from: SZPortRef(node: b, port: "flow"), to: SZPortRef(node: a, port: "flow"), kind: .flow),
        ])
    // Not just `count == 2`: with no data constraints the scheduler falls back to declaration order, so
    // [a, b] is fully determined. A count-only assertion would pass on an impl that dropped a node and
    // duplicated another, or that shuffled the ready set.
    #expect(SZScheduler.topologicalOrder(graph) == [a, b])
}
