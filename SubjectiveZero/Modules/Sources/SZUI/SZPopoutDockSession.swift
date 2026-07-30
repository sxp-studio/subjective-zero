// SPDX-License-Identifier: AGPL-3.0-only
// Drag-to-dock hit-testing — the pure math behind dragging a popped-out panel window over the main
// window: screen point ↔ container point conversion (AppKit's bottom-left origin vs the container's
// top-left), the dock candidate under the cursor (reusing SZPanelLayoutGeometry's zones), and the
// relaunch restore-frame sanitizer. Headless like SZWireDragSession, so SZUITests pins the behavior;
// the window manager (SZApp) only feeds it events and renders the result.
import CoreGraphics
import Foundation
import SZCore

public enum SZPopoutDockSession {
    /// A dock spot under the drag cursor: split `target` on `zone` (never `.center` — a detached
    /// panel has nothing to swap with, so docking only ever splits) with `preview` in container space.
    public struct Candidate: Equatable, Sendable {
        public var target: SZPanelID
        public var zone: SZPanelDropZone
        public var preview: CGRect

        public init(target: SZPanelID, zone: SZPanelDropZone, preview: CGRect) {
            self.target = target
            self.zone = zone
            self.preview = preview
        }
    }

    /// Every tile's rect for a container of `containerSize` — THE shared layout math for
    /// everything that reasons about the main window's tiles from outside the container view
    /// (dock hit-testing, tear-out/pop-out placement, dock-flight targets): same insets, same
    /// maximize override (the maximized panel owns the whole rect) as the container's renderer.
    public static func tileFrames(layout: SZPanelLayoutState, maximized: SZPanelID?,
                                  containerSize: CGSize, topInset: CGFloat) -> [SZPanelID: CGRect] {
        let gap = SZPanelLayoutGeometry.outerGap
        let rect = CGRect(x: gap, y: topInset, width: max(containerSize.width - gap * 2, 0),
                          height: max(containerSize.height - topInset - gap, 0))
        let isMax = maximized.map(layout.contains) ?? false
        return isMax ? [maximized!: rect]
                     : SZPanelLayoutGeometry.leafFrames(root: layout.root, in: rect)
    }

    /// The dock candidate for a container-space cursor point, or nil when the cursor is over no
    /// tile. Drop zones with `.center` resolved to the nearest edge.
    public static func candidate(at point: CGPoint, layout: SZPanelLayoutState,
                                 maximized: SZPanelID?, containerSize: CGSize,
                                 topInset: CGFloat) -> Candidate? {
        let frames = tileFrames(layout: layout, maximized: maximized,
                                containerSize: containerSize, topInset: topInset)
        guard let (target, frame) = frames.first(where: { $0.value.contains(point) }) else { return nil }
        let zone = nearestEdgeZone(at: point, in: frame)
        return Candidate(target: target, zone: zone,
                         preview: SZPanelLayoutGeometry.dropPreviewRect(zone: zone, in: frame))
    }

    /// `dropZone(at:in:)` with `.center` resolved to the nearest edge (normalized distance; ties
    /// break in left → right → top → bottom order, matching the geometry's own edge ordering).
    /// Internal: only `candidate` and the tests exercise it.
    static func nearestEdgeZone(at point: CGPoint, in rect: CGRect) -> SZPanelDropZone {
        let zone = SZPanelLayoutGeometry.dropZone(at: point, in: rect)
        guard zone == .center else { return zone }
        guard rect.width > 0, rect.height > 0 else { return .left }
        let toLeft = (point.x - rect.minX) / rect.width
        let toRight = (rect.maxX - point.x) / rect.width
        let toTop = (point.y - rect.minY) / rect.height
        let toBottom = (rect.maxY - point.y) / rect.height
        let nearest = min(toLeft, toRight, toTop, toBottom)
        if nearest == toLeft { return .left }
        if nearest == toRight { return .right }
        if nearest == toTop { return .top }
        return .bottom
    }

    // MARK: - Screen ↔ container conversion

    /// A screen point (AppKit, bottom-left origin) → the container's top-left-origin space, given
    /// the CONTENT view's screen frame and the titlebar safe-area height the container sits under.
    public static func containerPoint(fromScreen point: CGPoint, contentScreenFrame: CGRect,
                                      safeAreaTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x - contentScreenFrame.minX,
                y: contentScreenFrame.maxY - point.y - safeAreaTop)
    }

    /// A container-space rect → screen space (the inverse of `containerPoint`) — where a pop-out
    /// window must be created so it exactly covers a tile, and where a docking window animates to.
    public static func screenRect(forContainerRect rect: CGRect, contentScreenFrame: CGRect,
                                  safeAreaTop: CGFloat) -> CGRect {
        CGRect(x: contentScreenFrame.minX + rect.minX,
               y: contentScreenFrame.maxY - safeAreaTop - rect.maxY,
               width: rect.width, height: rect.height)
    }

    // MARK: - Relaunch restore

    /// Sanitize a persisted pop-out frame against the current screens: nil when the frame is
    /// smaller than the panel's minimum (corrupt — don't restore), recentered on the first screen
    /// when no screen shows a meaningful slice of it (a disconnected display must not strand the
    /// window off-screen).
    public static func sanitizedRestoreFrame(_ frame: CGRect, visibleScreenFrames: [CGRect],
                                             minSize: CGSize) -> CGRect? {
        guard frame.width >= minSize.width, frame.height >= minSize.height,
              let first = visibleScreenFrames.first else { return nil }
        let visiblyOn = visibleScreenFrames.contains { screen in
            let slice = screen.intersection(frame)
            return slice.width >= 80 && slice.height >= 40   // enough to grab the header
        }
        if visiblyOn { return frame }
        let size = CGSize(width: min(frame.width, first.width), height: min(frame.height, first.height))
        return CGRect(x: first.midX - size.width / 2, y: first.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
