// SPDX-License-Identifier: AGPL-3.0-only
// The rearrangeable panel container — renders the SZCore split tree as a FLAT ZStack of absolutely
// positioned tiles, NOT nested split views. Flatness is the point: each panel's SwiftUI identity is
// its SZPanelKind (stable ForEach id), so re-parenting a panel in the tree just moves a rect — the
// viewport's MTKView is never torn down and the node editor's zoom/pan and the chat draft survive
// any rearrangement. Dividers draw on top and drag to resize.
//
// State-derived like every SZUI panel: takes the layout VALUE plus intent callbacks; the host owns
// the state (docs/UI.md). Geometry comes from SZPanelLayoutGeometry — this file only renders it.
import SwiftUI
import SZCore

/// The container's named coordinate space — header drags and divider drags both speak it.
/// (A standalone constant: the container view is generic, so a static on it is awkward to name.)
let szPanelGridSpaceName = "szpanelgrid"

public struct SZPanelLayoutContainerView<Content: View>: View {
    private let layout: SZPanelLayoutState
    /// Where the window's traffic lights float (container coordinates) — SZApp passes it when the
    /// window runs with a hidden titlebar. A tile whose header falls under it indents its header
    /// content so the lights read as sitting inline with that header.
    private let windowControlsZone: CGRect?
    /// Margin above the tiles — defaults to the uniform outer gap; SZApp passes 0 with the hidden
    /// titlebar so the top row's header IS the titlebar row (lights vertically centered in it).
    private let topInset: CGFloat
    /// View ▸ Auto-Hide Panel Headers — passed through to every tile's chrome.
    private let autoHideHeaders: Bool
    /// View ▸ Rounded Viewport Corners — passed to every tile's chrome; only the viewport tile
    /// honors it (squares its corners when off), so other tiles stay rounded regardless.
    private let viewportRoundedCorners: Bool
    /// The panel blown up to fill the window (others hidden), if any — a render override on top of
    /// the split tree, so restore returns the exact prior layout. Ignored if the named panel isn't present.
    private let maximizedPanel: SZPanelKind?
    private let onDividerFractionChange: (SZPanelNodePath, Double) -> Void
    private let onDividerDragEnd: (SZPanelNodePath, Double) -> Void
    private let onMovePanel: (SZPanelKind, SZPanelKind, SZPanelDropZone) -> Void
    private let onClosePanel: (SZPanelKind) -> Void
    private let onToggleMaximize: (SZPanelKind) -> Void
    private let content: (SZPanelKind) -> Content

    /// A header drag in flight: the lifted panel and the cursor (grid space). Drives the dimming,
    /// the cursor ghost, and the drop-preview overlay.
    @State private var panelDrag: (kind: SZPanelKind, location: CGPoint)?

    public init(layout: SZPanelLayoutState,
                windowControlsZone: CGRect? = nil,
                topInset: CGFloat = SZPanelLayoutGeometry.outerGap,
                autoHideHeaders: Bool = false,
                viewportRoundedCorners: Bool = true,
                maximizedPanel: SZPanelKind? = nil,
                onDividerFractionChange: @escaping (SZPanelNodePath, Double) -> Void,
                onDividerDragEnd: @escaping (SZPanelNodePath, Double) -> Void,
                onMovePanel: @escaping (SZPanelKind, SZPanelKind, SZPanelDropZone) -> Void,
                onClosePanel: @escaping (SZPanelKind) -> Void,
                onToggleMaximize: @escaping (SZPanelKind) -> Void = { _ in },
                @ViewBuilder content: @escaping (SZPanelKind) -> Content) {
        self.layout = layout
        self.windowControlsZone = windowControlsZone
        self.topInset = topInset
        self.autoHideHeaders = autoHideHeaders
        self.viewportRoundedCorners = viewportRoundedCorners
        self.maximizedPanel = maximizedPanel
        self.onDividerFractionChange = onDividerFractionChange
        self.onDividerDragEnd = onDividerDragEnd
        self.onMovePanel = onMovePanel
        self.onClosePanel = onClosePanel
        self.onToggleMaximize = onToggleMaximize
        self.content = content
    }

