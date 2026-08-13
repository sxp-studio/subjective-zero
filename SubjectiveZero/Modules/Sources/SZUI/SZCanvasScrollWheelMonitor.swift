// SPDX-License-Identifier: AGPL-3.0-only
// Trackpad/mouse scroll → canvas pan (and ⌘+scroll → zoom).
// SwiftUI has no scroll-wheel gesture, so this is an NSEvent LOCAL monitor behind an
// NSViewRepresentable background whose frame equals the canvas coordinate space — the
// SZCanvasRightClickCatcher pattern, and the only other AppKit/`NSEvent` bit of the canvas
// (pinch-zoom is a SwiftUI gesture in the panel).
//
// THE FRAME IS THE ROUTING. Every open canvas installs its own monitor and each sees every scroll
// in the app, so something has to decide which canvas a scroll was meant for. That decision is the
// event's own location, hit-tested against this view's bounds at event time — stateless, and true
// whatever the panel is doing. It must NOT be derived from SwiftUI hover: a two-finger scroll does
// not move the pointer, so a canvas whose `.onContinuousHover` had gone stale (the HUD taking
// hover, the window deactivating, a neighbour panel opening under a still cursor) would never pan
// again until the mouse was physically moved.
import AppKit
import SwiftUI

struct SZScrollWheelData {
    var deltaX: CGFloat
    var deltaY: CGFloat
    var commandHeld: Bool
    /// Where the scroll landed, in canvas space (top-left origin, like "szcanvas") — always inside
    /// the canvas, and the pivot ⌘-scroll zooms toward.
    var location: CGPoint
}

struct SZCanvasScrollWheelCatcher: NSViewRepresentable {
    var onScroll: (SZScrollWheelData) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((SZScrollWheelData) -> Void)?
        private var monitor: Any?

        // Top-left origin, like the SwiftUI canvas space — converted points are directly usable.
        override var isFlipped: Bool { true }

        /// The routing rule. An unmeasured canvas (zero-size frame, e.g. a panel mid-layout) takes
        /// nothing rather than claiming the origin.
        nonisolated static func accepts(point: CGPoint, in bounds: CGRect) -> Bool {
            !bounds.isEmpty && bounds.contains(point)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window == nil ? removeMonitor() : installMonitor()
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard Self.accepts(point: point, in: self.bounds) else { return event }
                self.onScroll?(SZScrollWheelData(
                    deltaX: event.scrollingDeltaX,
                    deltaY: event.scrollingDeltaY,
                    commandHeld: event.modifierFlags.contains(.command),
                    location: point))
                // Observed, never swallowed: a scroll over a prompt field still scrolls the field
                // (the panel's own guard keeps the canvas still while one is being edited).
                return event
            }
        }

        // Teardown rides window membership (viewDidMoveToWindow → nil window), not the SwiftUI
        // lifecycle: an out-of-order onAppear/onDisappear pair used to leave a live panel with no
        // monitor at all, deaf to scroll with every other gesture intact.
        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

extension View {
    func monitorCanvasScrollWheel(onScroll: @escaping (SZScrollWheelData) -> Void) -> some View {
        background(SZCanvasScrollWheelCatcher(onScroll: onScroll))
    }
}
