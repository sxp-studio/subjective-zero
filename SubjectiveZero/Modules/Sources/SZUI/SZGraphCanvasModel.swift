// SPDX-License-Identifier: AGPL-3.0-only
// Pure helpers that turn the SZStore graph into canvas geometry — used by the connection layer (edge
// endpoints) and by gesture hit-testing. Built on SZNodeLayout so sockets and edges agree. No SwiftUI;
// unit-tested headlessly (SZUITests).
import CoreGraphics
import SZCore

/// One draggable socket on a node, with its world-space point. `port` is "" for flow sockets.
public struct SZSocket: Identifiable, Equatable, Sendable {
    public let nodeID: SZNodeID
    public let side: SZSocketSide
    public let kind: SZConnectionKind
    public let port: String
    public let point: CGPoint
    public var id: String { Self.key(nodeID: nodeID, side: side, kind: kind, port: port) }

    /// The socket's identity without its point — also derivable from a connection end, so the connected
    /// set can be built in one pass over the connections (`connectedSocketIDs`) instead of scanning them
    /// per socket.
    public static func key(nodeID: SZNodeID, side: SZSocketSide, kind: SZConnectionKind, port: String) -> String {
        "\(nodeID.uuidString):\(side):\(kind):\(port)"
    }
}

public enum SZGraphCanvasModel {
    /// World-space point of one of a node's sockets.
    public static func socketPoint(of node: SZNode, side: SZSocketSide, kind: SZConnectionKind, port: String) -> CGPoint {
        let offset = SZNodeLayout.socketOffset(of: node, side: side, kind: kind, port: port)
        return CGPoint(x: CGFloat(node.position.x) + offset.x, y: CGFloat(node.position.y) + offset.y)
    }

    /// Every socket a CONNECTION may target: flow in/out, plus a data socket per declared contract port —
    /// whatever the node's kind.
    ///
    /// Distinct from `sockets(of:)`, which is what the canvas DRAWS. A draft prompt node the Director has
    /// just given a contract owns those ports and is wirable, even though its card shows only flow dots
    /// until it's implemented. Conflating the two makes a rendering rule reject a legal graph edit.
    public static func connectableSockets(of node: SZNode) -> [SZSocket] {
        var result: [SZSocket] = []
        func add(_ side: SZSocketSide, _ kind: SZConnectionKind, _ port: String) {
            result.append(SZSocket(nodeID: node.id, side: side, kind: kind, port: port,
                                   point: socketPoint(of: node, side: side, kind: kind, port: port)))
        }
        add(.input, .flow, "")
        add(.output, .flow, "")
        if let contract = node.contract {
            for p in contract.inputs { add(.input, .data, p.name) }
            for p in contract.outputs { add(.output, .data, p.name) }
        }
        return result
    }

    /// Every interactive socket of ONE node: flow in/out, plus data sockets per declared port on a
    /// generated node (prompt cards show only flow sockets, matching the node views).
    public static func sockets(of node: SZNode) -> [SZSocket] {
        connectableSockets(of: node).filter { $0.kind == .flow || node.kind == .generated }
    }

    /// Every interactive socket in the graph — `sockets(of:)` over every node.
    public static func sockets(in graph: SZGraph) -> [SZSocket] {
        graph.nodes.flatMap(sockets(of:))
    }

    /// Whether `socket` is visually buried under a card that renders ABOVE the socket's own node —
    /// mirror of the canvas z-order: `tiers` (higher rides above, missing = 0), ties broken by
    /// `graph.nodes` order; a node never occludes its own dots (they draw just above its card).
    /// Keeps invisible dots from being wire-drop targets: what you see is what you can hit.
    public static func isOccluded(_ socket: SZSocket, in graph: SZGraph, tiers: [SZNodeID: Int] = [:]) -> Bool {
        guard let ownerIndex = graph.nodes.firstIndex(where: { $0.id == socket.nodeID }) else { return false }
        let ownerTier = tiers[socket.nodeID] ?? 0
        for (i, node) in graph.nodes.enumerated() where node.id != socket.nodeID {
            let tier = tiers[node.id] ?? 0
            guard tier > ownerTier || (tier == ownerTier && i > ownerIndex) else { continue }
            let size = SZNodeLayout.size(of: node)
            let card = CGRect(x: CGFloat(node.position.x) - size.width / 2,
                              y: CGFloat(node.position.y) - size.height / 2,
                              width: size.width, height: size.height)
            if card.contains(socket.point) { return true }
        }
        return false
    }

