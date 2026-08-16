// SPDX-License-Identifier: AGPL-3.0-only
// The viewport driver arbiter: pop-out windows outrank tiles (largest window drives — the
// projector case), no pop-outs means the primary-most tile drives unconditionally (tiles never
// compete by area — a wide sliver tile must not letterbox every other viewport), and window
// handoffs use hysteresis so near-equal windows never flap. Pure host-side state — no windows;
// areas arrive as events (attach / resize reports), drivership is a plain read.
import Testing
@testable import SubjectiveZero

@MainActor
struct SZViewportDriverRegistryTests {

    @Test func tilesOnlyMeansThePrimaryDrivesRegardlessOfArea() {
        let registry = SZViewportDriverRegistry()
        registry.setVisible(tiles: [0, 1, 2], windows: [])
        // A huge clone tile never outranks the primary — tiles don't compete by area.
        registry.reportArea(2, 5_000_000)
        registry.reportArea(0, 100_000)
        registry.reportArea(1, 2_000_000)
        #expect(registry.driver == 0)
    }

    @Test func aPopoutWindowOutranksEveryTile() {
        let registry = SZViewportDriverRegistry()
        registry.setVisible(tiles: [0, 1], windows: [2])
        // Even a SMALL pop-out drives over big tiles — a window is a deliberate display surface.
        registry.reportArea(2, 200_000)
        registry.reportArea(0, 2_000_000)
        registry.reportArea(1, 1_000_000)
        #expect(registry.driver == 2)
    }

    @Test func dockingTheLastWindowHandsBackToThePrimaryTile() {
        // The reported bug: dock the pop-out → drivership must return to the primary tile, not to
        // whichever tile happens to be largest (a wide strip tile letterboxing everything).
        let registry = SZViewportDriverRegistry()
        registry.setVisible(tiles: [0, 1], windows: [2])
        registry.reportArea(2, 3_000_000)
        registry.reportArea(0, 400_000)
        #expect(registry.driver == 2)
        registry.setVisible(tiles: [0, 1, 2], windows: [])   // viewport 3 docked as a (wide) tile
        #expect(registry.driver == 0)
    }

    @Test func largestWindowDrivesAmongSeveralWithHysteresis() {
        let registry = SZViewportDriverRegistry()
        registry.setVisible(tiles: [0], windows: [1, 2])
        registry.reportArea(1, 1_000_000)
        #expect(registry.driver == 1)
        // A slightly bigger challenger window does NOT flip (within the ~15% margin)…
        registry.reportArea(2, 1_100_000)
        #expect(registry.driver == 1)
        // …a decisively bigger one does — fullscreen on the projector takes over.
        registry.reportArea(2, 2_000_000)
        #expect(registry.driver == 2)
    }

    @Test func equalWindowsNeverFlap() {
        let registry = SZViewportDriverRegistry()
        registry.setVisible(tiles: [], windows: [1, 2])
        registry.reportArea(1, 500_000)
        #expect(registry.driver == 1)
        for delta in [0, 1, -1, 2, -2] {   // live-resize jitter around equal
            registry.reportArea(2, 500_000 + delta)
            #expect(registry.driver == 1)
        }
    }

    @Test func miniaturizedDriverWindowIsDemotedImmediately() {
        let registry = SZViewportDriverRegistry()
        registry.setVisible(tiles: [0], windows: [1])
        registry.reportArea(1, 2_000_000)
        registry.reportArea(0, 100)
        #expect(registry.driver == 1)
        // The driving window miniaturizes (drops out of the window set): the tile takes over.
        registry.setVisible(tiles: [0], windows: [])
        #expect(registry.driver == 0)
    }

    @Test func emptySetsMeanNoDriver() {
        let registry = SZViewportDriverRegistry()
        registry.setVisible(tiles: [0], windows: [])
        registry.reportArea(0, 100)
        #expect(registry.driver == 0)
        registry.setVisible(tiles: [], windows: [])
        #expect(registry.driver == nil)
    }

    @Test func aFullscreenWindowOutranksALargerFloatingWindow() {
        // The stage-safety rung: an accidentally-enlarged floating preview window must never steal
        // native resolution from the fullscreen projector output, whatever their areas say.
        let registry = SZViewportDriverRegistry()
        registry.setVisible(tiles: [0], windows: [1, 2], fullscreen: [2])
        registry.reportArea(2, 2_073_600)   // 1080p projector
        registry.reportArea(1, 6_000_000)   // huge floating window — still a mirror
        #expect(registry.driver == 2)
        // Exiting fullscreen returns that window to plain area competition — the bigger one wins now.
        registry.setVisible(tiles: [0], windows: [1, 2], fullscreen: [])
        #expect(registry.driver == 1)
    }

    @Test func fullscreenSetIsClampedToTheWindowSet() {
        // A stale fullscreen entry for a window that just closed must not strand drivership.
        let registry = SZViewportDriverRegistry()
        registry.setVisible(tiles: [0], windows: [1], fullscreen: [2])   // 2 isn't a window
        registry.reportArea(1, 500_000)
        #expect(registry.driver == 1)
    }

    @Test func shrinkingTheDrivingWindowHandsOffToTheNowLargest() {
        // The driver window's own report shrinks (resized small): a decisively larger sibling window
        // takes over in the very same recompute.
        let registry = SZViewportDriverRegistry()
        registry.setVisible(tiles: [], windows: [1, 2])
        registry.reportArea(1, 2_000_000)
        registry.reportArea(2, 1_000_000)   // sibling reports, stays a mirror
        #expect(registry.driver == 1)
        registry.reportArea(1, 400_000)     // shrank below 1M/1.15 → demoted
        #expect(registry.driver == 2)
    }

    @Test func areasReportedBeforeVisibilityAreKept() {
        // Attach reports area before the visibility sync lands (the host's attach path): the
        // report must survive into the first recompute that lists the instance.
        let registry = SZViewportDriverRegistry()
        registry.reportArea(2, 2_000_000)
        registry.reportArea(1, 500_000)
        registry.setVisible(tiles: [], windows: [1, 2])
        #expect(registry.driver == 2)
    }
}
