// SPDX-License-Identifier: AGPL-3.0-only
// Drag-to-dock hit-testing — the pure model behind dragging a popped-out window over the main
// window: candidate resolution (zones, maximize override, off-grid nil), the center→nearest-edge
// mapping (docking never swaps), screen↔container conversion, and the restore-frame sanitizer.
import CoreGraphics
import Foundation
import Testing
@testable import SZCore
@testable import SZUI

// A simple two-tile layout for hit-testing: viewport | chat, split 50/50 horizontally.
private let twoTiles = SZPanelLayoutState(
    root: .split(orientation: .horizontal, fraction: 0.5,
                 leading: .panel(.viewport), trailing: .panel(.chat)))
private let containerSize = CGSize(width: 800, height: 600)
private let topInset: CGFloat = 8

@Test func candidateIsNilOffEveryTile() {
    // The outer gap and the divider strip belong to no tile.
    #expect(SZPopoutDockSession.candidate(at: CGPoint(x: 2, y: 300), layout: twoTiles,
                                          maximized: nil, containerSize: containerSize,
                                          topInset: topInset) == nil)
    #expect(SZPopoutDockSession.candidate(at: CGPoint(x: -50, y: -50), layout: twoTiles,
                                          maximized: nil, containerSize: containerSize,
                                          topInset: topInset) == nil)
}

@Test func candidateResolvesEdgeZonesAndPreviewMatchesGeometry() {
    // Near the left tile's left edge → dock left of the viewport, preview = its left half.
    let point = CGPoint(x: 20, y: 300)
    let candidate = SZPopoutDockSession.candidate(at: point, layout: twoTiles, maximized: nil,
                                                  containerSize: containerSize, topInset: topInset)
    #expect(candidate?.target == .viewport)
    #expect(candidate?.zone == .left)
    let gap = SZPanelLayoutGeometry.outerGap
    let rect = CGRect(x: gap, y: topInset, width: containerSize.width - gap * 2,
                      height: containerSize.height - topInset - gap)
    let frames = SZPanelLayoutGeometry.leafFrames(root: twoTiles.root, in: rect)
    #expect(candidate?.preview == SZPanelLayoutGeometry.dropPreviewRect(zone: .left, in: frames[.viewport]!))
}

@Test func candidateMapsCenterToNearestEdge() {
    // Dead center of the right tile: dropZone says .center, but a detached panel has nothing to
    // swap with — the session resolves to the nearest edge instead (never .center).
    let gap = SZPanelLayoutGeometry.outerGap
    let rect = CGRect(x: gap, y: topInset, width: containerSize.width - gap * 2,
                      height: containerSize.height - topInset - gap)
    let frames = SZPanelLayoutGeometry.leafFrames(root: twoTiles.root, in: rect)
    let chatRect = frames[.chat]!
    // Slightly above center → .top wins among the edges.
    let point = CGPoint(x: chatRect.midX, y: chatRect.midY - 10)
    #expect(SZPanelLayoutGeometry.dropZone(at: point, in: chatRect) == .center)
    let candidate = SZPopoutDockSession.candidate(at: point, layout: twoTiles, maximized: nil,
                                                  containerSize: containerSize, topInset: topInset)
    #expect(candidate?.target == .chat)
    #expect(candidate?.zone == .top)
}

@Test func nearestEdgeZoneBreaksTiesLikeTheGeometry() {
    // The exact center of a square rect ties all four edges — left wins, matching
    // SZPanelLayoutGeometry.dropZone's own edge ordering.
    let square = CGRect(x: 0, y: 0, width: 100, height: 100)
    #expect(SZPopoutDockSession.nearestEdgeZone(at: CGPoint(x: 50, y: 50), in: square) == .left)
    // Off-center ties resolve by the same ordering: equidistant left+top → left.
    #expect(SZPopoutDockSession.nearestEdgeZone(at: CGPoint(x: 40, y: 40), in: square) == .left)
    // A plain edge point passes through untouched.
    #expect(SZPopoutDockSession.nearestEdgeZone(at: CGPoint(x: 95, y: 50), in: square) == .right)
}

