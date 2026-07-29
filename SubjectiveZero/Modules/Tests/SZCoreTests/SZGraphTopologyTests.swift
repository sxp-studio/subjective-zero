// SPDX-License-Identifier: AGPL-3.0-only
// The data-edge DAG invariant (SZGraph+Topology): the shared Kahn kernel, the connect-time cycle
// guard (`wouldCloseCycle` + `SZStore.tryConnect`), and the load-time repair that drops a persisted
// cycle's newest edge so the project still opens.
import Foundation
import Testing
@testable import SZCore

private func node(_ id: SZNodeID, _ title: String = "n") -> SZNode {
    SZNode(id: id, kind: .generated, title: title, position: SZPoint(x: 0, y: 0))
}

private func data(_ a: SZNodeID, _ b: SZNodeID, toPort: String = "input") -> SZConnection {
    SZConnection(from: SZPortRef(node: a, port: "output"),
                 to: SZPortRef(node: b, port: toPort), kind: .data)
}

// MARK: - wouldCloseCycle

@Test func closingATwoCycleIsDetectedWithItsPath() {
    let a = SZNodeID(), b = SZNodeID()
    let graph = SZGraph(nodes: [node(a), node(b)], connections: [data(a, b)])
    // a → b exists, so b → a closes the cycle; the path reads b → a → b.
    #expect(graph.wouldCloseCycle(from: b, to: a) == [b, a, b])
    // The safe directions stay safe.
    #expect(graph.wouldCloseCycle(from: a, to: b) == nil)
}

@Test func closingALongCycleNamesTheWholeWalk() {
    let a = SZNodeID(), b = SZNodeID(), c = SZNodeID()
    let graph = SZGraph(nodes: [node(a), node(b), node(c)],
                        connections: [data(a, b), data(b, c)])
    // a → b → c exists; c → a is the closing edge, walked c → a → b → c.
    #expect(graph.wouldCloseCycle(from: c, to: a) == [c, a, b, c])
}

@Test func aDiamondIsNotACycle() {
    // a → b, a → c, b → d, c → d: two paths converge on d, no edge revisits anything.
    let a = SZNodeID(), b = SZNodeID(), c = SZNodeID(), d = SZNodeID()
    let graph = SZGraph(nodes: [node(a), node(b), node(c), node(d)],
                        connections: [data(a, b), data(a, c), data(b, d, toPort: "in1"),
                                      data(c, d, toPort: "in2")])
    #expect(graph.topologicalOrder() == [a, b, c, d])
    // A second edge along an existing direction is still no cycle.
    #expect(graph.wouldCloseCycle(from: a, to: d) == nil)
    #expect(graph.wouldCloseCycle(from: b, to: c) == nil)
}

@Test func aSelfLoopIsRefused() {
    // The scheduler kernel skips self-loops rather than failing on them, so the guard must be the
    // one to say no.
    let a = SZNodeID()
    let graph = SZGraph(nodes: [node(a)])
    #expect(graph.wouldCloseCycle(from: a, to: a) == [a, a])
}

@Test func disconnectedComponentsOrderAndNeverCrossCycle() {
    let a = SZNodeID(), b = SZNodeID(), c = SZNodeID(), d = SZNodeID()
    let graph = SZGraph(nodes: [node(a), node(b), node(c), node(d)],
                        connections: [data(a, b), data(c, d)])
    #expect(graph.topologicalOrder()?.count == 4)
    // Joining two components can't close a cycle in either direction.
    #expect(graph.wouldCloseCycle(from: b, to: c) == nil)
    #expect(graph.wouldCloseCycle(from: d, to: a) == nil)
}

@Test func topologicalOrderIsNilOnACycle() {
    let a = SZNodeID(), b = SZNodeID()
    let graph = SZGraph(nodes: [node(a), node(b)], connections: [data(a, b), data(b, a)])
    #expect(graph.topologicalOrder() == nil)
}

// MARK: - connect refusal (SZStore.tryConnect)

