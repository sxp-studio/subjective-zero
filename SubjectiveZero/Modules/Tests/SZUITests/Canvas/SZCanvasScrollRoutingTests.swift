// SPDX-License-Identifier: AGPL-3.0-only
// Which canvas a scroll belongs to. The scroll monitor is window-wide — every open canvas sees
// every scroll — so this frame test is the whole arbitration rule, and it used to be a hover flag
// that could stick in either position (pan dead on one canvas, or two canvases panning together).
import AppKit
import CoreGraphics
import Testing
@testable import SZUI

private typealias Catcher = SZCanvasScrollWheelCatcher.CatcherView

@Test func aScrollInsideTheCanvasIsClaimed() {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    #expect(Catcher.accepts(point: CGPoint(x: 400, y: 300), in: bounds))
    #expect(Catcher.accepts(point: CGPoint(x: 0, y: 0), in: bounds))       // top-left corner
    #expect(Catcher.accepts(point: CGPoint(x: 799.5, y: 599.5), in: bounds))
}

@Test func aScrollOutsideTheCanvasIsLeftForTheNeighbour() {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    #expect(!Catcher.accepts(point: CGPoint(x: -1, y: 300), in: bounds))
    #expect(!Catcher.accepts(point: CGPoint(x: 900, y: 300), in: bounds))  // the tile next door
    #expect(!Catcher.accepts(point: CGPoint(x: 400, y: 620), in: bounds))
    #expect(!Catcher.accepts(point: CGPoint(x: 800, y: 600), in: bounds))  // max edge is exclusive
}

/// A panel mid-layout must claim nothing rather than swallowing every scroll whose point happens to
/// land on the origin — `CGRect.contains` says yes to (0,0) in a zero-size rect at the origin.
@Test func anUnmeasuredCanvasClaimsNothing() {
    #expect(!Catcher.accepts(point: .zero, in: .zero))
    #expect(!Catcher.accepts(point: CGPoint(x: 10, y: 10), in: CGRect(x: 10, y: 10, width: 0, height: 40)))
}

/// The view converts window points into its own flipped space, so the point handed to the panel is
/// already in canvas coordinates (top-left origin) — the ⌘-scroll zoom pivots on it directly.
@MainActor @Test func theCatcherViewReportsTopLeftOriginPoints() {
    let view = Catcher(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    #expect(view.isFlipped)
}
