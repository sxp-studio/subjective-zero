// SPDX-License-Identifier: AGPL-3.0-only
// Which viewport instance DRIVES the frame schedule. With cloned viewports (and popped-out viewport
// windows), exactly one instance may call SZRuntime.drawLive — it advances the timeline, owns
// renderSize, and therefore sets the RESOLUTION the graph renders at — while every other visible
// instance mirrors via presentCurrentFrame. The runtime stays viewport-agnostic; this registry is
// the host-side arbiter the per-instance render closures consult AT CALL TIME (a viewport's render
// loop captures its closure immutably for the attach's lifetime, so drivership must be a read
// inside the closure, not a re-vend).
//
// THE DRIVERSHIP LADDER — fullscreen pop-outs > windowed pop-outs > the primary tile:
// pop a viewport out and fullscreen it on a projector and the graph renders natively THERE, while
// the mac-display tiles show a crisp downscale — never the reverse (a projector upscaling a small
// tile's pixels). Fullscreen outranks windowed REGARDLESS of area: an accidentally-enlarged
// floating preview window must never steal native resolution from the stage output. With no
// pop-outs, the LOWEST-instance tile (the primary) drives — tiles never compete by area, so
// docking a window back restores the pre-clone behavior, no divider drag can reshape the frame,
// and a wide sliver of a tile can never letterbox every other viewport into a thin band. Windows
// report their drawable area as they render; within a rung of the ladder, a challenger takes over
// only when it beats the incumbent by a margin (hysteresis, so live-resizing near-equal windows
// doesn't flap drivership every frame).
//
// Written on the main thread (visibility) and on render threads (area reports); a single `driver`
// value behind one Mutex means at most one instance can ever satisfy `isDriver` for any read — two
// callers can never both advance the timeline, by construction. During a handoff there's at most a
// sub-frame gap where nobody advances (mirrors keep re-presenting the held endpoint).
import Synchronization

final class SZViewportDriverRegistry: Sendable {
    private struct State {
        /// Viewport instances living as main-window tiles.
        var tiles: Set<Int> = []
        /// Viewport instances living in pop-out windows (displayable ones only).
        var windows: Set<Int> = []
        /// The subset of `windows` currently in native fullscreen (the top of the ladder).
        var fullscreen: Set<Int> = []
        /// Last-reported drawable pixel area per instance (0 until a viewport first renders).
        var areas: [Int: Int] = [:]
        var driver: Int?
    }

    private let state = Mutex<State>(State())

    /// A challenger window must beat the incumbent window's area by this factor to take
    /// drivership — a genuine "bigger window" wins immediately, near-equal ones never flap.
    private static let takeoverFactor = 1.15

    /// Read per frame on the caller's render thread, reporting the caller's current drawable
    /// area — the report is what lets drivership follow the largest window through live resizes.
    func isDriver(_ instance: Int, reportingArea area: Int) -> Bool {
        state.withLock { s in
            if s.areas[instance] != area {
                s.areas[instance] = area
                Self.recompute(&s)
            }
            return s.driver == instance
        }
    }

    /// Push the currently-visible viewport instances, split by where they live (`fullscreen` ⊆
    /// `windows`). All empty → no driver, everything idles (matches the closed-viewport behavior).
    func setVisible(tiles: Set<Int>, windows: Set<Int>, fullscreen: Set<Int> = []) {
        state.withLock { s in
            s.tiles = tiles
            s.windows = windows
            s.fullscreen = fullscreen.intersection(windows)
            let visible = tiles.union(windows)
            s.areas = s.areas.filter { visible.contains($0.key) }
            Self.recompute(&s)
        }
    }

    private static func recompute(_ s: inout State) {
        // No pop-outs: the primary-most tile drives, unconditionally — no area contest.
        guard !s.windows.isEmpty else {
            s.driver = s.tiles.min()
            return
        }
        // The ladder rung that competes: fullscreen windows if any exist, else all windows.
        // Largest area wins within the rung (lowest instance breaks ties), with hysteresis.
        let rung = s.fullscreen.isEmpty ? s.windows : s.fullscreen
        let candidate = rung.min { a, b in
            let (areaA, areaB) = (s.areas[a] ?? 0, s.areas[b] ?? 0)
            return areaA == areaB ? a < b : areaA > areaB
        }
        guard let incumbent = s.driver, rung.contains(incumbent) else {
            s.driver = candidate
            return
        }
        guard let candidate, candidate != incumbent else { return }
        if Double(s.areas[candidate] ?? 0) > Double(s.areas[incumbent] ?? 0) * takeoverFactor {
            s.driver = candidate
        }
    }
}
