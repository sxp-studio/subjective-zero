// SPDX-License-Identifier: AGPL-3.0-only
// The read-side join over derived bindings: decoding the mappings table and answering "which
// derived output feeds this target" — including the guard that a hand-wired non-table output
// (e.g. `lastEvent`) never counts as a binding — plus the `isBindingSource` capability check.
import Foundation
import Testing
@testable import SZCore

private func graphWithBinding(table: String) -> (SZGraph, SZNodeID, SZNodeID) {
    let source = SZNode(
        kind: .generated, title: "Control Source",
        contract: SZNodeContract(
            title: "Control Source", sfSymbol: "dial.low", summary: "",
            inputs: [SZPort(name: "mappings", type: .string, def: .string(table))],
            outputs: [SZPort(name: "lastEvent", type: .float2),
                      SZPort(name: "lastKey", type: .string),
                      SZPort(name: "knob", type: .float)]),
        position: SZPoint(x: 0, y: 0))
    let target = SZNode(
        kind: .generated, title: "Effect",
        contract: SZNodeContract(
            title: "Effect", sfSymbol: "circle", summary: "",
            inputs: [SZPort(name: "amount", type: .float, def: .float(1))],
            outputs: [SZPort(name: "output", type: .texture, display: true)]),
        position: SZPoint(x: 1, y: 0))
    let graph = SZGraph(nodes: [source, target])
    return (graph, source.id, target.id)
}

@Test func mappingsTableDecodesRowsByPortName() {
    let (graph, source, _) = graphWithBinding(
        table: #"[{"key":"ch1/cc21","port":"knob","min":0,"max":2,"label":"Blur"}]"#)
    let table = graph.mappingsTable(node: source)
    #expect(table["knob"] == SZBindingEntry(key: "ch1/cc21", min: 0, max: 2, label: "Blur"))
}

@Test func mappingsTableDefaultsAndSkipsIncompleteRows() {
    let (graph, source, _) = graphWithBinding(
        table: #"[{"key":"ch1/cc21","port":"knob"},{"key":"/1/x"},{"port":"orphan"},{"key":"","port":"empty"}]"#)
    let table = graph.mappingsTable(node: source)
    #expect(table == ["knob": SZBindingEntry(key: "ch1/cc21", min: 0, max: 1, label: nil)])
}

@Test func mappingsTableDegradesToEmptyOnMalformedJSONOrMissingNode() {
    let (graph, source, _) = graphWithBinding(table: "not json")
    #expect(graph.mappingsTable(node: source).isEmpty)
    #expect(graph.mappingsTable(node: SZNodeID()).isEmpty)
}

@Test func derivedBindingPortFindsTheTableNamedEdge() {
    var (graph, source, target) = graphWithBinding(table: #"[{"key":"ch1/cc21","port":"knob"}]"#)
    let ref = SZPortRef(node: target, port: "amount")
    #expect(graph.derivedBindingPort(source: source, target: ref) == nil)   // unbound yet
    graph.connections.append(SZConnection(
        from: SZPortRef(node: source, port: "knob"), to: ref, kind: .data))
    #expect(graph.derivedBindingPort(source: source, target: ref) == "knob")
}

@Test func derivedBindingPortIgnoresEdgesFromNonTableOutputs() {
    var (graph, source, target) = graphWithBinding(table: "[]")
    let ref = SZPortRef(node: target, port: "amount")
    // A hand-wired lastEvent edge is a wire, not a binding.
    graph.connections.append(SZConnection(
        from: SZPortRef(node: source, port: "lastEvent"), to: ref, kind: .data))
    #expect(graph.derivedBindingPort(source: source, target: ref) == nil)
}

@Test func isBindingSourceRequiresTableInputAndLastKeyOutput() {
    let (graph, source, target) = graphWithBinding(table: "[]")
    #expect(graph.node(id: source)?.contract?.isBindingSource == true)
    #expect(graph.node(id: target)?.contract?.isBindingSource == false)
    // A float4 `lastKey` (or a non-string table) is not the seed shape.
    let wrong = SZNodeContract(title: "x", sfSymbol: "", summary: "",
                               inputs: [SZPort(name: "mappings", type: .string, def: .string("[]"))],
                               outputs: [SZPort(name: "lastKey", type: .float4)])
    #expect(wrong.isBindingSource == false)
}
