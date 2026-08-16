// SPDX-License-Identifier: AGPL-3.0-only
// Which viewport instance DRIVES: it owns renderSize (the graph renders at ITS resolution) and its
// display link paces the loop; every other visible viewport mirrors. Host-side arbiter, main thread,
// re-run on visibility and size edges; SZHost+Viewports pushes the result to the runtime.
//
// The ladder — fullscreen pop-outs > windowed pop-outs > the primary tile: a fullscreen projector
// output renders natively while the mac tiles downscale, regardless of area (an enlarged floating
// window must never steal native resolution from the stage). Within a rung the largest area wins with
// hysteresis (no flapping on live resize). With no pop-outs the lowest-instance tile drives — tiles
// never compete by area, so no divider drag reshapes the frame. No visible viewport → no driver.
import Foundation

@MainActor
final class SZViewportDriverRegistry {
    /// Instances living as main-window tiles (attached, window displayable).
    private var tiles: Set<Int> = []
    /// Instances in displayable pop-out windows.
    private var windows: Set<Int> = []
    /// The subset of `windows` in native fullscreen.
    private var fullscreen: Set<Int> = []
    /// Last-reported drawable pixel area per instance.
    private var areas: [Int: Int] = [:]
    /// nil = no visible viewport.
    private(set) var driver: Int?

    /// A challenger window must beat the incumbent's area by this factor to take over.
    private static let takeoverFactor = 1.15

    /// Drawable pixel area — on attach and on every real drawableSize change.
    func reportArea(_ instance: Int, _ area: Int) {
        guard areas[instance] != area else { return }
        areas[instance] = area
        recompute()
    }

    /// The visible instances by where they live (`fullscreen` ⊆ `windows`). All empty → no driver.
    func setVisible(tiles: Set<Int>, windows: Set<Int>, fullscreen: Set<Int> = []) {
        self.tiles = tiles
        self.windows = windows
        self.fullscreen = fullscreen.intersection(windows)
        let visible = tiles.union(windows)
        areas = areas.filter { visible.contains($0.key) }
        recompute()
    }

    private func recompute() {
        // No pop-outs: the primary tile drives, no area contest.
        guard !windows.isEmpty else {
            driver = tiles.min()
            return
        }
        // The competing rung: fullscreen windows if any, else all windows. Largest area wins
        // (lowest instance breaks ties), with hysteresis.
        let rung = fullscreen.isEmpty ? windows : fullscreen
        let candidate = rung.min { a, b in
            let (areaA, areaB) = (areas[a] ?? 0, areas[b] ?? 0)
            return areaA == areaB ? a < b : areaA > areaB
        }
        guard let incumbent = driver, rung.contains(incumbent) else {
            driver = candidate
            return
        }
        guard let candidate, candidate != incumbent else { return }
        if Double(areas[candidate] ?? 0) > Double(areas[incumbent] ?? 0) * Self.takeoverFactor {
            driver = candidate
        }
    }
}