@MainActor
private func loadedStore() -> SZStore {
    let store = SZStore()
    store.setProject(SZProject(name: "Cycles"))
    return store
}

@MainActor
@Test func connectRefusesACycleWithThePathAndLeavesTheGraphUntouched() {
    let store = loadedStore()
    let a = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    let b = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 0))!
    _ = store.connect(from: SZPortRef(node: a, port: "output"),
                      to: SZPortRef(node: b, port: "input"), kind: .data)

    let result = store.tryConnect(from: SZPortRef(node: b, port: "output"),
                                  to: SZPortRef(node: a, port: "input"), kind: .data)
    #expect(result == .cycleRefused(path: [b, a, b]))
    // Nothing changed: still exactly the one original edge.
    let edges = store.project!.graph.connections
    #expect(edges.count == 1)
    #expect(edges.first?.from.node == a)
    // The nil-folding wrapper refuses the same way.
    #expect(store.connect(from: SZPortRef(node: b, port: "output"),
                          to: SZPortRef(node: a, port: "input"), kind: .data) == nil)
    #expect(store.project!.graph.connections.count == 1)
}

@MainActor
@Test func connectRefusesASelfLoop() {
    let store = loadedStore()
    let a = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    let result = store.tryConnect(from: SZPortRef(node: a, port: "output"),
                                  to: SZPortRef(node: a, port: "input"), kind: .data)
    #expect(result == .cycleRefused(path: [a, a]))
    #expect(store.project!.graph.connections.isEmpty)
}

@MainActor
@Test func swappingAnOccupiedInputIsJudgedWithTheDisplacedEdgeGone() {
    // Chain a → b → c, then re-feed c.input straight from a. That displaces b → c, and the result
    // (a → b, a → c) is acyclic — the displaced edge must not count against the replace.
    let store = loadedStore()
    let a = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    let b = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 0))!
    let c = store.addPromptNode(prompt: nil, position: SZPoint(x: 200, y: 0))!
    _ = store.connect(from: SZPortRef(node: a, port: "output"), to: SZPortRef(node: b, port: "input"), kind: .data)
    _ = store.connect(from: SZPortRef(node: b, port: "output"), to: SZPortRef(node: c, port: "input"), kind: .data)

    let result = store.tryConnect(from: SZPortRef(node: a, port: "output"),
                                  to: SZPortRef(node: c, port: "input"), kind: .data)
    guard case .connected = result else {
        Issue.record("swap refused: \(result)")
        return
    }
    let incoming = store.project!.graph.connections.filter { $0.kind == .data && $0.to.node == c }
    #expect(incoming.count == 1)
    #expect(incoming.first?.from.node == a)
    #expect(store.project!.graph.topologicalOrder() != nil)
}

@MainActor
@Test func theReconnectSequenceRestoresAWireWhoseReAddIsRefused() {
    // The store contract behind SZHost.reconnectConnection: disconnect + tryConnect; a cycle refusal
    // means the host re-appends the removed edge, so the wire is never silently lost.
    let store = loadedStore()
    let a = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    let b = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 0))!
    let c = store.addPromptNode(prompt: nil, position: SZPoint(x: 200, y: 0))!
    _ = store.connect(from: SZPortRef(node: a, port: "output"), to: SZPortRef(node: b, port: "input"), kind: .data)
    let picked = store.connect(from: SZPortRef(node: b, port: "output"),
                               to: SZPortRef(node: c, port: "input"), kind: .data)!
    let old = store.project!.graph.connections.first { $0.id == picked }!

    // Re-route b → c's input end onto a.input: a → b → a would cycle, so the re-add refuses…
    #expect(store.disconnect(connection: picked))
    let result = store.tryConnect(from: old.from, to: SZPortRef(node: a, port: "input"), kind: .data)
    #expect(result == .cycleRefused(path: [b, a, b]))
    // …and the host's restore puts the original edge back, id and all.
    store.mutate { $0.graph.connections.append(old) }
    #expect(store.project!.graph.connections.contains { $0.id == picked && $0.to.node == c })
    #expect(store.project!.graph.connections.count == 2)
}

