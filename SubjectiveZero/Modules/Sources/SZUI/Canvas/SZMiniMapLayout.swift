// SPDX-License-Identifier: AGPL-3.0-only
// The mini map's geometry — the world rect it shows (graph bounds ∪ viewport, so the viewport is never
// off the map) and the world↔map transform that fits it into the thumbnail. Pure math over the panel-
// local camera and SZNodeLayout's card rects (the SAME rects hit-testing, culling and the LOD tiles
// use). No SwiftUI, unit-tested headlessly (SZUITests).
import CoreGraphics

struct SZMiniMapLayout: Equatable {
    /// Thumbnail content area (the drawn map, inside the glass card's padding).
    static let size = CGSize(width: 184, height: 120)
    /// Breathing room around the extent, as a fraction of its larger side.
    static let margin: CGFloat = 0.06

    /// World rect shown = union(graph bounds, viewport rect), padded by `margin`.
    let extent: CGRect
    /// World → map scale (aspect-preserving fit of `extent` into `size`).
    let scale: CGFloat
    /// Map-space origin of `extent.origin` — the fitted extent is centered in `size`.
    let origin: CGPoint
    let size: CGSize

    init(graphBounds: CGRect?, viewport: CGRect, size: CGSize = Self.size) {
        var box = viewport
        if let graphBounds { box = box.union(graphBounds) }
        let pad = max(box.width, box.height) * Self.margin
        let extent = box.insetBy(dx: -pad, dy: -pad)
        let scale = extent.width > 0 && extent.height > 0
            ? min(size.width / extent.width, size.height / extent.height)
            : 1
        self.extent = extent
        self.scale = scale
        self.size = size
        self.origin = CGPoint(x: (size.width - extent.width * scale) / 2,
                              y: (size.height - extent.height * scale) / 2)
    }

    func mapPoint(world: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + (world.x - extent.minX) * scale,
                y: origin.y + (world.y - extent.minY) * scale)
    }

    func mapRect(world: CGRect) -> CGRect {
        let o = mapPoint(world: world.origin)
        return CGRect(x: o.x, y: o.y, width: world.width * scale, height: world.height * scale)
    }

    /// Map → world: the inverse (a click / drag on the map → where to put the camera).
    func worldPoint(map: CGPoint) -> CGPoint {
        CGPoint(x: extent.minX + (map.x - origin.x) / scale,
                y: extent.minY + (map.y - origin.y) / scale)
    }

    /// The camera that centers the viewport on the world point under a map click, keeping zoom.
    func cameraCentering(mapPoint: CGPoint, camera: SZCanvasCamera, viewSize: CGSize) -> SZCanvasCamera {
        .centered(on: CGRect(origin: worldPoint(map: mapPoint), size: .zero), in: viewSize, zoom: camera.zoom)
    }

    /// The camera after dragging the map by `translation` (map points) from `start`: the viewport
    /// moves the same WORLD distance the pointer travelled on the map, so the rectangle stays under
    /// the cursor.
    func cameraDragging(by translation: CGSize, from start: SZCanvasCamera) -> SZCanvasCamera {
        var camera = start
        camera.pan(by: CGSize(width: -translation.width / scale * start.zoom,
                              height: -translation.height / scale * start.zoom))
        return camera
    }

    /// The screen viewport in world space — the rect the camera currently shows (no overscan). The
    /// one home for that math; SZCanvasVisibility feeds it an inflated screen rect for culling.
    static func viewportWorldRect(camera: SZCanvasCamera, screen: CGRect) -> CGRect {
        let topLeft = camera.worldPoint(screen: CGPoint(x: screen.minX, y: screen.minY))
        let bottomRight = camera.worldPoint(screen: CGPoint(x: screen.maxX, y: screen.maxY))
        return CGRect(x: topLeft.x, y: topLeft.y,
                      width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    }

    static func viewportWorldRect(camera: SZCanvasCamera, viewSize: CGSize) -> CGRect {
        viewportWorldRect(camera: camera, screen: CGRect(origin: .zero, size: viewSize))
    }
}
