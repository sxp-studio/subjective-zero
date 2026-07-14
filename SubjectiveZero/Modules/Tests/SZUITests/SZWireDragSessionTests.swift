// SPDX-License-Identifier: AGPL-3.0-only
// The wire-drag state machine — pickup vs fresh-wire grabs, the nearer-end edge detach, the click
// guard, and every drop outcome (connect / re-route / disconnect / flow-spawn) — pinned headlessly.
// This logic previously lived as view methods and every regression surfaced as a live gesture bug.
import CoreGraphics
import Foundation
import Testing
@testable import SZUI
import SZCore

private func texNode(_ title: String, at position: SZPoint,
                     inputs: [String] = [], outputs: [String] = []) -> SZNode {
    SZNode(kind: .generated, title: title, sfSymbol: "circle",
           contract: SZNodeContract(title: title, sfSymbol: "circle", summary: "",
                                    inputs: inputs.map { SZPort(name: $0, type: .texture) },
                                    outputs: outputs.map { SZPort(name: $0, type: .texture) }),
           position: position)
}

private func socket(_ node: SZNode, _ side: SZSocketSide, _ kind: SZConnectionKind, _ port: String) -> SZSocket {
    SZGraphCanvasModel.connectableSockets(of: node).first {
        $0.side == side && $0.kind == kind && $0.port == port
    }!
}

private func unlocked(_: SZNodeID) -> Bool { false }

/// source.out ──data──▶ sink.input, far enough apart that socket radii don't overlap.
private func wiredGraph() -> (source: SZNode, sink: SZNode, conn: SZConnection, graph: SZGraph) {
    let source = texNode("Source", at: SZPoint(x: 0, y: 0), outputs: ["out"])
    let sink = texNode("Sink", at: SZPoint(x: 600, y: 0), inputs: ["input"], outputs: ["result"])
    let conn = SZConnection(from: SZPortRef(node: source.id, port: "out"),
                            to: SZPortRef(node: sink.id, port: "input"), kind: .data)
    return (source, sink, conn, SZGraph(nodes: [source, sink], connections: [conn]))
}

// MARK: - Grabs

@Test func grabbingAConnectedDataInputPicksUpItsWireAnchoredAtTheFarOutput() {
    let (source, sink, conn, graph) = wiredGraph()
    let grab = socket(sink, .input, .data, "input")
    let session = SZWireDragSession.begin(from: grab, atWorld: grab.point, screen: grab.point,
                                          in: graph, isLocked: unlocked)
    #expect(session?.picked?.id == conn.id)
    #expect(session?.picked?.end == .to)
    #expect(session?.picked?.original == conn.to)
    #expect(session?.source.nodeID == source.id)     // preview re-anchors at the kept (output) end
    #expect(session?.source.side == .output)
}

@Test func pickupIsRefusedWhenTheFarEndIsLocked() {
    let (source, sink, _, graph) = wiredGraph()
    let grab = socket(sink, .input, .data, "input")
    let session = SZWireDragSession.begin(from: grab, atWorld: grab.point, screen: grab.point,
                                          in: graph) { $0 == source.id }
    #expect(session == nil)
}

@Test func outputsAndUnwiredInputsStartAFreshWire() {
    let (source, sink, _, graph) = wiredGraph()
    for grab in [socket(source, .output, .data, "out"),      // an output
                 socket(sink, .output, .data, "result"),     // an unwired output
                 socket(source, .input, .flow, "")] {        // a flow socket
        let session = SZWireDragSession.begin(from: grab, atWorld: grab.point, screen: grab.point,
                                              in: graph, isLocked: unlocked)
        #expect(session?.picked == nil)
        #expect(session?.source.id == grab.id)               // anchored where it started
    }
}

@Test func edgeGrabDetachesTheEndNearerTheGrab() {
    let (source, sink, conn, graph) = wiredGraph()
    let pts = SZGraphCanvasModel.endpoints(of: conn, in: graph)!
    // Grab near the INPUT end → the input end detaches; preview keeps the output anchor.
    let nearInput = CGPoint(x: pts.to.x - 20, y: pts.to.y)
    let a = SZWireDragSession.begin(along: conn, atWorld: nearInput, screen: nearInput, in: graph)
    #expect(a?.picked?.end == .to)
    #expect(a?.source.nodeID == source.id)
    // Grab near the OUTPUT end → the source end detaches; preview keeps the input anchor.
    let nearOutput = CGPoint(x: pts.from.x + 20, y: pts.from.y)
    let b = SZWireDragSession.begin(along: conn, atWorld: nearOutput, screen: nearOutput, in: graph)
    #expect(b?.picked?.end == .from)
    #expect(b?.source.nodeID == sink.id)
}

