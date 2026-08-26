// SPDX-License-Identifier: AGPL-3.0-only
// Arrows nobody wired, and the run gate that reads them. An arrow still standing when a run settles is
// unfinished work whether or not its node built fine, which is how a built node came to read Ready over
// inputs that were never connected.
import Foundation
import Testing
@testable import SZCore

private func node(_ id: SZNodeID, _ title: String, kind: SZNodeKind = .prompt) -> SZNode {
    SZNode(id: id, kind: kind, title: title, prompt: "do \(title)", position: SZPoint(x: 0, y: 0))
}

private func flow(_ a: SZNodeID, _ b: SZNodeID, toPort: String = "flow") -> SZConnection {
    SZConnection(from: SZPortRef(node: a, port: "flow"), to: SZPortRef(node: b, port: toPort), kind: .flow)
}

@Test func anArrowIntoABuiltNodeIsStillUnwiredIntent() {
    // The Point Cloud shape: the node compiled, so it is no longer dirty, but its arrow was never
    // wired. The node's kind does not matter here; only the standing arrow does.
    let depth = SZNodeID(), cloud = SZNodeID()
    let graph = SZGraph(nodes: [node(depth, "Depth Map", kind: .generated),
                                node(cloud, "Point Cloud", kind: .generated)],
                        connections: [flow(depth, cloud)])

    #expect(graph.unwiredNodes(in: [depth, cloud]) == [cloud])
    #expect(graph.unwiredIntent(into: [depth, cloud]).count == 1)
}

@Test func onlyArrowsLandingInsideTheGivenSetCount() {
    let a = SZNodeID(), b = SZNodeID(), stray = SZNodeID()
    let graph = SZGraph(nodes: [node(a, "A"), node(b, "B"), node(stray, "Stray")],
                        connections: [flow(a, b), flow(a, stray)])

    #expect(graph.unwiredNodes(in: [a, b]) == [b])          // the stray target is out of scope
    #expect(graph.unwiredNodes(in: [stray]) == [stray])
    #expect(graph.unwiredNodes(in: []).isEmpty)
}

@Test func aRealizedArrowAndASelfArrowAreNotUnwiredIntent() {
    let a = SZNodeID(), b = SZNodeID()
    let data = SZConnection(from: SZPortRef(node: a, port: "output"),
                            to: SZPortRef(node: b, port: "input"), kind: .data)
    let graph = SZGraph(nodes: [node(a, "A"), node(b, "B")],
                        connections: [data, flow(b, b)])

    // Laying the data edge is what resolves an arrow, so a graph with no flow left owes nothing —
    // and a node pointing at itself was never intent to wire.
    #expect(graph.unwiredNodes(in: [a, b]).isEmpty)
}

@Test func multipleArrowsOnOneNodeCollapseToOneEntryAndKeepBothLines() {
    let video = SZNodeID(), depth = SZNodeID(), cloud = SZNodeID()
    let graph = SZGraph(nodes: [node(video, "Video File"), node(depth, "Depth Map"), node(cloud, "Point Cloud")],
                        connections: [flow(depth, cloud), flow(video, cloud)])

    #expect(graph.unwiredNodes(in: [video, depth, cloud]) == [cloud])   // one node, still owed
    // Both arrows survive for the brief to name, ordered by the source's declaration index.
    let arrows = graph.unwiredIntent(into: [video, depth, cloud])
    #expect(arrows.map(\.from.node) == [video, depth])
}

@Test func aRunOwesTheArrowsItCapturedAndNothingDrawnSince() {
    // The frozen read. A run takes the arrows standing at admission; one drawn afterwards belongs to
    // the next run, or the fleet wires whatever appears mid-drag.
    let a = SZNodeID(), b = SZNodeID()
    let atStart = flow(a, b)
    var graph = SZGraph(nodes: [node(a, "A"), node(b, "B")], connections: [atStart])
    let captured: Set<SZConnectionID> = [atStart.id]

    graph.connections.append(flow(a, b, toPort: "input"))   // drawn after admission
    #expect(graph.unwiredIntent(among: captured).map(\.id) == [atStart.id])
    #expect(graph.unwiredNodes(among: captured) == [b])
    // A live read would have picked up both — that is exactly what the capture prevents.
    #expect(graph.unwiredIntent(into: [a, b]).count == 2)
}

@Test func anArrowWiredOrDeletedDuringTheRunLeavesTheOwedList() {
    // The owed list shrinks by construction: realizing an arrow removes the flow edge, so the
    // captured id simply stops matching. Nothing has to remember that it was settled.
    let a = SZNodeID(), b = SZNodeID()
    let arrow = flow(a, b)
    var graph = SZGraph(nodes: [node(a, "A"), node(b, "B")], connections: [arrow])
    let captured: Set<SZConnectionID> = [arrow.id]
    #expect(graph.unwiredNodes(among: captured) == [b])

    graph.connections = [SZConnection(from: SZPortRef(node: a, port: "output"),
                                      to: SZPortRef(node: b, port: "input"), kind: .data)]
    #expect(graph.unwiredNodes(among: captured).isEmpty)
    #expect(graph.unwiredIntent(among: []).isEmpty)
}

