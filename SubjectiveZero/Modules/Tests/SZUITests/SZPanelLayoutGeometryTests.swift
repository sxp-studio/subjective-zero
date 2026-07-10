// SPDX-License-Identifier: AGPL-3.0-only
// Panel-layout geometry — leaf/divider rects, min-size clamping, undersized-window degradation, and
// drop-zone boundaries. Headless like SZGraphCanvasModelTests: the container view renders exactly
// these rects, so pinning them here pins the layout behavior.
import CoreGraphics
import Foundation
import Testing
@testable import SZUI
import SZCore

private let window = CGRect(x: 0, y: 0, width: 1440, height: 860)
private let divider = SZPanelLayoutGeometry.dividerThickness

@Test func defaultLayoutTilesTheWindow() {
    let frames = SZPanelLayoutGeometry.leafFrames(root: SZPanelLayoutState.default.root, in: window)
    let viewport = frames[.viewport]!, editor = frames[.nodeEditor]!, chat = frames[.chat]!

    // Chat = right column, full height; viewport over editor fill the left column.
    #expect(chat.maxX == window.maxX && chat.minY == 0 && chat.height == window.height)
    #expect(viewport.minX == 0 && viewport.minY == 0)
    #expect(editor.maxY == window.maxY)
    #expect(viewport.width == editor.width)
    // Dividers carve exact gaps: columns and rows sum back to the window.
    #expect(viewport.width + divider + chat.width == window.width)
    #expect(viewport.height + divider + editor.height == window.height)
    // Fractions honored (0.75 of the width net of the divider, 0.6 of the left column's height).
    #expect(abs(viewport.width - (window.width - divider) * 0.75) < 0.5)
    #expect(abs(viewport.height - (window.height - divider) * 0.6) < 0.5)
}

@Test func minSizeWinsOverFraction() {
    var layout = SZPanelLayoutState.default
    layout.setFraction(0.95, at: [])   // squeeze chat below its 280 min width
    let frames = SZPanelLayoutGeometry.leafFrames(root: layout.root, in: window)
    #expect(frames[.chat]!.width == SZPanelLayoutGeometry.minSize(for: .chat).width)
    #expect(frames[.viewport]!.width == window.width - divider - frames[.chat]!.width)
}

@Test func undersizedWindowDegradesProportionallyNeverNegative() {
    // 300pt wide can't fit viewport(240) + chat(280) side by side.
    let tiny = CGRect(x: 0, y: 0, width: 300, height: 400)
    let root: SZPanelLayoutNode = .split(orientation: .horizontal, fraction: 0.5,
                                         leading: .panel(.viewport), trailing: .panel(.chat))
    let frames = SZPanelLayoutGeometry.leafFrames(root: root, in: tiny)
    let viewport = frames[.viewport]!, chat = frames[.chat]!
    #expect(viewport.width > 0 && chat.width > 0)
    #expect(viewport.width + divider + chat.width == tiny.width)
    // Shares match the 240:280 minimum ratio.
    #expect(abs(viewport.width / chat.width - 240.0 / 280.0) < 0.01)
}

@Test func dividerFramesAddressEverySplit() {
    let dividers = SZPanelLayoutGeometry.dividerFrames(root: SZPanelLayoutState.default.root, in: window)
    #expect(dividers.count == 2)
    let byPath = Dictionary(uniqueKeysWithValues: dividers.map { ($0.path, $0) })
    let outer = byPath[[]]!, inner = byPath[[.leading]]!
    #expect(outer.orientation == .horizontal && outer.rect.width == divider
            && outer.rect.height == window.height)
    #expect(inner.orientation == .vertical && inner.rect.height == divider)
    #expect(inner.splitRect.width == outer.rect.minX)   // inner split = the left column
}

@Test func dividerDragMapsLocationToFraction() {
    let splitRect = CGRect(x: 0, y: 0, width: 1000 + divider, height: 500)
    let mid = SZPanelLayoutGeometry.fraction(
        forDividerAt: CGPoint(x: 500 + divider / 2, y: 100), orientation: .horizontal, in: splitRect)
    #expect(abs(mid - 0.5) < 0.001)
    // Off both ends clamps to 0…1.
    #expect(SZPanelLayoutGeometry.fraction(forDividerAt: CGPoint(x: -50, y: 0), orientation: .horizontal, in: splitRect) == 0)
    #expect(SZPanelLayoutGeometry.fraction(forDividerAt: CGPoint(x: 2000, y: 0), orientation: .horizontal, in: splitRect) == 1)
    // Vertical uses y.
    let vertical = SZPanelLayoutGeometry.fraction(
        forDividerAt: CGPoint(x: 0, y: 250 + divider / 2), orientation: .vertical,
        in: CGRect(x: 0, y: 0, width: 500, height: 500 + divider))
    #expect(abs(vertical - 0.5) < 0.001)
}

@Test func dropZoneCenterCoreAndEdgeProximity() {
    let rect = CGRect(x: 0, y: 0, width: 400, height: 200)
    #expect(SZPanelLayoutGeometry.dropZone(at: CGPoint(x: 200, y: 100), in: rect) == .center)
    // Just inside the 25%-inset core boundary is still center; outside it, the nearest edge wins.
    #expect(SZPanelLayoutGeometry.dropZone(at: CGPoint(x: 101, y: 100), in: rect) == .center)
    #expect(SZPanelLayoutGeometry.dropZone(at: CGPoint(x: 99, y: 100), in: rect) == .left)
    #expect(SZPanelLayoutGeometry.dropZone(at: CGPoint(x: 301, y: 100), in: rect) == .right)
    #expect(SZPanelLayoutGeometry.dropZone(at: CGPoint(x: 200, y: 20), in: rect) == .top)
    #expect(SZPanelLayoutGeometry.dropZone(at: CGPoint(x: 200, y: 180), in: rect) == .bottom)
    // Corners: normalized distance decides (30/400 of width beats 40/200 of height → left).
    #expect(SZPanelLayoutGeometry.dropZone(at: CGPoint(x: 30, y: 40), in: rect) == .left)
    #expect(SZPanelLayoutGeometry.dropZone(at: CGPoint(x: 40, y: 10), in: rect) == .top)
}

@Test func dropPreviewRectsCoverTheAdvertisedHalf() {
    let rect = CGRect(x: 100, y: 50, width: 400, height: 200)
    #expect(SZPanelLayoutGeometry.dropPreviewRect(zone: .left, in: rect)
            == CGRect(x: 100, y: 50, width: 200, height: 200))
    #expect(SZPanelLayoutGeometry.dropPreviewRect(zone: .right, in: rect)
            == CGRect(x: 300, y: 50, width: 200, height: 200))
    #expect(SZPanelLayoutGeometry.dropPreviewRect(zone: .top, in: rect)
            == CGRect(x: 100, y: 50, width: 400, height: 100))
    #expect(SZPanelLayoutGeometry.dropPreviewRect(zone: .bottom, in: rect)
            == CGRect(x: 100, y: 150, width: 400, height: 100))
    #expect(SZPanelLayoutGeometry.dropPreviewRect(zone: .center, in: rect) == rect)
}
