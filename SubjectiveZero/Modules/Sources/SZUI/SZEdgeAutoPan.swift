// SPDX-License-Identifier: AGPL-3.0-only
// Edge auto-pan while dragging, ported from the shipping editor's SBEdgeAutoPan: dragging a node or
// a wire within `zone` pt of the viewport edge pans the camera so offscreen nodes can be reached.
// The math is a pure namespace (headless-testable); the driver is a dumb 60fps metronome that emits
// screen-space pan deltas — the panel applies them to `canvasOffset` and re-derives the in-flight
// drag's world position. Speeds are SCREEN-space so the pan feels identical at every zoom level.
import CoreGraphics
import Foundation
import QuartzCore

enum SZEdgeAutoPan {
    static let zone: CGFloat = 60        // edge margin where panning begins, screen pt
    static let minSpeed: CGFloat = 50    // pt/s on entering the zone
    static let maxSpeed: CGFloat = 400   // pt/s at (or past) the edge

    /// Per-edge pan strength, 0…1. Doubles as the visual indicator's input.
    struct Intensities: Equatable {
        var left: CGFloat = 0, right: CGFloat = 0, top: CGFloat = 0, bottom: CGFloat = 0
        var isActive: Bool { left > 0 || right > 0 || top > 0 || bottom > 0 }
    }

    /// Quadratic ramp: 0 at `zone` pt from the edge, 1 at the edge. A cursor dragged PAST the edge
    /// (negative distance) saturates at 1 — exactly what you want when the drag leaves the panel.
    static func intensities(cursor: CGPoint, in size: CGSize) -> Intensities {
        guard size.width > 0, size.height > 0 else { return Intensities() }
        func ramp(_ distance: CGFloat) -> CGFloat {
            let clamped = min(max(distance, 0), zone)
            let raw = 1 - clamped / zone
            return raw * raw
        }
        return Intensities(left: ramp(cursor.x),
                           right: ramp(size.width - cursor.x),
                           top: ramp(cursor.y),
                           bottom: ramp(size.height - cursor.y))
    }

    /// Screen-space camera velocity (pt/s) to ADD to `canvasOffset`. Revealing content to the right
    /// means the offset shrinks, so the right edge contributes negatively; opposing edges cancel.
    static func velocity(cursor: CGPoint, in size: CGSize) -> CGSize {
        let i = intensities(cursor: cursor, in: size)
        func speed(_ intensity: CGFloat) -> CGFloat {
            intensity == 0 ? 0 : minSpeed + (maxSpeed - minSpeed) * intensity
        }
        return CGSize(width: speed(i.left) - speed(i.right),
                      height: speed(i.top) - speed(i.bottom))
    }
}

/// Drives the pan while a drag sits in the edge zone: a 60fps timer that scales the current velocity
/// by measured elapsed time and hands the panel a screen-space delta. Runs only while the velocity is
/// nonzero — idle costs nothing. Not observable on purpose: each tick mutates the panel's own @State,
/// which is what invalidates the view.
@MainActor
final class SZEdgeAutoPanDriver {
    var onTick: ((CGSize) -> Void)?
    private(set) var velocity: CGSize = .zero
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0

    /// Recompute the velocity for the cursor's edge proximity; lazily start/stop the timer.
    func update(cursor: CGPoint, in size: CGSize) {
        velocity = SZEdgeAutoPan.velocity(cursor: cursor, in: size)
        if velocity == .zero {
            stopTimer()
        } else if timer == nil {
            lastTick = CACurrentMediaTime()
            // .common mode is required: the main run loop sits in event-tracking mode while a drag
            // is held, and default-mode timers stall there.
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                MainActor.assumeIsolated { self.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func stop() {
        velocity = .zero
        stopTimer()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.1)   // clamp huge gaps (app hidden, debugger) to avoid jumps
        lastTick = now
        onTick?(CGSize(width: velocity.width * dt, height: velocity.height * dt))
    }
}
