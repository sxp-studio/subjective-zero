// SPDX-License-Identifier: AGPL-3.0-only
// The auto-hiding header's reveal model (shared by docked tiles and pop-out strips): summon band,
// hysteresis on the revealed footprint, grace-period hide, and the pin.
import SwiftUI
import Testing
@testable import SZUI

private let band: CGFloat = 36
private let header: CGFloat = 28
private func at(_ y: CGFloat) -> HoverPhase { .active(CGPoint(x: 10, y: y)) }
private let grace: Duration = .milliseconds(20)
@MainActor private func model() -> SZHeaderRevealModel { SZHeaderRevealModel(hideGrace: grace) }
/// Await the grace timer itself rather than sleeping past it: these run on the MainActor alongside
/// tests that block it for seconds (node compiles), where a wall-clock sleep proves nothing.
@MainActor private func settle(_ m: SZHeaderRevealModel) async { await m.pendingHide?.value }

@MainActor @Test func hiddenUntilHoveredInBandAndAlwaysShownWhenAutoHideOff() {
    let m = model()
    #expect(!m.shown(autoHide: true))
    #expect(m.shown(autoHide: false))
    m.hover(at(band + 1), triggerBand: band, headerHeight: header)
    #expect(!m.visible)
    m.hover(at(band), triggerBand: band, headerHeight: header)
    #expect(m.visible)
    #expect(m.shown(autoHide: true))
}

@MainActor @Test func revealedHeaderFootprintKeepsItAlive() async {
    // A pop-out strip (28) under a 36 band: hysteresis = max(band, header) — cursor parked ON the
    // strip but past a thinner band (chat's 8) must not count as "out".
    let m = model()
    m.hover(at(4), triggerBand: 8, headerHeight: header)
    #expect(m.visible)
    m.hover(at(20), triggerBand: 8, headerHeight: header)   // on the header, outside the 8pt band
    await settle(m)
    #expect(m.visible)
    m.hover(at(header + 1), triggerBand: 8, headerHeight: header)
    await settle(m)
    #expect(!m.visible)
}

@MainActor @Test func leavingHidesAfterGraceAndReturningWithinGraceCancels() async {
    let m = model()
    m.hover(at(0), triggerBand: band, headerHeight: header)
    m.hover(.ended, triggerBand: band, headerHeight: header)
    #expect(m.visible)   // not yet — grace
    m.hover(at(0), triggerBand: band, headerHeight: header)   // back before the timer fires
    await settle(m)
    #expect(m.visible)
    m.hover(.ended, triggerBand: band, headerHeight: header)
    await settle(m)
    #expect(!m.visible)
}

@MainActor @Test func pinBlocksHideUntilUnpinned() async {
    let m = model()
    m.hover(at(0), triggerBand: band, headerHeight: header)
    m.pinned = true
    m.hover(at(500), triggerBand: band, headerHeight: header)
    await settle(m)
    #expect(m.visible)
    #expect(m.shown(autoHide: true))
    m.unpin()
    #expect(!m.pinned)
    await settle(m)
    #expect(!m.visible)
}