// MARK: - The click guard

@Test func aSubThresholdWobbleNeverDropsOrDisconnects() {
    let (_, sink, _, graph) = wiredGraph()
    let grab = socket(sink, .input, .data, "input")
    var session = SZWireDragSession.begin(from: grab, atWorld: grab.point, screen: grab.point,
                                          in: graph, isLocked: unlocked)!
    // 5pt of wobble at zoom 1 stays under the 8pt guard: the pickup must restore untouched.
    session.update(toWorld: CGPoint(x: grab.point.x + 5, y: grab.point.y), zoom: 1,
                   in: graph, tiers: [:], isLocked: unlocked)
    #expect(!session.moved)
    #expect(session.outcome() == .none)
    // The same drag past the guard, dropped on empty canvas, disconnects.
    session.update(toWorld: CGPoint(x: grab.point.x + 200, y: grab.point.y + 200), zoom: 1,
                   in: graph, tiers: [:], isLocked: unlocked)
    #expect(session.moved)
}

@Test func theClickGuardThresholdIsZoomAware() {
    let (_, sink, _, graph) = wiredGraph()
    let grab = socket(sink, .input, .data, "input")
    var session = SZWireDragSession.begin(from: grab, atWorld: grab.point, screen: grab.point,
                                          in: graph, isLocked: unlocked)!
    // 12 world-pt exceeds 8/1 at zoom 1 but stays under 8/0.5 = 16 at zoom 0.5.
    session.update(toWorld: CGPoint(x: grab.point.x + 12, y: grab.point.y), zoom: 0.5,
                   in: graph, tiers: [:], isLocked: unlocked)
    #expect(!session.moved)
    session.update(toWorld: CGPoint(x: grab.point.x + 12, y: grab.point.y), zoom: 1,
                   in: graph, tiers: [:], isLocked: unlocked)
    #expect(session.moved)
}

// MARK: - Drop outcomes

@Test func aPickedWireDroppedOnEmptyCanvasDisconnects() {
    let (_, sink, conn, graph) = wiredGraph()
    let grab = socket(sink, .input, .data, "input")
    var session = SZWireDragSession.begin(from: grab, atWorld: grab.point, screen: grab.point,
                                          in: graph, isLocked: unlocked)!
    session.update(toWorld: CGPoint(x: 300, y: 400), zoom: 1, in: graph, tiers: [:], isLocked: unlocked)
    #expect(session.target == nil)
    #expect(session.outcome() == .disconnect(conn.id))
}

@Test func droppingBackOnTheOriginalPortRestoresTheWireUntouched() {
    let (_, sink, _, graph) = wiredGraph()
    let grab = socket(sink, .input, .data, "input")
    var session = SZWireDragSession.begin(from: grab, atWorld: grab.point, screen: grab.point,
                                          in: graph, isLocked: unlocked)!
    // Wander past the click guard, then come home: the snap re-acquires the original socket.
    session.update(toWorld: CGPoint(x: 300, y: 400), zoom: 1, in: graph, tiers: [:], isLocked: unlocked)
    session.update(toWorld: grab.point, zoom: 1, in: graph, tiers: [:], isLocked: unlocked)
    #expect(session.target?.id == grab.id)
    #expect(session.outcome() == .none)
}

