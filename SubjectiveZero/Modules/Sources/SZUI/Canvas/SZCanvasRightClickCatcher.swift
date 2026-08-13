// SPDX-License-Identifier: AGPL-3.0-only
// Right-click capture for the canvas — an NSViewRepresentable background whose NSView frame equals
// the "szcanvas" space (so event locations convert directly to panel coordinates; the hover-sampled
// `cursor` is stale/nil over the HUD and after focus changes) plus an NSEvent LOCAL monitor (the
// SZScrollWheelMonitorManager precedent — SwiftUI has no right-click gesture, and an NSView
// underlay can't reliably see clicks through NSHostingView hit-testing).
//
// EVERY mouse-down in the window routes through `onMouseDown` with a panel-space point and a
// secondary flag (right-click / ctrl-click / two-finger tap — the OS maps the latter to
// rightMouseDown). Returning true swallows the event (a handled secondary click must not fall into
// AppKit's residual menu machinery or the SwiftUI tap underneath); false passes it through. Points
// OUTSIDE the canvas bounds are still reported (with `inCanvas: false`) so an open menu can
// dismiss on any click-away, wherever it lands.
import AppKit
import SwiftUI

struct SZCanvasRightClickCatcher: NSViewRepresentable {
    var onMouseDown: (_ point: CGPoint, _ isSecondary: Bool, _ inCanvas: Bool) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onMouseDown = onMouseDown
    }

    final class CatcherView: NSView {
        var onMouseDown: ((CGPoint, Bool, Bool) -> Bool)?
        private var monitor: Any?

        // Top-left origin, like the SwiftUI "szcanvas" space — converted points are directly usable.
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window == nil ? removeMonitor() : installMonitor()
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            // ONLY secondary clicks open the menu — a left double-click is add-a-node (a SwiftUI
            // gesture on the canvas background), deliberately NOT routed here, so double-clicking
            // the HUD / a text field / the menu itself can't be hijacked by the monitor.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) {
                [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let isSecondary = event.type == .rightMouseDown
                    || event.modifierFlags.contains(.control)
                let point = self.convert(event.locationInWindow, from: nil)
                let inCanvas = self.bounds.contains(point)
                let swallow = self.onMouseDown?(point, isSecondary, inCanvas) ?? false
                return swallow ? nil : event
            }
        }

        // Teardown rides window membership (viewDidMoveToWindow → nil window), not deinit — a
        // nonisolated deinit can't touch the monitor under strict concurrency, and leaving the
        // window is the only real teardown path for a representable's view.
        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
