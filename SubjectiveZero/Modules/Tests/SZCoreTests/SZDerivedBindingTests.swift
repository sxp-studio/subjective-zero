// SPDX-License-Identifier: AGPL-3.0-only
// The derived-binding transaction on SZStore: one transaction that updates a node's binding-table input,
// upserts the output the entry declares, and wires it — WITHOUT raising `needsRebuild` (the node's code
// is table-generic by construction; `editPorts` remains the editorial, build-invalidating path).
import Foundation
import Testing
@testable import SZCore

@MainActor
private func storeWithTableNode() -> (SZStore, SZNodeID, SZNodeID) {
    let store = SZStore()
    store.setProject(SZProject(name: "Bindings"))
    let source = SZNode(
        kind: .generated, title: "Control Source",
        contract: SZNodeContract(
            title: "Control Source", sfSymbol: "dial.low", summary: "",
            inputs: [SZPort(name: "mappings", type: .string, def: .string("[]"))],
            outputs: [SZPort(name: "lastEvent", type: .float2),
                      SZPort(name: "lastKey", type: .string)]),
        position: SZPoint(x: 0, y: 0))
    let target = SZNode(
        kind: .generated, title: "Effect",
        contract: SZNodeContract(
            title: "Effect", sfSymbol: "circle", summary: "",
            inputs: [SZPort(name: "amount", type: .float, def: .float(1))],
            outputs: [SZPort(name: "output", type: .texture, display: true)]),
        position: SZPoint(x: 1, y: 0))
    store.mutate { $0.graph.nodes.append(contentsOf: [source, target]) }
    return (store, source.id, target.id)
}

@MainActor
@Test func commitDerivedBindingIsOneRevisionAndRaisesNoRebuild() {
    let (store, source, target) = storeWithTableNode()
    let table = #"[{"key":"ch1/cc21","port":"amount-knob","min":0,"max":2}]"#

    let applied = store.commitDerivedBinding(
        node: source, tableInput: "mappings", tableJSON: table,
        output: SZPort(name: "amount-knob", type: .float),
        target: SZPortRef(node: target, port: "amount"))
    #expect(applied)

    let node = store.project?.graph.node(id: source)
    #expect(node?.contract?.inputs.first { $0.name == "mappings" }?.def?.string == table)
    #expect(node?.contract?.outputs.map(\.name) == ["lastEvent", "lastKey", "amount-knob"])
    #expect(node?.rebuildReason == nil)     // derived output ⇒ no build invalidation

    let edge = store.project?.graph.connections.first
    #expect(edge?.kind == .data)
    #expect(edge?.from == SZPortRef(node: source, port: "amount-knob"))
    #expect(edge?.to == SZPortRef(node: target, port: "amount"))
}

@MainActor
@Test func commitDerivedBindingSwapsAnOccupiedTargetInput() {
    let (store, source, target) = storeWithTableNode()
    _ = store.connect(from: SZPortRef(node: source, port: "lastEvent"),
                      to: SZPortRef(node: target, port: "amount"), kind: .data)
    store.commitDerivedBinding(
        node: source, tableInput: "mappings", tableJSON: "[]",
        output: SZPort(name: "knob", type: .float),
        target: SZPortRef(node: target, port: "amount"))
    // The data input holds exactly one incoming edge — the binding replaced the old wire.
    let edges = store.project?.graph.connections.filter { $0.kind == .data } ?? []
    #expect(edges.count == 1)
    #expect(edges.first?.from.port == "knob")
}

@MainActor
@Test func removeDerivedBindingDropsOutputAndItsEdges() {
    let (store, source, target) = storeWithTableNode()
    store.commitDerivedBinding(
        node: source, tableInput: "mappings",
        tableJSON: #"[{"key":"ch1/cc21","port":"knob","min":0,"max":1}]"#,
        output: SZPort(name: "knob", type: .float),
        target: SZPortRef(node: target, port: "amount"))

    let applied = store.removeDerivedBinding(
        node: source, tableInput: "mappings", tableJSON: "[]", output: "knob")
    #expect(applied)

    let node = store.project?.graph.node(id: source)
    #expect(node?.contract?.outputs.map(\.name) == ["lastEvent", "lastKey"])
    #expect(node?.contract?.inputs.first { $0.name == "mappings" }?.def?.string == "[]")
    #expect(store.project?.graph.connections.isEmpty == true)
    #expect(node?.rebuildReason == nil)
}

@MainActor
@Test func rebindingTheSameTargetUnderTheSameNameReplacesInPlace() {
    let (store, source, target) = storeWithTableNode()
    let ref = SZPortRef(node: target, port: "amount")
    store.commitDerivedBinding(
        node: source, tableInput: "mappings",
        tableJSON: #"[{"key":"ch1/cc21","port":"knob","min":0,"max":2}]"#,
        output: SZPort(name: "knob", type: .float), target: ref)

    // A rebind that reuses the existing binding's name (what the replace-aware caller resolves
    // via `derivedBindingPort`) lands as an in-place swap: same output, same single edge, the
    // table's one row now naming the new controller.
    #expect(store.project?.graph.derivedBindingPort(source: source, target: ref) == "knob")
    store.commitDerivedBinding(
        node: source, tableInput: "mappings",
        tableJSON: #"[{"key":"ch1/cc22","port":"knob","min":0,"max":2}]"#,
        output: SZPort(name: "knob", type: .float), target: ref)

    let node = store.project?.graph.node(id: source)
    #expect(node?.contract?.outputs.map(\.name) == ["lastEvent", "lastKey", "knob"])   // no "knob-2"
    #expect(store.project?.graph.mappingsTable(node: source) ==
            ["knob": SZBindingEntry(key: "ch1/cc22", min: 0, max: 2, label: nil)])
    let edges = store.project?.graph.connections.filter { $0.kind == .data } ?? []
    #expect(edges.count == 1)
    #expect(edges.first?.from == SZPortRef(node: source, port: "knob"))
}

@MainActor
@Test func derivedBindingRefusesMissingNodeOrNonStringTable() {
    let (store, source, _) = storeWithTableNode()
    #expect(store.commitDerivedBinding(
        node: SZNodeID(), tableInput: "mappings", tableJSON: "[]",
        output: SZPort(name: "x", type: .float), target: nil) == false)
    // `lastEvent` exists but is not a string input — not a binding table.
    #expect(store.commitDerivedBinding(
        node: source, tableInput: "lastEvent", tableJSON: "[]",
        output: SZPort(name: "x", type: .float), target: nil) == false)
    #expect(store.removeDerivedBinding(
        node: source, tableInput: "missing", tableJSON: "[]", output: "x") == false)
}