@Test func aFlowRestoreComparesNodesOnly() {
    // A flow ref's port may be "flow" (ensureFlow) while the socket is keyed portless — dropping a
    // picked flow edge back on its node must read as unchanged, not as a re-route.
    let a = texNode("A", at: SZPoint(x: 0, y: 0), outputs: ["out"])
    let b = texNode("B", at: SZPoint(x: 600, y: 0), inputs: ["input"])
    let flow = SZConnection(from: SZPortRef(node: a.id, port: "flow"),
                            to: SZPortRef(node: b.id, port: "flow"), kind: .flow)
    let graph = SZGraph(nodes: [a, b], connections: [flow])
    let pts = SZGraphCanvasModel.endpoints(of: flow, in: graph)!
    let nearInput = CGPoint(x: pts.to.x - 20, y: pts.to.y)
    var session = SZWireDragSession.begin(along: flow, atWorld: nearInput, screen: nearInput, in: graph)!
    session.update(toWorld: CGPoint(x: 300, y: 300), zoom: 1, in: graph, tiers: [:], isLocked: unlocked)
    session.update(toWorld: pts.to, zoom: 1, in: graph, tiers: [:], isLocked: unlocked)
    #expect(session.target?.nodeID == b.id)
    #expect(session.outcome() == .none)
}

@Test func aFreshWireOrientsOutputToInputWhicheverEndWasDragged() {
    // An unwired pair, so neither grab reads as a pickup and the drop target isn't occupied.
    let from = texNode("From", at: SZPoint(x: 0, y: 600), outputs: ["out"])
    let to = texNode("To", at: SZPoint(x: 600, y: 600), inputs: ["input"])
    let fresh = SZGraph(nodes: [from, to], connections: [])

    let out = socket(from, .output, .data, "out")
    let inp = socket(to, .input, .data, "input")
    let expected = SZWireDragSession.Outcome.connect(
        from: SZPortRef(node: from.id, port: "out"),
        to: SZPortRef(node: to.id, port: "input"), kind: .data)

    // output → input
    var a = SZWireDragSession.begin(from: out, atWorld: out.point, screen: out.point,
                                    in: fresh, isLocked: unlocked)!
    a.update(toWorld: inp.point, zoom: 1, in: fresh, tiers: [:], isLocked: unlocked)
    #expect(a.outcome() == expected)

    // input → output lands the SAME oriented connect
    var b = SZWireDragSession.begin(from: inp, atWorld: inp.point, screen: inp.point,
                                    in: fresh, isLocked: unlocked)!
    b.update(toWorld: out.point, zoom: 1, in: fresh, tiers: [:], isLocked: unlocked)
    #expect(b.outcome() == expected)
}

@Test func aFreshFlowWireDroppedInSpaceSpawnsEdgeAnchored() {
    let a = texNode("A", at: SZPoint(x: 0, y: 0), outputs: ["out"])
    let graph = SZGraph(nodes: [a], connections: [])
    let drop = CGPoint(x: 500, y: 300)

    // From a flow-OUT the node is downstream and grows rightward: LEFT edge at the drop point.
    let flowOut = socket(a, .output, .flow, "")
    var out = SZWireDragSession.begin(from: flowOut, atWorld: flowOut.point, screen: flowOut.point,
                                      in: graph, isLocked: unlocked)!
    out.update(toWorld: drop, zoom: 1, in: graph, tiers: [:], isLocked: unlocked)
    #expect(out.outcome() == .spawnPromptNode(
        center: CGPoint(x: drop.x + SZNodeLayout.width / 2, y: drop.y),
        source: SZPortRef(node: a.id, port: "flow"), downstream: true))

    // From a flow-IN the node is upstream and grows leftward. The center is RAW — snapping is the
    // panel's placement rule (snappedPromptCenter), applied at dispatch, not the session's.
    let flowIn = socket(a, .input, .flow, "")
    var inp = SZWireDragSession.begin(from: flowIn, atWorld: flowIn.point, screen: flowIn.point,
                                      in: graph, isLocked: unlocked)!
    inp.update(toWorld: drop, zoom: 1, in: graph, tiers: [:], isLocked: unlocked)
    #expect(inp.outcome() == .spawnPromptNode(
        center: CGPoint(x: drop.x - SZNodeLayout.width / 2, y: drop.y),
        source: SZPortRef(node: a.id, port: "flow"), downstream: false))
}

@Test func aDataWireDroppedInSpaceDoesNothing() {
    let a = texNode("A", at: SZPoint(x: 0, y: 0), outputs: ["out"])
    let graph = SZGraph(nodes: [a], connections: [])
    let grab = socket(a, .output, .data, "out")
    var session = SZWireDragSession.begin(from: grab, atWorld: grab.point, screen: grab.point,
                                          in: graph, isLocked: unlocked)!
    session.update(toWorld: CGPoint(x: 500, y: 300), zoom: 1, in: graph, tiers: [:], isLocked: unlocked)
    #expect(session.outcome() == .none)   // only FLOW wires spawn on empty drops
}