    public var body: some View {
        GeometryReader { proxy in
            let gap = SZPanelLayoutGeometry.outerGap
            let rect = CGRect(x: gap, y: topInset, width: max(proxy.size.width - gap * 2, 0),
                              height: max(proxy.size.height - topInset - gap, 0))
            // Maximize is a render override, not a tree edit: give the maximized panel the whole rect
            // and drop the others + dividers (kinds below filters to whatever has a frame). Ignored if
            // the named panel isn't actually present.
            let isMax = maximizedPanel.map(layout.contains) ?? false
            let frames = isMax ? [maximizedPanel!: rect]
                               : SZPanelLayoutGeometry.leafFrames(root: layout.root, in: rect)
            let dividers = isMax ? [] : SZPanelLayoutGeometry.dividerFrames(root: layout.root, in: rect)
            // allCases order (not tree order) so the ForEach data stays stable across rearrangements —
            // identity is the kind, the tree only decides the rects.
            let kinds = SZPanelKind.allCases.filter { frames[$0] != nil }

            ZStack(alignment: .topLeading) {
                // Backdrop: window background + window-drag from any gap/margin (holes punched over
                // every tile and divider so it never steals their mouse).
                SZPanelWindowDragBackdrop(
                    passthroughRects: Array(frames.values) + dividers.map(\.rect))
                ForEach(kinds, id: \.self) { kind in
                    let frame = frames[kind]!
                    SZPanelChromeView(kind: kind, canClose: kinds.count > 1,
                                      canMaximize: layout.presentKinds.count > 1,
                                      isMaximized: maximizedPanel == kind,
                                      autoHideEnabled: autoHideHeaders,
                                      viewportRoundedCorners: viewportRoundedCorners,
                                      headerLeadingInset: headerLeadingInset(for: frame),
                                      onClose: { onClosePanel(kind) },
                                      onToggleMaximize: { onToggleMaximize(kind) },
                                      onHeaderDragChanged: { panelDrag = (kind, $0) },
                                      onHeaderDragEnded: { endPanelDrag(kind, at: $0, frames: frames) }) {
                        content(kind)
                    }
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .opacity(panelDrag?.kind == kind ? 0.45 : 1)   // the lifted panel dims (tab-drag idiom)
                }
                ForEach(dividers, id: \.path) { divider in
                    let strip = SZPanelDividerView(divider: divider,
                                                   onFractionChange: { onDividerFractionChange(divider.path, $0) },
                                                   onDragEnd: { onDividerDragEnd(divider.path, $0) })
                    strip
                        .frame(width: strip.grabRect.width, height: strip.grabRect.height)
                        .position(x: strip.grabRect.midX, y: strip.grabRect.midY)
                }
                dropPreviewOverlay(frames: frames)
                dragGhost
            }
            // Animate structural changes (drop/close/reopen) only — leafKinds ignores fractions, so
            // live divider drags track the cursor instead of chasing it through an animation.
            .animation(.easeInOut(duration: 0.18), value: layout.root.leafKinds)
            // Maximize/restore grows or shrinks the tile(s) — animate on the maximized panel so the
            // real content resizes smoothly into / out of the full window.
            .animation(.easeInOut(duration: 0.2), value: maximizedPanel)
            .animation(.easeOut(duration: 0.12), value: dropCandidate(frames: frames)?.preview)
            .coordinateSpace(name: szPanelGridSpaceName)
        }
    }

    /// Indent a tile's header content when the window's traffic lights float over it, so the
    /// lights read as part of that header instead of covering its name.
    private func headerLeadingInset(for frame: CGRect) -> CGFloat {
        guard let zone = windowControlsZone, frame.intersects(zone) else { return 0 }
        return max(0, zone.maxX - frame.minX)
    }