    /// The IDs of every socket wired by at least one connection, in one O(connections) pass — the
    /// socket layer looks its dots up here instead of scanning all connections per socket. Flow ends
    /// normalize to port "" (a flow ref's port may be "flow", but flow sockets are keyed portless —
    /// same rule the per-socket scan applied). `excluding` drops a picked-up wire so its sockets dim.
    public static func connectedSocketIDs(in graph: SZGraph, excluding excluded: SZConnectionID? = nil) -> Set<String> {
        var result = Set<String>()
        result.reserveCapacity(graph.connections.count * 2)
        for c in graph.connections where c.id != excluded {
            result.insert(SZSocket.key(nodeID: c.from.node, side: .output, kind: c.kind,
                                       port: c.kind == .flow ? "" : c.from.port))
            result.insert(SZSocket.key(nodeID: c.to.node, side: .input, kind: c.kind,
                                       port: c.kind == .flow ? "" : c.to.port))
        }
        return result
    }

    /// The declared type of a node's port (nil if no contract / not found).
    public static func portType(of node: SZNode, side: SZSocketSide, port: String) -> SZPortType? {
        let ports = side == .input ? (node.contract?.inputs ?? []) : (node.contract?.outputs ?? [])
        return ports.first { $0.name == port }?.type
    }

    /// Whether `a`→`b` is a legal connection (order-independent): different nodes, opposite sides, same
    /// kind; data additionally requires equal port types (texture→texture, float→float, …). Flow is
    /// always allowed between an output and an input.
    public static func canConnect(_ a: SZSocket, _ b: SZSocket, in graph: SZGraph) -> Bool {
        guard a.nodeID != b.nodeID, a.side != b.side, a.kind == b.kind else { return false }
        guard a.kind == .data else { return true }
        let out = a.side == .output ? a : b
        let inp = a.side == .input ? a : b
        guard let outNode = graph.node(id: out.nodeID), let inNode = graph.node(id: inp.nodeID),
              let outType = portType(of: outNode, side: .output, port: out.port),
              let inType = portType(of: inNode, side: .input, port: inp.port) else { return false }
        return outType == inType
    }

    /// The data connection feeding an input data socket (nil for flow sockets, outputs, or an unwired
    /// input). Single-valued because a data input holds at most one incoming edge (`SZStore.connect`
    /// swaps). Grabbing such a socket picks its wire up for re-routing instead of starting a new one.
    public static func incomingDataConnection(to socket: SZSocket, in graph: SZGraph) -> SZConnection? {
        guard socket.kind == .data, socket.side == .input else { return nil }
        return graph.connections.first {
            $0.kind == .data && $0.to == SZPortRef(node: socket.nodeID, port: socket.port)
        }
    }

    /// The socket at the end of `connection` OPPOSITE the detached one — where a pickup drag's preview
    /// anchors while the detached end is re-routed. Works for data AND flow edges; the socket's port is
    /// normalized to the canvas convention ("" for flow sockets, whatever the connection ref names for
    /// data). Nil if the edge's endpoints don't resolve.
    public static func pickupAnchor(detaching end: SZConnectionEnd, of connection: SZConnection,
                                    in graph: SZGraph) -> SZSocket? {
        guard let pts = endpoints(of: connection, in: graph) else { return nil }
        let ref = end == .to ? connection.from : connection.to
        return SZSocket(nodeID: ref.node,
                        side: end == .to ? .output : .input,
                        kind: connection.kind,
                        port: connection.kind == .flow ? "" : ref.port,
                        point: end == .to ? pts.from : pts.to)
    }

    /// Which end of `connection` a grab at world-space `point` should detach for re-routing: the
    /// endpoint nearer the grab (nearer the input end → move the input end, nearer the output end →
    /// move the source). Nil if the edge's endpoints don't resolve (an endpoint is still a prompt node).
    public static func detachableEnd(of connection: SZConnection, grabbedAt point: CGPoint,
                                     in graph: SZGraph) -> SZConnectionEnd? {
        guard let pts = endpoints(of: connection, in: graph) else { return nil }
        return hypot(point.x - pts.to.x, point.y - pts.to.y)
            < hypot(point.x - pts.from.x, point.y - pts.from.y) ? .to : .from
    }

    /// Resolve a connection's two endpoints in world space (the output socket of `from`, the input
    /// socket of `to`). Nil if an endpoint node is missing, OR — for a DATA connection — if either
    /// typed port doesn't exist yet (an endpoint is still a prompt node). A data edge is drawn only once
    /// both real ports exist; before that the relationship is carried by a flow (intent) edge, which the
    /// draft step realizes into this data edge (and resolves) once the contract lands.
    public static func endpoints(of connection: SZConnection, in graph: SZGraph) -> (from: CGPoint, to: CGPoint)? {
        guard let fromNode = graph.node(id: connection.from.node),
              let toNode = graph.node(id: connection.to.node) else { return nil }
        if connection.kind == .data {
            guard portType(of: fromNode, side: .output, port: connection.from.port) != nil,
                  portType(of: toNode, side: .input, port: connection.to.port) != nil else { return nil }
        }
        return (
            socketPoint(of: fromNode, side: .output, kind: connection.kind, port: connection.from.port),
            socketPoint(of: toNode, side: .input, kind: connection.kind, port: connection.to.port)
        )
    }
}
