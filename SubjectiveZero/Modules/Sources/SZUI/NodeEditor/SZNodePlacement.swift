// SPDX-License-Identifier: AGPL-3.0-only
// Where an agent-added card lands when the call names a neighbour instead of coordinates. Pure
// math over SZNodeLayout's card rects, using SZGraphLayout's gaps so the placement matches what
// Tidy would put there. No SwiftUI; unit-tested headlessly.
import CoreGraphics
import SZCore

public enum SZNodePlacement {
    /// Where a card lands on an empty graph: the add handlers' old fixed spot.
    public static let emptyGraphDefault = CGPoint(x: 240, y: 240)

    /// Center for a new card of `size` one column right of `anchor`, on its row, stepped down past
    /// any card it would overlap.
    public static func after(_ anchor: SZNode, size: CGSize, in graph: SZGraph,
                             previewsEnabled: Bool) -> CGPoint {
        let card = SZNodeLayout.cardRect(of: anchor, previewsEnabled: previewsEnabled)
        let start = CGPoint(x: card.maxX + SZGraphLayout.layerGap + size.width / 2, y: card.midY)
        return free(from: start, size: size, in: graph, previewsEnabled: previewsEnabled)
    }

    /// Center for a new card with no neighbour: one column right of the whole graph, at its
    /// vertical middle. A `source` (nothing feeds it) goes one column left instead.
    public static func beside(graph: SZGraph, size: CGSize, previewsEnabled: Bool,
                              source: Bool = false) -> CGPoint {
        guard let bounds = SZGraphCanvasModel.worldBounds(of: graph, previewsEnabled: previewsEnabled)
        else { return emptyGraphDefault }
        let x = source ? bounds.minX - SZGraphLayout.layerGap - size.width / 2
                       : bounds.maxX + SZGraphLayout.layerGap + size.width / 2
        return free(from: CGPoint(x: x, y: bounds.midY), size: size, in: graph, previewsEnabled: previewsEnabled)
    }

    /// Step `center` down past every card it would overlap, keeping `nodeGap` clear.
    private static func free(from center: CGPoint, size: CGSize, in graph: SZGraph,
                             previewsEnabled: Bool) -> CGPoint {
        let gap = SZGraphLayout.nodeGap
        let taken = graph.nodes.map {
            SZNodeLayout.cardRect(of: $0, previewsEnabled: previewsEnabled).insetBy(dx: -gap, dy: -gap)
        }
        var center = center
        for _ in 0...(taken.count * 2) {
            let card = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                              width: size.width, height: size.height)
            guard let hit = taken.first(where: { $0.intersects(card) }) else { break }
            center.y = hit.maxY + size.height / 2
        }
        return center
    }
}
