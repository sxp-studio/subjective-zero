// SPDX-License-Identifier: AGPL-3.0-only
// The viewport driver arbiter: pop-out windows outrank tiles (largest window drives — the
// projector case), no pop-outs means the primary-most tile drives unconditionally (tiles never
// compete by area — a wide sliver tile must not letterbox every other viewport), and window
// handoffs use hysteresis so near-equal windows never flap. Pure host-side state — no windows.
import Testing
@testable import SubjectiveZero

@Test func tilesOnlyMeansThePrimaryDrivesRegardlessOfArea() {
    let registry = SZViewportDriverRegistry()
    registry.setVisible(tiles: [0, 1, 2], windows: [])
    // A huge clone tile never outranks the primary — tiles don't compete by area.
    #expect(!registry.isDriver(2, reportingArea: 5_000_000))
    #expect(registry.isDriver(0, reportingArea: 100_000))
    #expect(!registry.isDriver(1, reportingArea: 2_000_000))
}

@Test func aPopoutWindowOutranksEveryTile() {
    let registry = SZViewportDriverRegistry()
    registry.setVisible(tiles: [0, 1], windows: [2])
    // Even a SMALL pop-out drives over big tiles — a window is a deliberate display surface.
    #expect(registry.isDriver(2, reportingArea: 200_000))
    #expect(!registry.isDriver(0, reportingArea: 2_000_000))
    #expect(!registry.isDriver(1, reportingArea: 1_000_000))
}

@Test func dockingTheLastWindowHandsBackToThePrimaryTile() {
    // The reported bug: dock the pop-out → drivership must return to the primary tile, not to
    // whichever tile happens to be largest (a wide strip tile letterboxing everything).
    let registry = SZViewportDriverRegistry()
    registry.setVisible(tiles: [0, 1], windows: [2])
    #expect(registry.isDriver(2, reportingArea: 3_000_000))
    registry.setVisible(tiles: [0, 1, 2], windows: [])   // viewport 3 docked as a (wide) tile
    #expect(!registry.isDriver(2, reportingArea: 3_000_000))
    #expect(registry.isDriver(0, reportingArea: 400_000))
}

@Test func largestWindowDrivesAmongSeveralWithHysteresis() {
    let registry = SZViewportDriverRegistry()
    registry.setVisible(tiles: [0], windows: [1, 2])
    #expect(registry.isDriver(1, reportingArea: 1_000_000))
    // A slightly bigger challenger window does NOT flip (within the ~15% margin)…
    #expect(!registry.isDriver(2, reportingArea: 1_100_000))
    #expect(registry.isDriver(1, reportingArea: 1_000_000))
    // …a decisively bigger one does — fullscreen on the projector takes over.
    #expect(registry.isDriver(2, reportingArea: 2_000_000))
    #expect(!registry.isDriver(1, reportingArea: 1_000_000))
}

@Test func equalWindowsNeverFlap() {
    let registry = SZViewportDriverRegistry()
    registry.setVisible(tiles: [], windows: [1, 2])
    #expect(registry.isDriver(1, reportingArea: 500_000))
    for _ in 0..<5 {
        #expect(!registry.isDriver(2, reportingArea: 500_000))
        #expect(registry.isDriver(1, reportingArea: 500_000))
    }
}

@Test func miniaturizedDriverWindowIsDemotedImmediately() {
    let registry = SZViewportDriverRegistry()
    registry.setVisible(tiles: [0], windows: [1])
    #expect(registry.isDriver(1, reportingArea: 2_000_000))
    // The driving window miniaturizes (drops out of the window set): the tile takes over.
    registry.setVisible(tiles: [0], windows: [])
    #expect(registry.isDriver(0, reportingArea: 100))
}

@Test func emptySetsMeanNoDriver() {
    let registry = SZViewportDriverRegistry()
    registry.setVisible(tiles: [0], windows: [])
    #expect(registry.isDriver(0, reportingArea: 100))
    registry.setVisible(tiles: [], windows: [])
    #expect(!registry.isDriver(0, reportingArea: 100))
}

@Test func aFullscreenWindowOutranksALargerFloatingWindow() {
    // The stage-safety rung: an accidentally-enlarged floating preview window must never steal
    // native resolution from the fullscreen projector output, whatever their areas say.
    let registry = SZViewportDriverRegistry()
    registry.setVisible(tiles: [0], windows: [1, 2], fullscreen: [2])
    #expect(registry.isDriver(2, reportingArea: 2_073_600))       // 1080p projector
    #expect(!registry.isDriver(1, reportingArea: 6_000_000))      // huge floating window — still a mirror
    #expect(registry.isDriver(2, reportingArea: 2_073_600))
    // Exiting fullscreen returns that window to plain area competition — the bigger one wins now.
    registry.setVisible(tiles: [0], windows: [1, 2], fullscreen: [])
    #expect(registry.isDriver(1, reportingArea: 6_000_000))
}

@Test func fullscreenSetIsClampedToTheWindowSet() {
    // A stale fullscreen entry for a window that just closed must not strand drivership.
    let registry = SZViewportDriverRegistry()
    registry.setVisible(tiles: [0], windows: [1], fullscreen: [2])   // 2 isn't a window
    #expect(registry.isDriver(1, reportingArea: 500_000))
}

@Test func shrinkingTheDrivingWindowHandsOffToTheNowLargest() {
    // The driver window's own report shrinks (resized small): a decisively larger sibling window
    // takes over in the very same recompute.
    let registry = SZViewportDriverRegistry()
    registry.setVisible(tiles: [], windows: [1, 2])
    #expect(registry.isDriver(1, reportingArea: 2_000_000))
    #expect(!registry.isDriver(2, reportingArea: 1_000_000))   // sibling reports, stays a mirror
    #expect(!registry.isDriver(1, reportingArea: 400_000))     // shrank below 1M/1.15 → demoted
    #expect(registry.isDriver(2, reportingArea: 1_000_000))
}
