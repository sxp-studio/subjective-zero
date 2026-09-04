// SPDX-License-Identifier: AGPL-3.0-only
// The projection every renderer loads: built nodes only. A prompt node has no source to run yet.
import Foundation

public extension SZGraph {
    /// The subgraph a runtime can actually render: `generated` nodes built for the active target, the
    /// connections among them, and the render endpoint only if its node is one of them. A node without a
    /// source for this platform stays out, so a missing file never fails the whole load.
    var renderable: SZGraph {
        let generated = Set(nodes.filter { $0.kind == .generated && $0.builtForTarget }.map(\.id))
        return SZGraph(
            nodes: nodes.filter { generated.contains($0.id) },
            connections: connections.filter { generated.contains($0.from.node) && generated.contains($0.to.node) },
            renderEndpoint: renderEndpoint.flatMap { generated.contains($0.node) ? $0 : nil })
    }
}