// MARK: - Target validity (SZGraphCanvasModel)

@Test func snapTargetPicksTheNearestSocketWithinTheZoomAwareRadius() {
    let from = texNode("From", at: SZPoint(x: 0, y: 0), outputs: ["out"])
    let near = texNode("Near", at: SZPoint(x: 600, y: 0), inputs: ["input"])
    let far = texNode("Far", at: SZPoint(x: 600, y: 400), inputs: ["input"])
    let graph = SZGraph(nodes: [from, near, far], connections: [])
    let source = socket(from, .output, .data, "out")
    let nearInput = socket(near, .input, .data, "input")

    let probe = CGPoint(x: nearInput.point.x + 10, y: nearInput.point.y + 10)
    #expect(SZGraphCanvasModel.snapTarget(for: source, at: probe, zoom: 1, in: graph, tiers: [:],
                                          pickedConnectionID: nil, isLocked: unlocked)?.id
            == nearInput.id)
    // 40pt out exceeds the 28/zoom radius at zoom 1 but not at zoom 0.5 (radius 56).
    let out = CGPoint(x: nearInput.point.x + 40, y: nearInput.point.y)
    #expect(SZGraphCanvasModel.snapTarget(for: source, at: out, zoom: 1, in: graph, tiers: [:],
                                          pickedConnectionID: nil, isLocked: unlocked) == nil)
    #expect(SZGraphCanvasModel.snapTarget(for: source, at: out, zoom: 0.5, in: graph, tiers: [:],
                                          pickedConnectionID: nil, isLocked: unlocked)?.id
            == nearInput.id)
}

@Test func anOccludedSocketIsNeverAValidTargetUntilItsNodeIsRaised() {
    // Overlap Sink's input dot under a card that renders above it (same fixture as isOccluded).
    let from = texNode("From", at: SZPoint(x: 0, y: 600), outputs: ["out"])
    let sink = texNode("Sink", at: SZPoint(x: 600, y: 0), inputs: ["input"])
    let cover = texNode("Cover", at: SZPoint(x: 600 - Double(SZNodeLayout.width) / 2, y: 0),
                        inputs: ["input"])
    let graph = SZGraph(nodes: [from, sink, cover], connections: [])
    let source = socket(from, .output, .data, "out")
    let buried = socket(sink, .input, .data, "input")
    #expect(SZGraphCanvasModel.isOccluded(buried, in: graph))   // fixture sanity
    #expect(!SZGraphCanvasModel.isValidTarget(buried, for: source, in: graph, tiers: [:],
                                              pickedConnectionID: nil, isLocked: unlocked))
    #expect(SZGraphCanvasModel.isValidTarget(buried, for: source, in: graph, tiers: [sink.id: 2],
                                             pickedConnectionID: nil, isLocked: unlocked))
}

@Test func swappingOutAnOccupiedInputIsRefusedWhenTheDisplacedEdgeTouchesALockedNode() {
    let (source, sink, conn, graph) = wiredGraph()
    let rival = texNode("Rival", at: SZPoint(x: 0, y: 600), outputs: ["out"])
    var g = graph
    g.nodes.append(rival)
    let newSource = socket(rival, .output, .data, "out")
    let occupied = socket(sink, .input, .data, "input")

    // The displaced edge's source is locked → refuse the swap.
    #expect(!SZGraphCanvasModel.isValidTarget(occupied, for: newSource, in: g, tiers: [:],
                                              pickedConnectionID: nil) { $0 == source.id })
    // Unlocked → the swap is legal.
    #expect(SZGraphCanvasModel.isValidTarget(occupied, for: newSource, in: g, tiers: [:],
                                             pickedConnectionID: nil, isLocked: unlocked))
    // The currently picked-up edge doesn't count as occupying: dropping back restores it.
    #expect(SZGraphCanvasModel.isValidTarget(occupied, for: newSource, in: g, tiers: [:],
                                             pickedConnectionID: conn.id) { $0 == source.id })
}
