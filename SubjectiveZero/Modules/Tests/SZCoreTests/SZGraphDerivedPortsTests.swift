// SPDX-License-Identifier: AGPL-3.0-only
// Port derivation for contract-less nodes (SZGraph+DerivedPorts) — the single home the brief
// renderer briefs agents from: data wiring implies inputs/outputs, the render endpoint counts
// as an output, and duplicates collapse in first-wire order.
import Foundation
import Testing
@testable import SZCore

@Test func portDerivationFollowsWiring() {
    let camera = SZNodeID(), gray = SZNodeID()
    let graph = SZGraph(
        nodes: [],
        connections: [SZConnection(from: SZPortRef(node: camera, port: "texture"),
                                   to: SZPortRef(node: gray, port: "input"), kind: .data)],
        renderEndpoint: SZPortRef(node: gray, port: "output"))
    #expect(graph.derivedDataInputPorts(of: gray) == ["input"])
    #expect(graph.derivedOutputPorts(of: gray) == ["output"])
    #expect(graph.derivedDataInputPorts(of: camera) == [])
    #expect(graph.derivedOutputPorts(of: camera) == ["texture"])
}
