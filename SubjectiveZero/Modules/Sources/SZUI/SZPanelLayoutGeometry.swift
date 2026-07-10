// SPDX-License-Identifier: AGPL-3.0-only
// Panel-layout geometry — the pure math between the SZCore split tree and the pixels: leaf/divider
// rects, divider-drag → fraction, and drop-zone hit-testing. Headless (no views), like SZNodeLayout,
// so the layout behavior is pinned down by SZUITests before any rendering exists.
//
// Min sizes clamp every split: a divider can't push a panel below its minimum, and when the window
// itself is too small for a split's minimums the children degrade proportionally (never negative).
import CoreGraphics
import Foundation
import SZCore

public enum SZPanelLayoutGeometry {
    /// Gap between panel tiles — the whole strip is the divider's grab area (no drawn line; the
    /// window background shows through and the resize cursor signals the affordance).
    public static let dividerThickness: CGFloat = 8

    /// Breathing room between the window edges and the panel tiles (the "sections of the window"
    /// look: rounded tiles floating on the window background).
    public static let outerGap: CGFloat = 8

    /// Panel tile corner radius.
    public static let tileCornerRadius: CGFloat = 8

    /// Per-panel minimum content sizes (ports of the old SplitView `.frame(min…)` constraints; the
    /// chat's old 540 max-width is deliberately dropped — a hard max is hostile in a free layout).
    public static func minSize(for kind: SZPanelKind) -> CGSize {
        switch kind {
        case .viewport: CGSize(width: 240, height: 180)
        case .nodeEditor: CGSize(width: 480, height: 160)
        case .chat: CGSize(width: 280, height: 160)
        }
    }

    /// A divider between the two children of a split: `rect` is the grabbable strip, `path` addresses
    /// the split for `setFraction`, `splitRect` is the split's full rect (drag → fraction math).
    public struct SZPanelDividerFrame: Equatable {
        public var path: SZPanelNodePath
        public var orientation: SZPanelSplitOrientation
        public var rect: CGRect
        public var splitRect: CGRect
    }

    // MARK: - Layout

    /// The rect of every panel leaf, tiling `rect` (dividers carved out).
    public static func leafFrames(root: SZPanelLayoutNode, in rect: CGRect) -> [SZPanelKind: CGRect] {
        var frames: [SZPanelKind: CGRect] = [:]
        walk(root, in: rect) { kind, leafRect in frames[kind] = leafRect } onDivider: { _ in }
        return frames
    }

    /// Every divider strip, front-to-back irrelevant (they never overlap).
    public static func dividerFrames(root: SZPanelLayoutNode, in rect: CGRect) -> [SZPanelDividerFrame] {
        var dividers: [SZPanelDividerFrame] = []
        walk(root, in: rect) { _, _ in } onDivider: { dividers.append($0) }
        return dividers
    }

    /// A divider drag: cursor location (container space) → the split's new leading fraction.
    /// Raw position math only — min-size clamping is applied by the layout itself, and
    /// `normalize()` clamps the committed value to 0.1…0.9.
    public static func fraction(forDividerAt location: CGPoint, orientation: SZPanelSplitOrientation,
                                in splitRect: CGRect) -> Double {
        let available = axisLength(of: splitRect, along: orientation) - dividerThickness
        guard available > 0 else { return 0.5 }
        let offset = orientation == .horizontal ? location.x - splitRect.minX : location.y - splitRect.minY
        return min(max(Double((offset - dividerThickness / 2) / available), 0), 1)
    }

    // MARK: - Drop zones

    /// Which zone of a hovered panel the cursor is in: the inner 50%-inset core is `.center` (swap);
    /// outside it, the nearest edge (normalized distance) wins (split).
    public static func dropZone(at point: CGPoint, in rect: CGRect) -> SZPanelDropZone {
        guard rect.width > 0, rect.height > 0 else { return .center }
        let core = rect.insetBy(dx: rect.width / 4, dy: rect.height / 4)
        if core.contains(point) { return .center }
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

    /// The tinted preview for a pending drop: the half of the target the dragged panel would take
    /// (edge zones), or the whole target (center = swap).
    public static func dropPreviewRect(zone: SZPanelDropZone, in rect: CGRect) -> CGRect {
        switch zone {
        case .left: CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right: CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .bottom: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        case .center: rect
        }
    }

    // MARK: - Internals

    /// Minimum length of a subtree along one window axis: splits on that axis sum (plus divider),
    /// splits across it take the max of their children.
    static func minLength(of node: SZPanelLayoutNode, along orientation: SZPanelSplitOrientation) -> CGFloat {
        switch node {
        case .panel(let kind):
            let size = minSize(for: kind)
            return orientation == .horizontal ? size.width : size.height
        case .split(let splitOrientation, _, let leading, let trailing):
            let a = minLength(of: leading, along: orientation)
            let b = minLength(of: trailing, along: orientation)
            return splitOrientation == orientation ? a + b + dividerThickness : max(a, b)
        }
    }

    private static func axisLength(of rect: CGRect, along orientation: SZPanelSplitOrientation) -> CGFloat {
        orientation == .horizontal ? rect.width : rect.height
    }

    /// Single recursive pass emitting every leaf rect and divider.
    private static func walk(_ node: SZPanelLayoutNode, in rect: CGRect, path: SZPanelNodePath = [],
                             onLeaf: (SZPanelKind, CGRect) -> Void,
                             onDivider: (SZPanelDividerFrame) -> Void) {
        switch node {
        case .panel(let kind):
            onLeaf(kind, rect)
        case .split(let orientation, let fraction, let leading, let trailing):
            let available = max(axisLength(of: rect, along: orientation) - dividerThickness, 0)
            let leadingMin = minLength(of: leading, along: orientation)
            let trailingMin = minLength(of: trailing, along: orientation)
            var leadingLength = available * CGFloat(fraction)
            if leadingMin + trailingMin <= available {
                // Room for both minimums: the fraction rules, min-clamped from both sides.
                leadingLength = min(max(leadingLength, leadingMin), available - trailingMin)
            } else if leadingMin + trailingMin > 0 {
                // Window too small for the minimums: degrade proportionally to them.
                leadingLength = available * leadingMin / (leadingMin + trailingMin)
            }

            let leadingRect: CGRect, dividerRect: CGRect, trailingRect: CGRect
            if orientation == .horizontal {
                leadingRect = CGRect(x: rect.minX, y: rect.minY, width: leadingLength, height: rect.height)
                dividerRect = CGRect(x: leadingRect.maxX, y: rect.minY,
                                     width: min(dividerThickness, max(rect.width - leadingLength, 0)), height: rect.height)
                trailingRect = CGRect(x: dividerRect.maxX, y: rect.minY,
                                      width: max(rect.maxX - dividerRect.maxX, 0), height: rect.height)
            } else {
                leadingRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: leadingLength)
                dividerRect = CGRect(x: rect.minX, y: leadingRect.maxY,
                                     width: rect.width, height: min(dividerThickness, max(rect.height - leadingLength, 0)))
                trailingRect = CGRect(x: rect.minX, y: dividerRect.maxY,
                                      width: rect.width, height: max(rect.maxY - dividerRect.maxY, 0))
            }
            onDivider(SZPanelDividerFrame(path: path, orientation: orientation, rect: dividerRect, splitRect: rect))
            walk(leading, in: leadingRect, path: path + [.leading], onLeaf: onLeaf, onDivider: onDivider)
            walk(trailing, in: trailingRect, path: path + [.trailing], onLeaf: onLeaf, onDivider: onDivider)
        }
    }
}
