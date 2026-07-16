// SPDX-License-Identifier: AGPL-3.0-only
// Which nodes are on screen — the culling input for the live-preview watch set. Pure math over the
// panel-local camera and SZNodeLayout's card rects (the SAME rects hit-testing and the LOD tiles
// use, so "visible" here is exactly "drawn"). No SwiftUI, unit-tested headlessly.
import CoreGraphics
import SZCore

enum SZCanvasVisibility {
    /// Nodes whose card rect intersects the current screen viewport, inflated by `overscan` (a
    /// fraction of the viewport per side) so cards just off the edge keep streaming — a small pan
    /// reveals a live thumb, not a placeholder that then pops.
    static func visibleNodes(in graph: SZGraph, camera: SZCanvasCamera, viewSize: CGSize,
                             overscan: CGFloat = 0.25) -> Set<SZNodeID> {
        guard viewSize.width > 0, viewSize.height > 0 else { return [] }
        let inset = CGSize(width: viewSize.width * overscan, height: viewSize.height * overscan)
        let topLeft = camera.worldPoint(screen: CGPoint(x: -inset.width, y: -inset.height))
        let bottomRight = camera.worldPoint(screen: CGPoint(x: viewSize.width + inset.width,
                                                            y: viewSize.height + inset.height))
        let viewport = CGRect(x: topLeft.x, y: topLeft.y,
                              width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
        return Set(graph.nodes.filter { SZNodeLayout.cardRect(of: $0).intersects(viewport) }.map(\.id))
    }
}
