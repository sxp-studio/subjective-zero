// SPDX-License-Identifier: AGPL-3.0-only
// Port derivation for contract-less nodes: what a node's data wiring implies its ports are,
// straight from the graph. The brief renderer briefs agents with these; the neutral home
// exists so nothing prompt-shaped depends on orchestration files — this is the single home
// for the derivation.
import Foundation

extension SZGraph {
    /// The distinct data-input ports wired into `node`, first-wire order.
    public func derivedDataInputPorts(of node: SZNodeID) -> [String] {
        Self.orderedPorts(connections.filter { $0.kind == .data && $0.to.node == node }.map(\.to.port))
    }

    /// The distinct data-output ports wired out of `node` (render endpoint included),
    /// first-wire order.
    public func derivedOutputPorts(of node: SZNodeID) -> [String] {
        var ports = connections.filter { $0.kind == .data && $0.from.node == node }.map(\.from.port)
        if let endpoint = renderEndpoint, endpoint.node == node { ports.append(endpoint.port) }
        return Self.orderedPorts(ports)
    }

    private static func orderedPorts(_ ports: [String]) -> [String] {
        var seen = Set<String>()
        return ports.filter { seen.insert($0).inserted }
    }
}
