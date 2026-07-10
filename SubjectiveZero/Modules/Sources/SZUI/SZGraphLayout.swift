// SPDX-License-Identifier: AGPL-3.0-only
// Auto-layout for the node canvas — the "Tidy Graph" command's brain. Given the graph, it computes a
// clean left-to-right layered (Sugiyama-style) placement: nodes flow into columns by dependency depth,
// so upstream sits left of downstream and the wire tangle straightens out. Pure and SwiftUI-free (built
// on SZNodeLayout for card sizing), so it is unit-testable headlessly and callable from the host.
//
// node.position is the card CENTER (see SZNodeLayout), so
// every returned point is a center; the result recenters on the original graph midpoint so a tidy keeps
// the graph roughly where the user left it rather than teleporting it to the origin.
import CoreGraphics
import SZCore

public enum SZGraphLayout {
    /// Column-to-column gap (world pt) between dependency layers.
    static let layerGap: CGFloat = 110
    /// Vertical gap (world pt) between cards stacked within a layer.
    static let nodeGap: CGFloat = 42

    /// Compute tidied positions for every node. Returns `[nodeID: newCenter]`. Empty if there are no
    /// nodes. The graph is shifted back so it stays under the same camera: pinned to `anchor`'s old
    /// position if given (the render endpoint — "keep what you're viewing in place"), else to the nodes'
    /// per-axis median (robust to a far outlier, unlike a bounding-box midpoint). Callers can commit the
    /// whole map through `SZStore.moveNodes` without the graph jumping across the canvas.
    public static func tidied(nodes: [SZNode], connections: [SZConnection],
                              anchor: SZNodeID? = nil) -> [SZNodeID: SZPoint] {
        guard !nodes.isEmpty else { return [:] }
        let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

        // Incoming adjacency: for each node, the set of nodes feeding it. Both edge kinds contribute the
        // same node→node dependency (data = a realized wire, flow = intent toward one); a Set dedupes any
        // node pair that happens to carry both.
        var incoming: [SZNodeID: Set<SZNodeID>] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, []) })
        for c in connections where nodesByID[c.from.node] != nil && nodesByID[c.to.node] != nil {
            incoming[c.to.node, default: []].insert(c.from.node)
        }

        // Layer each node one deeper than its deepest upstream. Walk in topological order so upstream
        // layers are always resolved first; nodes in a cycle (never emitted by the sort) fall back to 0.
        let ordered = topologicalOrder(nodeIDs: nodes.map(\.id), incoming: incoming)
        var layerByID: [SZNodeID: Int] = [:]
        for id in ordered {
            let upstream = incoming[id] ?? []
            layerByID[id] = upstream.compactMap { layerByID[$0] }.max().map { $0 + 1 } ?? 0
        }
        for node in nodes where layerByID[node.id] == nil { layerByID[node.id] = 0 }

        // Group into columns; within a column keep the user's rough vertical ordering (by current y,
        // then title) so a tidy re-flows rather than shuffles.
        let grouped = Dictionary(grouping: nodes.map(\.id)) { layerByID[$0] ?? 0 }
        let layers = grouped.keys.sorted().map { layer in
            grouped[layer, default: []].sorted { lhs, rhs in
                let ly = nodesByID[lhs]?.position.y ?? 0
                let ry = nodesByID[rhs]?.position.y ?? 0
                if ly == ry { return (nodesByID[lhs]?.title ?? "") < (nodesByID[rhs]?.title ?? "") }
                return ly < ry
            }
        }

        // Lay columns left→right at a fixed pitch (all cards in a column share a center x); stack cards
        // top→down by their own heights + nodeGap. Origin is arbitrary — recentering below fixes it.
        let maxNodeWidth = nodes.map { SZNodeLayout.size(of: $0).width }.max() ?? SZNodeLayout.width
        var positions: [SZNodeID: SZPoint] = [:]
        for (layerIndex, layer) in layers.enumerated() {
            let centerX = CGFloat(layerIndex) * (maxNodeWidth + layerGap)
            var top: CGFloat = 0
            for id in layer {
                guard let node = nodesByID[id] else { continue }
                let height = SZNodeLayout.size(of: node).height
                positions[id] = SZPoint(x: Double(centerX), y: Double(top + height / 2))
                top += height + nodeGap
            }
        }

        // Shift the tidied graph back under the same camera. Prefer pinning the ANCHOR node (the render
        // endpoint — what the user is looking at) to its old position: this keeps what you're viewing put
        // regardless of a far outlier (a bounding-box midpoint would get dragged tens of thousands of px by
        // one node fat-fingered to 99999,99999, stranding the layout off-screen). Fall back to the per-axis
        // median (still outlier-resistant for a minority outlier) when there's no anchor.
        let oldCenter: SZPoint?
        let newCenter: SZPoint?
        if let anchor, let old = nodesByID[anchor]?.position, let new = positions[anchor] {
            oldCenter = old; newCenter = new
        } else {
            oldCenter = medianCenter(of: nodes.map(\.position))
            newCenter = medianCenter(of: nodes.compactMap { positions[$0.id] })
        }
        if let oldCenter, let newCenter {
            let dx = oldCenter.x - newCenter.x
            let dy = oldCenter.y - newCenter.y
            for id in positions.keys { positions[id]?.x += dx; positions[id]?.y += dy }
        }
        return positions
    }

    /// Kahn topological sort over the incoming-adjacency map. Nodes still carrying incoming edges when
    /// the queue drains (i.e. inside a cycle) are simply omitted — the caller layers them at 0.
    private static func topologicalOrder(nodeIDs: [SZNodeID], incoming: [SZNodeID: Set<SZNodeID>]) -> [SZNodeID] {
        var remaining = incoming.mapValues { $0.count }   // in-degree per node
        var outgoing: [SZNodeID: [SZNodeID]] = [:]
        for (to, froms) in incoming { for from in froms { outgoing[from, default: []].append(to) } }

        // Seed with in-degree-0 nodes in the graph's node order (stable, deterministic).
        var queue = nodeIDs.filter { (remaining[$0] ?? 0) == 0 }
        var result: [SZNodeID] = []
        var head = 0
        while head < queue.count {
            let id = queue[head]; head += 1
            result.append(id)
            for next in outgoing[id] ?? [] {
                let d = (remaining[next] ?? 0) - 1
                remaining[next] = d
                if d == 0 { queue.append(next) }
            }
        }
        return result
    }

    /// Per-axis median of a set of node centers — robust to a far outlier that a bounding-box midpoint
    /// would chase (and thereby fling the whole tidied layout off-screen). Nil for an empty set.
    private static func medianCenter(of points: [SZPoint]) -> SZPoint? {
        guard !points.isEmpty else { return nil }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            let mid = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        }
        return SZPoint(x: median(points.map(\.x)), y: median(points.map(\.y)))
    }
}