@Test func anArrowTheDataAlreadySatisfiesIsNotUnwired() {
    // Unwired is about the wiring, not about whether an arrow is still drawn. An arrow can outlive its
    // own wiring (laying an edge that exists returns before the discharge), and counting it left a run
    // owing work already done.
    let a = SZNodeID(), b = SZNodeID()
    let data = SZConnection(from: SZPortRef(node: a, port: "output"),
                            to: SZPortRef(node: b, port: "input"), kind: .data)
    let graph = SZGraph(nodes: [node(a, "A"), node(b, "B")], connections: [data, flow(a, b)])
    #expect(graph.unwiredNodes(in: [a, b]).isEmpty)

    // A pinned arrow asks for one slot, so an edge into a different one does not satisfy it.
    let toMask = SZGraph(nodes: [node(a, "A"), node(b, "B")],
                         connections: [data, flow(a, b, toPort: "mask")])
    #expect(toMask.unwiredNodes(in: [a, b]) == [b])
}

@Test func aBuiltNodeWithADanglingArrowKeepsTheRunGateOpen() {
    // The gate the run reads. Nothing left to build, but an arrow is still hanging: the run must
    // take another pass instead of ending, which is what used to leave the wiring undone.
    let cloud = UUID()
    let stillOwed = SZFacts(message: "", run: SZRun(
        workSet: [], round: 1, roundCap: 2, steers: [], instruction: "build it", unwired: [cloud]))
    #expect(stillOwed.hasWorkLeft)

    let settled = SZFacts(message: "", run: SZRun(
        workSet: [], round: 1, roundCap: 2, steers: [], instruction: "build it", unwired: []))
    #expect(!settled.hasWorkLeft)

    let building = SZFacts(message: "", run: SZRun(
        workSet: [cloud], round: 1, roundCap: 2, steers: [], instruction: "build it", unwired: []))
    #expect(building.hasWorkLeft)

    #expect(!SZFacts(message: "").hasWorkLeft)              // no run at all
}

// MARK: - Arrows that can never be answered

@Test func anArrowIsStuckOnlyWhenItsWireWouldRing() {
    // Stuck is about the wire the arrow asks for. A ring of arrows is refused where it is drawn; what
    // makes a standing arrow unanswerable is a data path already running the other way.
    let a = SZNodeID(), b = SZNodeID()
    let backwards = flow(b, a)
    let graph = SZGraph(nodes: [node(a, "A"), node(b, "B")],
                        connections: [SZConnection(from: SZPortRef(node: a, port: "output"),
                                                   to: SZPortRef(node: b, port: "input"), kind: .data),
                                      backwards])
    #expect(graph.isStuckIntent(backwards))
    #expect(graph.stuckIntent.map(\.id) == [backwards.id])

    // The same arrow with nothing running the other way is ordinary unfinished wiring.
    let open = SZGraph(nodes: [node(a, "A"), node(b, "B")], connections: [backwards])
    #expect(!open.isStuckIntent(backwards))
    #expect(open.stuckIntent.isEmpty)
}

@Test func anArrowNeverBlocksAWire() {
    // A wish must not block a fact: `wouldCloseCycle` judges a data edge over data alone, so an
    // arrow pointing the other way cannot refuse the wiring the user is actually laying.
    let a = SZNodeID(), b = SZNodeID()
    let graph = SZGraph(nodes: [node(a, "A"), node(b, "B")], connections: [flow(b, a)])
    #expect(graph.wouldCloseCycle(from: a, to: b) == nil)
    // Counting intent, the same pair DOES ring: only one of the two arrows could ever be laid.
    #expect(graph.wouldCloseIntentCycle(from: a, to: b) != nil)
}

@Test func aRingOfArrowsAloneIsCaught() {
    // The case a data-only walk cannot see: three arrows drawn before any wire exists. Nothing is
    // wired, so `wouldCloseCycle` is silent on all three, but the ring is already unanswerable.
    let a = SZNodeID(), b = SZNodeID(), c = SZNodeID()
    let graph = SZGraph(nodes: [node(a, "A"), node(b, "B"), node(c, "C")],
                        connections: [flow(a, b), flow(b, c)])
    #expect(graph.wouldCloseCycle(from: c, to: a) == nil)          // no wires at all
    #expect(graph.wouldCloseIntentCycle(from: c, to: a) != nil)    // C then A closes the ring
    // And the walk names it, so a refusal can say which cards are involved.
    #expect(graph.wouldCloseIntentCycle(from: c, to: a)?.first == c)
}