    // MARK: - Header drag & drop

    /// The panel + zone under the cursor mid-drag (excluding the dragged panel itself), with the
    /// tinted preview rect. Leaf rects never overlap, so at most one panel contains the cursor.
    private func dropCandidate(frames: [SZPanelKind: CGRect])
        -> (target: SZPanelKind, zone: SZPanelDropZone, preview: CGRect)? {
        guard let drag = panelDrag,
              let (target, rect) = frames.first(where: { $0.key != drag.kind && $0.value.contains(drag.location) })
        else { return nil }
        let zone = SZPanelLayoutGeometry.dropZone(at: drag.location, in: rect)
        return (target, zone, SZPanelLayoutGeometry.dropPreviewRect(zone: zone, in: rect))
    }

    /// Commit (or cancel) a header drag: over another panel → move; anywhere else → no-op.
    private func endPanelDrag(_ kind: SZPanelKind, at location: CGPoint, frames: [SZPanelKind: CGRect]) {
        defer { panelDrag = nil }
        panelDrag = (kind, location)
        guard let hit = dropCandidate(frames: frames) else { return }
        onMovePanel(kind, hit.target, hit.zone)
    }

    /// The overlay explaining the pending change: the half of the target the dragged panel would
    /// take (or the whole target for a swap), tinted + dashed, with a capsule label spelling it out.
    @ViewBuilder
    private func dropPreviewOverlay(frames: [SZPanelKind: CGRect]) -> some View {
        if let drag = panelDrag, let hit = dropCandidate(frames: frames) {
            RoundedRectangle(cornerRadius: SZPanelLayoutGeometry.tileCornerRadius, style: .continuous)
                .fill(Self.accent.opacity(0.10))
                .strokeBorder(Self.accent.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .overlay {
                    Text(Self.previewLabel(dragged: drag.kind, target: hit.target, zone: hit.zone))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Self.accent)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .frame(width: hit.preview.width, height: hit.preview.height)
                .position(x: hit.preview.midX, y: hit.preview.midY)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// A small capsule with the panel's name riding just above the cursor while its header is dragged.
    @ViewBuilder
    private var dragGhost: some View {
        if let drag = panelDrag {
            HStack(spacing: 5) {
                Image(systemName: "rectangle.dashed")
                Text(drag.kind.displayName)
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.75))
            .position(x: drag.location.x, y: drag.location.y - 18)
            .allowsHitTesting(false)
        }
    }

    private static var accent: Color { Color(red: 0.26, green: 0.59, blue: 1.0) }   // the app's insertion blue

    private static func previewLabel(dragged: SZPanelKind, target: SZPanelKind, zone: SZPanelDropZone) -> String {
        switch zone {
        case .center: "Swap \(target.displayName) ↔ \(dragged.displayName)"
        case .left: "Split left — \(dragged.displayName) here"
        case .right: "Split right — \(dragged.displayName) here"
        case .top: "Split top — \(dragged.displayName) here"
        case .bottom: "Split bottom — \(dragged.displayName) here"
        }
    }
}

/// One divider strip: a full AppKit view owning its hit area, drag, and cursor rect. This is the
/// third cursor implementation and the one that CAN'T flicker: with a SwiftUI gesture view the
/// window's cursor updates route to NSHostingView (arrow) while a tracking area asserts resize —
/// they alternate per event. As the genuine hit-test owner, this view's `addCursorRect` is the only
/// cursor authority over the strip, and the drag maps straight to the fraction callbacks. The
/// grab/cursor area extends `grabPadding` past the visible gap into each neighbor (NSSplitView
/// style): easier to hit, at the cost of a few invisible points of panel edge.
private struct SZPanelDividerView: NSViewRepresentable {
    let divider: SZPanelLayoutGeometry.SZPanelDividerFrame
    let onFractionChange: (Double) -> Void
    let onDragEnd: (Double) -> Void

    static var grabPadding: CGFloat { 3 }

    /// The widened strip this view occupies, in container coordinates.
    var grabRect: CGRect {
        divider.rect.insetBy(
            dx: divider.orientation == .horizontal ? -Self.grabPadding : 0,
            dy: divider.orientation == .vertical ? -Self.grabPadding : 0)
    }

    final class SZDividerNSView: NSView {
        var orientation: SZPanelSplitOrientation = .horizontal
        var splitRect: CGRect = .zero
        var originInContainer: CGPoint = .zero
        var onFractionChange: ((Double) -> Void)?
        var onDragEnd: ((Double) -> Void)?

        override var isFlipped: Bool { true }   // match the container's top-left-origin coordinates

        private var cursor: NSCursor {
            orientation == .horizontal ? .resizeLeftRight : .resizeUpDown
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        // Passive cursor rects alone still lose to NSHostingView's tracking machinery on hover (the
        // drag worked only because mouseDragged sets the cursor explicitly). So: own tracking area,
        // re-assert on enter AND every move. Unlike the earlier flicker, this now converges — the
        // window routes cursorUpdate to the hit-test owner, which is this view.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            // .activeAlways, not .activeInKeyWindow: native resize cursors show on non-key windows
            // too — with the key-window option, hovering right after a relaunch (window not yet
            // clicked) showed nothing and read as "hover broke again".
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect],
                owner: self, userInfo: nil))
        }

