// SPDX-License-Identifier: AGPL-3.0-only
// The driver registry is fed from viewport SURFACES (views actually in a window), never from the
// layout tree: a viewport that is in the layout but unmounted — maximized-away, hidden by the
// welcome surface — can't be a ghost driver, and detaching the last surface leaves no driver.
// Pure host bookkeeping — no runtime, no windows (`syncViewportDriver` tolerates both).
import QuartzCore
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostViewportSurfacesTests {

    /// `SZHost()` reads this machine's real app-state.json, so a window arrangement with no
    /// viewport in it would fail these on a developer's desk rather than on their change.
    /// The layout each test means is stated, never inherited.
    private func host() -> SZHost {
        let fresh = SZHost()
        fresh.panelLayout = .default
        return fresh
    }

    private func attach(_ id: SZPanelID, to host: SZHost) -> CAMetalLayer {
        let layer = CAMetalLayer()
        host.viewportSurfaces.append(SZViewportSurface(id: id, layer: layer, view: nil))
        host.viewportDriver.reportArea(id.instance, 1_000_000)
        host.syncViewportDriver()
        return layer
    }

    @Test func aViewportInTheLayoutButNotAttachedIsNeverTheDriver() {
        // The default layout holds the primary viewport (0), but only a clone's (1) view is in a
        // window — the primary is maximized-away. The primary would win by the ladder; it has no
        // surface, so it can't.
        let host = host()
        #expect(host.panelLayout.contains(SZPanelID(.viewport, instance: 0)))
        #expect(host.viewportDriver.driver == nil)
        _ = attach(SZPanelID(.viewport, instance: 1), to: host)
        #expect(host.viewportDriver.driver == 1)
    }

    @Test func detachingTheLastSurfaceLeavesNoDriver() {
        let host = host()
        let id = SZPanelID(.viewport, instance: 0)
        let layer = attach(id, to: host)
        #expect(host.viewportDriver.driver == 0)
        host.viewportSurfaces.removeAll { $0.layer === layer }
        host.syncViewportDriver()
        #expect(host.viewportDriver.driver == nil)
    }
}
