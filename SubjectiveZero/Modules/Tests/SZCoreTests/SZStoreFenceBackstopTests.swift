// SPDX-License-Identifier: AGPL-3.0-only
// The store's fence tripwire: every FENCED-class graph edit consults the host-installed backstop
// with the right node ids (so a future caller that bypasses the host funnels is caught in debug),
// while OPEN-class edits (move, add) never consult it — locked nodes stay repositionable and adds
// are always allowed, by documented design.
import Foundation
import Testing
@testable import SZCore

@MainActor
private func storeWithTwoNodes() -> (SZStore, SZNodeID, SZNodeID, SZConnectionID) {
    let store = SZStore()
    store.setProject(SZProject(name: "Fence"))
    let a = store.addPromptNode(prompt: "a", position: SZPoint(x: 0, y: 0))!
    let b = store.addPromptNode(prompt: "b", position: SZPoint(x: 200, y: 0))!
    let edge = store.connect(from: SZPortRef(node: a, port: ""),
                             to: SZPortRef(node: b, port: ""), kind: .flow)!
    return (store, a, b, edge)
}

@MainActor
@Test func fencedOpsConsultTheBackstopWithTheirNodeIDs() {
    let (store, a, b, edge) = storeWithTwoNodes()
    var consulted: [Set<SZNodeID>] = []
    store.fenceBackstop = { ids in consulted.append(ids); return nil }

    store.updateNode(id: a, title: "renamed")
    #expect(consulted.last == [a])
    store.editPorts(node: a, SZStore.SZPortEdit(
        upsertInputs: [SZPort(name: "x", type: .float)], removeInputs: [],
        upsertOutputs: [], removeOutputs: []))
    #expect(consulted.last == [a])
    store.setInputDefault(node: a, port: "x", value: .float(1))
    #expect(consulted.last == [a])
    store.setNodeBody(id: a, body: SZNodeBody(mode: .none))
    #expect(consulted.last == [a])
    store.disconnect(connection: edge)
    #expect(consulted.last == [a, b])
    store.connect(from: SZPortRef(node: a, port: ""),
                  to: SZPortRef(node: b, port: ""), kind: .flow)
    #expect(consulted.last == [a, b])
    store.removeNode(id: b)
    #expect(consulted.last == [b])
}

@MainActor
@Test func openOpsNeverConsultTheBackstop() {
    let (store, a, _, _) = storeWithTwoNodes()
    var consultations = 0
    store.fenceBackstop = { _ in consultations += 1; return nil }

    store.moveNode(id: a, to: SZPoint(x: 50, y: 50))
    store.moveNodes([(id: a, to: SZPoint(x: 60, y: 60))])
    _ = store.addPromptNode(prompt: "c", position: SZPoint(x: 400, y: 0))
    #expect(consultations == 0)
}