        override func cursorUpdate(with event: NSEvent) { cursor.set() }
        override func mouseEntered(with event: NSEvent) { cursor.set() }
        override func mouseMoved(with event: NSEvent) { cursor.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

        override func mouseDragged(with event: NSEvent) {
            cursor.set()   // cursor rects aren't re-evaluated mid-drag; hold it explicitly
            onFractionChange?(fraction(for: event))
        }

        override func mouseUp(with event: NSEvent) {
            onDragEnd?(fraction(for: event))
        }

        private func fraction(for event: NSEvent) -> Double {
            let local = convert(event.locationInWindow, from: nil)
            let container = CGPoint(x: originInContainer.x + local.x, y: originInContainer.y + local.y)
            return SZPanelLayoutGeometry.fraction(forDividerAt: container, orientation: orientation,
                                                  in: splitRect)
        }
    }

    func makeNSView(context: Context) -> SZDividerNSView { SZDividerNSView() }

    func updateNSView(_ nsView: SZDividerNSView, context: Context) {
        nsView.orientation = divider.orientation
        nsView.splitRect = divider.splitRect
        nsView.originInContainer = grabRect.origin
        nsView.onFractionChange = onFractionChange
        nsView.onDragEnd = onDragEnd
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

/// The container's backdrop: paints the near-black window background AND drags the window when
/// grabbed — but ONLY where no tile or divider sits (`passthroughRects` punch holes in its hit
/// area), so the gaps/margins around the tiles become the window's drag handle without stealing a
/// single click from panel content or divider gestures. This replaces both the plain background
/// Color and any titlebar-wide drag strip.
struct SZPanelWindowDragBackdrop: NSViewRepresentable {
    var passthroughRects: [CGRect]

    final class SZBackdropView: NSView {
        var passthroughRects: [CGRect] = []

        override var isFlipped: Bool { true }   // match SwiftUI's top-left-origin rects
        override var mouseDownCanMoveWindow: Bool { false }   // performDrag owns it

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = superview.map { convert(point, from: $0) } ?? point
            return passthroughRects.contains { $0.contains(local) } ? nil : super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> SZBackdropView {
        let view = SZBackdropView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.04, alpha: 1).cgColor
        return view
    }

    func updateNSView(_ nsView: SZBackdropView, context: Context) {
        nsView.passthroughRects = passthroughRects
    }
}
