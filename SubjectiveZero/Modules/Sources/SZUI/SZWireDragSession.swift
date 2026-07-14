// SPDX-License-Identifier: AGPL-3.0-only
// The wire-drag state machine — grab (fresh wire or edge pickup), per-tick tracking (click guard +
// target snap), and the pure drop decision. A plain value held in the panel's @State; it emits
// intents (`Outcome`) and never touches the store or host, so the branchy pickup / re-route /
// disconnect / spawn logic is unit-tested headlessly (SZUITests). Locking rules come in as an
// `isLocked` closure; the panel's own per-tick guards (the grabbed node, an edge's two ends) stay
// at the gesture adapters.
import CoreGraphics
import SZCore

struct SZWireDragSession {
    let grabbed: SZSocket   // the socket the gesture started on (gesture identity across ticks)
    let source: SZSocket    // the preview wire's fixed anchor — the KEPT end's socket for a pickup
    let start: CGPoint      // world point where the grab began (click/wobble guard)
    var current: CGPoint
    var lastScreen: CGPoint // last cursor position, screen (szcanvas) space — auto-pan re-derivation
    var target: SZSocket?
    let picked: (id: SZConnectionID, end: SZConnectionEnd, original: SZPortRef)?   // re-routing an edge
    var moved = false       // passed the click guard — a plain click must not drop/disconnect

    /// Begin from a SOCKET grab. Grabbing a CONNECTED data input picks its wire up to re-route: the
    /// preview re-anchors to the far output socket and the original edge hides until drop — refused
    /// when the far end is locked (re-routing would unwire its node too, the same both-ends rule as
    /// the edge-path pickup). Everything else (outputs, flow, unwired inputs) starts a new wire — a
    /// flow-in holds N edges, so its wires are picked up along their paths instead.
    static func begin(from socket: SZSocket, atWorld world: CGPoint, screen: CGPoint,
                      in graph: SZGraph, isLocked: (SZNodeID) -> Bool) -> SZWireDragSession? {
        if let conn = SZGraphCanvasModel.incomingDataConnection(to: socket, in: graph),
           let anchor = SZGraphCanvasModel.pickupAnchor(detaching: .to, of: conn, in: graph) {
            guard !isLocked(conn.from.node) else { return nil }
            return SZWireDragSession(grabbed: socket, source: anchor, start: world, current: world,
                                     lastScreen: screen, target: nil,
                                     picked: (conn.id, .to, conn.to))
        }
        return SZWireDragSession(grabbed: socket, source: socket, start: world, current: world,
                                 lastScreen: screen, target: nil, picked: nil)
    }

    /// Begin from a grab anywhere ALONG an edge (data or flow): the end nearer the grab detaches
    /// (nearer the input → re-route the input end, nearer the output → re-route the source) and the
    /// preview anchors at the kept end. Nil if the edge's endpoints don't resolve.
    static func begin(along connection: SZConnection, atWorld world: CGPoint, screen: CGPoint,
                      in graph: SZGraph) -> SZWireDragSession? {
        guard let end = SZGraphCanvasModel.detachableEnd(of: connection, grabbedAt: world, in: graph),
              let anchor = SZGraphCanvasModel.pickupAnchor(detaching: end, of: connection, in: graph)
        else { return nil }
        return SZWireDragSession(grabbed: anchor, source: anchor, start: world, current: world,
                                 lastScreen: screen, target: nil,
                                 picked: (connection.id, end, end == .to ? connection.to : connection.from))
    }

    /// Shared per-tick update for both wire gestures: track the cursor, arm the click guard once the
    /// grab has really moved (world-space, zoom-aware), and snap to the nearest legal target.
    mutating func update(toWorld world: CGPoint, zoom: CGFloat, in graph: SZGraph,
                         tiers: [SZNodeID: Int], isLocked: (SZNodeID) -> Bool) {
        current = world
        if hypot(world.x - start.x, world.y - start.y) > 8 / max(zoom, 0.1) { moved = true }
        target = SZGraphCanvasModel.snapTarget(for: source, at: world, zoom: zoom, in: graph,
                                               tiers: tiers, pickedConnectionID: picked?.id,
                                               isLocked: isLocked)
    }

    /// What a drop should do — the panel dispatches to the host/store.
    enum Outcome: Equatable {
        case none
        case connect(from: SZPortRef, to: SZPortRef, kind: SZConnectionKind)
        case reconnect(SZConnectionID, SZConnectionEnd, SZPortRef)
        case disconnect(SZConnectionID)
        /// A fresh FLOW (intent) wire dropped on empty canvas — "drag into space" means "generate
        /// something here": spawn a prompt node at `center` (raw; the panel applies its snap rule)
        /// and join it with a flow edge. `downstream` follows the dragged socket (flow-OUT → source
        /// feeds new; flow-IN → new feeds source).
        case spawnPromptNode(center: CGPoint, source: SZPortRef, downstream: Bool)
    }

    /// The drop decision: a picked-up edge re-routes (or disconnects on an empty drop), a fresh wire
    /// connects, a fresh flow wire in space spawns. Pure — reads only the session.
    func outcome() -> Outcome {
        if let picked {
            guard moved else { return .none }               // plain click / sub-threshold wobble: no-op
            guard let target else { return .disconnect(picked.id) }   // dropped on empty canvas
            let ref = SZPortRef(node: target.nodeID, port: target.port)
            // Dropping back on the original port restores the wire untouched. Flow compares nodes
            // only: the socket port is "" but a flow ref's port may be "flow" (ensureFlow).
            let unchanged = source.kind == .flow
                ? ref.node == picked.original.node : ref == picked.original
            return unchanged ? .none : .reconnect(picked.id, picked.end, ref)
        }
        if let target {
            let out = source.side == .output ? source : target
            let inp = source.side == .input ? source : target
            return .connect(from: SZPortRef(node: out.nodeID, port: out.port),
                            to: SZPortRef(node: inp.nodeID, port: inp.port), kind: out.kind)
        }
        if moved, source.kind == .flow {
            // Anchor the new node by the EDGE the wire lands on, not its centroid: drop from a
            // flow-OUT and the node grows rightward with its LEFT edge (input side) at the drop
            // point; drop from a flow-IN and it grows leftward with its RIGHT edge at the drop. So
            // the wire terminates cleanly at the node's socket instead of burying the drop point in
            // the card's middle. Shift the centroid by half the (fixed) prompt-node width toward the
            // flow direction. Snapping is the panel's (snappedPromptCenter), not the session's.
            var center = current
            center.x += source.side == .output ? SZNodeLayout.width / 2 : -SZNodeLayout.width / 2
            return .spawnPromptNode(center: center,
                                    source: SZPortRef(node: source.nodeID, port: "flow"),
                                    downstream: source.side == .output)
        }
        return .none
    }
}