@Test func candidateHonorsMaximizeOverride() {
    // With chat maximized, the whole rect is chat's — a drag anywhere docks against chat.
    let candidate = SZPopoutDockSession.candidate(at: CGPoint(x: 20, y: 300), layout: twoTiles,
                                                  maximized: .chat, containerSize: containerSize,
                                                  topInset: topInset)
    #expect(candidate?.target == .chat)
    // A maximized id that is NOT in the tree is ignored (same rule as the container).
    let ignored = SZPopoutDockSession.candidate(at: CGPoint(x: 20, y: 300), layout: twoTiles,
                                                maximized: .profiler, containerSize: containerSize,
                                                topInset: topInset)
    #expect(ignored?.target == .viewport)
}

@Test func screenAndContainerConversionRoundTrips() {
    // AppKit screen space is bottom-left origin; the container is top-left under the titlebar
    // safe area. A round trip through both directions must be exact.
    let content = CGRect(x: 100, y: 200, width: 800, height: 600)
    let safeArea: CGFloat = 28
    let screenPoint = CGPoint(x: 350, y: 500)
    let container = SZPopoutDockSession.containerPoint(fromScreen: screenPoint,
                                                       contentScreenFrame: content, safeAreaTop: safeArea)
    #expect(container == CGPoint(x: 250, y: 272))   // y: 800 − 500 − 28
    let rect = CGRect(x: 250, y: 272, width: 120, height: 80)
    let screenRect = SZPopoutDockSession.screenRect(forContainerRect: rect,
                                                    contentScreenFrame: content, safeAreaTop: safeArea)
    // Back-convert the rect's top-left: the container point falls on the rect's origin.
    let topLeft = SZPopoutDockSession.containerPoint(fromScreen: CGPoint(x: screenRect.minX, y: screenRect.maxY),
                                                     contentScreenFrame: content, safeAreaTop: safeArea)
    #expect(topLeft == rect.origin)
    #expect(screenRect.size == rect.size)
}

@Test func sanitizedRestoreFrameKeepsOnScreenFrames() {
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let frame = CGRect(x: 400, y: 300, width: 640, height: 400)
    #expect(SZPopoutDockSession.sanitizedRestoreFrame(frame, visibleScreenFrames: [screen],
                                                      minSize: CGSize(width: 240, height: 180)) == frame)
}

@Test func sanitizedRestoreFrameRecentersOffScreenFrames() {
    // The saved frame lived on a display that's gone: recenter on the first screen, same size.
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let gone = CGRect(x: 4000, y: 300, width: 640, height: 400)
    let restored = SZPopoutDockSession.sanitizedRestoreFrame(gone, visibleScreenFrames: [screen],
                                                             minSize: CGSize(width: 240, height: 180))
    #expect(restored == CGRect(x: 640, y: 340, width: 640, height: 400))
}

@Test func sanitizedRestoreFrameRejectsCorruptOrScreenlessFrames() {
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    // Smaller than the panel's minimum → corrupt record, don't restore.
    #expect(SZPopoutDockSession.sanitizedRestoreFrame(CGRect(x: 0, y: 0, width: 50, height: 50),
                                                      visibleScreenFrames: [screen],
                                                      minSize: CGSize(width: 240, height: 180)) == nil)
    // No screens at all (headless edge) → nothing to restore onto.
    #expect(SZPopoutDockSession.sanitizedRestoreFrame(CGRect(x: 0, y: 0, width: 640, height: 400),
                                                      visibleScreenFrames: [],
                                                      minSize: CGSize(width: 240, height: 180)) == nil)
}

@Test func cloneTilesGetDistinctFrames() {
    // Two viewport instances are two tiles with two disjoint rects, each keyed by its own id.
    var layout = SZPanelLayoutState.default
    let clone = layout.clonePanel(.viewport)
    #expect(clone != nil)
    let rect = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let frames = SZPanelLayoutGeometry.leafFrames(root: layout.root, in: rect)
    let primary = frames[.viewport]
    let cloneFrame = frames[clone!]
    #expect(primary != nil && cloneFrame != nil)
    #expect(primary!.intersection(cloneFrame!).isNull || primary!.intersection(cloneFrame!).isEmpty)
}
