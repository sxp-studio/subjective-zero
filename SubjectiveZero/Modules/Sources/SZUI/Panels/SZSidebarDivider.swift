// SPDX-License-Identifier: AGPL-3.0-only
// A grab strip inside a panel: drag it to resize, double click to fold. Vertical (the sidebar's own
// edge) or horizontal (the Library panel's list/description split).
//
// AppKit, not a SwiftUI gesture, for the reason the tile dividers next door document at
// length: over an NSHostingView the window's cursor updates and a SwiftUI-side tracking area
// alternate per event, so the resize cursor flickers. As the real hit-test owner, this view's
// cursor rect is the only authority over the strip.
//
// It reports the pointer's travel in points from where the drag began; the caller adds that
// to whatever size it stamped at `onDragBegan` and clamps. No geometry knowledge here — the
// caller owns its own limits. Right is positive on a vertical strip, up is positive on a
// horizontal one, which is the direction that grows the thing below it.
import AppKit
import SwiftUI

struct SZSidebarDivider: NSViewRepresentable {
    /// Which way the strip is dragged: `.vertical` is an upright strip moved left and right (a
    /// sidebar edge), `.horizontal` is a lying strip moved up and down (a stacked split).
    enum Axis { case vertical, horizontal }

    var axis: Axis = .vertical
    /// The mouse went down: stamp the size this drag measures from.
    let onDragBegan: () -> Void
    /// Pointer travel, in points, since that mouse-down. Right is positive.
    let onDrag: (CGFloat) -> Void
    /// A double click on the strip — the fold gesture, and never fired after a drag.
    let onDoubleClick: () -> Void

    final class SZDividerStrip: NSView {
        var axis: Axis = .vertical
        var onDragBegan: (() -> Void)?
        var onDrag: ((CGFloat) -> Void)?
        var onDoubleClick: (() -> Void)?

        private var cursor: NSCursor { axis == .vertical ? .resizeLeftRight : .resizeUpDown }
        private var anchor: CGFloat = 0
        /// The pointer actually moved: a drag, not a click. Keeps a resize from firing the
        /// fold, and a fold from committing whatever width the last pixel of jitter implied.
        private var travelled = false

        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

        // The passive cursor rect alone loses to NSHostingView's tracking machinery on hover,
        // so re-assert on enter and on every move (the tile divider's finding, applied here).
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect],
                owner: self, userInfo: nil))
        }

        override func cursorUpdate(with event: NSEvent) { cursor.set() }
        override func mouseEntered(with event: NSEvent) { cursor.set() }
        override func mouseMoved(with event: NSEvent) { cursor.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

        private func position(_ event: NSEvent) -> CGFloat {
            axis == .vertical ? event.locationInWindow.x : event.locationInWindow.y
        }

        override func mouseDown(with event: NSEvent) {
            anchor = position(event)
            travelled = false
            onDragBegan?()
        }

        override func mouseDragged(with event: NSEvent) {
            cursor.set()   // cursor rects aren't re-evaluated mid-drag
            let delta = position(event) - anchor
            guard travelled || abs(delta) > 2 else { return }
            travelled = true
            onDrag?(delta)
        }

        override func mouseUp(with event: NSEvent) {
            guard !travelled, event.clickCount == 2 else { return }
            onDoubleClick?()
        }
    }

    func makeNSView(context: Context) -> SZDividerStrip { SZDividerStrip() }

    /// Folding mid-drag takes the strip out from under the pointer, so its own `mouseExited`
    /// never arrives and the resize cursor would stay on a canvas that has no edge to drag.
    static func dismantleNSView(_ nsView: SZDividerStrip, coordinator: ()) {
        NSCursor.arrow.set()
    }

    func updateNSView(_ nsView: SZDividerStrip, context: Context) {
        nsView.axis = axis
        nsView.onDragBegan = onDragBegan
        nsView.onDrag = onDrag
        nsView.onDoubleClick = onDoubleClick
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}