@MainActor
@Test func flowEdgesAreNeverCycleChecked() {
    // Intent may point "backwards": a mutual flow pair is legal.
    let store = loadedStore()
    let a = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    let b = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 0))!
    _ = store.connect(from: SZPortRef(node: a, port: "flow"), to: SZPortRef(node: b, port: "flow"), kind: .flow)
    let back = store.tryConnect(from: SZPortRef(node: b, port: "flow"),
                                to: SZPortRef(node: a, port: "flow"), kind: .flow)
    guard case .connected = back else {
        Issue.record("flow refused: \(back)")
        return
    }
    #expect(store.project!.graph.connections.filter { $0.kind == .flow }.count == 2)
}

// MARK: - repair at load

@Test func repairDropsExactlyTheNewestCycleEdgeAndIsIdempotent() {
    let a = SZNodeID(), b = SZNodeID(), c = SZNodeID()
    let cycleCloser = data(c, a)   // appended last = newest
    var graph = SZGraph(nodes: [node(a), node(b), node(c)],
                        connections: [data(a, b), data(b, c), cycleCloser])

    let dropped = graph.repairDataCycles()
    #expect(dropped.map(\.id) == [cycleCloser.id])
    #expect(graph.connections.count == 2)
    #expect(graph.topologicalOrder() == [a, b, c])
    // A second pass has nothing left to do.
    #expect(graph.repairDataCycles().isEmpty)
    #expect(graph.connections.count == 2)
}

@Test func repairLeavesFlowAndInnocentDataEdgesAlone() {
    // Two data cycles + one clean edge + a flow cycle: repair drops exactly one data edge per cycle
    // (each cycle's newest), and flow — intent, not order — is never touched.
    let a = SZNodeID(), b = SZNodeID(), c = SZNodeID(), d = SZNodeID(), e = SZNodeID()
    let closerAB = data(b, a)
    let closerCD = data(d, c)
    let flowBack = SZConnection(from: SZPortRef(node: b, port: "flow"),
                                to: SZPortRef(node: a, port: "flow"), kind: .flow)
    var graph = SZGraph(nodes: [node(a), node(b), node(c), node(d), node(e)],
                        connections: [data(a, b), data(c, d), data(d, e), closerAB, closerCD, flowBack])

    let dropped = graph.repairDataCycles()
    // Last participating edge first: closerCD (index 4), then closerAB (index 3).
    #expect(dropped.map(\.id) == [closerCD.id, closerAB.id])
    #expect(graph.topologicalOrder() != nil)
    #expect(graph.connections.contains { $0.id == flowBack.id })
    #expect(graph.connections.filter { $0.kind == .data }.count == 3)
}

@Test func aPersistedCycleRepairsOnceAndRoundTripsClean() throws {
    // The load-time story end to end: a cyclic project.json loads, repair drops the newest edge,
    // the repaired project saves, and the next load needs no repair.
    let a = SZNodeID(), b = SZNodeID()
    let closer = data(b, a)
    var project = SZProject(name: "Cyclic")
    project.graph = SZGraph(nodes: [node(a, "A"), node(b, "B")], connections: [data(a, b), closer])
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "SZCycleRepair-\(UUID().uuidString)")
        .appending(path: "Cyclic.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)

    var loaded = try SZProjectIO.load(from: dir)
    let dropped = loaded.graph.repairDataCycles()
    #expect(dropped.map(\.id) == [closer.id])   // deterministically the newest
    #expect(loaded.graph.topologicalOrder() != nil)
    try SZProjectIO.save(loaded, to: dir)

    var reloaded = try SZProjectIO.load(from: dir)
    #expect(reloaded.graph.repairDataCycles().isEmpty)   // second open: nothing to repair
    #expect(reloaded.graph.connections.count == 1)
    #expect(reloaded.graph.connections.first?.from.node == a)
}
