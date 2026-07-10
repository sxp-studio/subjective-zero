// SPDX-License-Identifier: AGPL-3.0-only
// Trackpad/mouse scroll → canvas pan (and ⌘+scroll → zoom).
// SwiftUI has no scroll-wheel gesture, so we install an `NSEvent` local
// monitor and forward the deltas to the editor panel. This is the only AppKit/`NSEvent` bit of the
// canvas; pinch-zoom uses a SwiftUI MagnificationGesture in the panel.
import AppKit
import SwiftUI

struct SZScrollWheelData {
    var deltaX: CGFloat
    var deltaY: CGFloat
    var commandHeld: Bool
}

@MainActor
final class SZScrollWheelMonitorManager {
    private var monitor: Any?
    var onScroll: ((SZScrollWheelData) -> Void)?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                self.onScroll?(SZScrollWheelData(
                    deltaX: event.scrollingDeltaX,
                    deltaY: event.scrollingDeltaY,
                    commandHeld: event.modifierFlags.contains(.command)))
            }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

private struct SZCanvasScrollWheelMonitor: ViewModifier {
    let onScroll: (SZScrollWheelData) -> Void
    @State private var manager = SZScrollWheelMonitorManager()

    func body(content: Content) -> some View {
        manager.onScroll = onScroll
        return content
            .onAppear { manager.start() }
            .onDisappear { manager.stop() }
    }
}

extension View {
    func monitorCanvasScrollWheel(onScroll: @escaping (SZScrollWheelData) -> Void) -> some View {
        modifier(SZCanvasScrollWheelMonitor(onScroll: onScroll))
    }
}
