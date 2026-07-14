// SPDX-License-Identifier: AGPL-3.0-only
// The node-editor camera — zoom + pan offset and the transforms derived from them. A plain value
// held in the panel's @State, not observable on purpose (like SZEdgeAutoPanDriver): gesture closures
// inside the `.equatable()`-skipped content subtree can be from an older render, so camera reads go
// through the panel's live state and snapshots (the pinch anchor) are cheap copies. No SwiftUI, so
// the zoom-about-pivot and framing math is unit-tested headlessly (SZUITests).
import CoreGraphics

struct SZCanvasCamera: Equatable, Sendable {
    var zoom: CGFloat = 1
    var offset: CGSize = .zero

    static let zoomRange: ClosedRange<CGFloat> = 0.35...2.4

    /// Screen → world: inverse of the canvas layer's `.scaleEffect(zoom).offset(offset)`.
    func worldPoint(screen: CGPoint) -> CGPoint {
        SZNodeLayout.worldPoint(screen: screen, zoom: zoom, offset: offset)
    }

    /// World → screen: the forward transform (screen = world·zoom + offset).
    func screenPoint(world: CGPoint) -> CGPoint {
        CGPoint(x: world.x * zoom + offset.width, y: world.y * zoom + offset.height)
    }

    /// Slide the camera by a screen-space delta (two-finger scroll, edge auto-pan).
    mutating func pan(by delta: CGSize) {
        offset.width += delta.width
        offset.height += delta.height
    }

    /// Set zoom to `target` (clamped) while keeping `pivot` (screen space) over the same world point
    /// that sat under it in `anchor` — the camera snapshotted at pinch start, or the live camera for
    /// a wheel zoom tick.
    mutating func applyZoom(_ target: CGFloat, pivot: CGPoint, from anchor: SZCanvasCamera) {
        let world = anchor.worldPoint(screen: pivot)
        zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, target))
        offset = CGSize(width: pivot.x - world.x * zoom, height: pivot.y - world.y * zoom)
    }

    /// The camera that puts `bounds`' midpoint at the viewport center, keeping `zoom` (Center View).
    static func centered(on bounds: CGRect, in viewSize: CGSize, zoom: CGFloat) -> SZCanvasCamera {
        SZCanvasCamera(zoom: zoom,
                       offset: CGSize(width: viewSize.width / 2 - bounds.midX * zoom,
                                      height: viewSize.height / 2 - bounds.midY * zoom))
    }

    /// The camera that frames `bounds` with a proportional margin at a clamped zoom (Zoom to Fit).
    static func fitting(_ bounds: CGRect, in viewSize: CGSize) -> SZCanvasCamera {
        let framed = bounds.insetBy(dx: -max(80, bounds.width * 0.14),
                                    dy: -max(80, bounds.height * 0.14))
        let zoom = min(zoomRange.upperBound,
                       max(zoomRange.lowerBound,
                           min(viewSize.width / framed.width, viewSize.height / framed.height)))
        return centered(on: framed, in: viewSize, zoom: zoom)
    }
}
