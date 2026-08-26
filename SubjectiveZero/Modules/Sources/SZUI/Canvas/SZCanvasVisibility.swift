// SPDX-License-Identifier: AGPL-3.0-only
// Which nodes are on screen — the culling input for the live-preview watch set. Pure math over the
// panel-local camera and SZNodeLayout's card rects (the SAME rects hit-testing and the LOD tiles
// use, so "visible" here is exactly "drawn"). No SwiftUI, unit-tested headlessly.
import CoreGraphics
import SZCore

enum SZCanvasVisibility {
    /// Overscan per side, as a fraction of the viewport: cards just off the edge keep streaming, so
    /// a small pan reveals a live thumb, not a placeholder that then pops.
    static let overscan: CGFloat = 0.25

    /// Nodes whose card rect intersects the current screen viewport (inflated by `overscan`).
    static func visibleNodes(in graph: SZGraph, camera: SZCanvasCamera, viewSize: CGSize,
                             previewsEnabled: Bool) -> Set<SZNodeID> {
        guard viewSize.width > 0, viewSize.height > 0 else { return [] }
        let screen = CGRect(origin: .zero, size: viewSize)
            .insetBy(dx: -viewSize.width * overscan, dy: -viewSize.height * overscan)
        let viewport = SZMiniMapLayout.viewportWorldRect(camera: camera, screen: screen)
        return Set(graph.nodes.filter {
            SZNodeLayout.cardRect(of: $0, previewsEnabled: previewsEnabled).intersects(viewport)
        }.map(\.id))
    }
}
