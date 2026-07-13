// SPDX-License-Identifier: AGPL-3.0-only
// The context menu's shift-clamped placement — opens at the click point, slides inward near the
// right/bottom edges (8pt margin), NSMenu-like — pinned headlessly.
import CoreGraphics
import Testing
@testable import SZUI

private func session(anchor: CGPoint) -> SZContextMenuSession {
    SZContextMenuSession(target: .canvas, anchor: anchor, suggestions: [])
}

private let menu = CGSize(width: 240, height: 180)
private let view = CGSize(width: 1000, height: 700)

@Test func menuOpensAtTheAnchorWhenItFits() {
    let anchor = CGPoint(x: 300, y: 200)
    #expect(session(anchor: anchor).origin(menuSize: menu, in: view) == anchor)
    #expect(session(anchor: anchor).frame(menuSize: menu, in: view)
            == CGRect(origin: anchor, size: menu))
}

@Test func menuSlidesInwardNearTheRightAndBottomEdges() {
    let origin = session(anchor: CGPoint(x: 990, y: 690)).origin(menuSize: menu, in: view)
    #expect(origin == CGPoint(x: 1000 - 240 - 8, y: 700 - 180 - 8))   // 8pt margin, both axes
}

@Test func menuNeverGoesAboveTheTopLeftMargin() {
    #expect(session(anchor: CGPoint(x: -50, y: -50)).origin(menuSize: menu, in: view)
            == CGPoint(x: 8, y: 8))
}
