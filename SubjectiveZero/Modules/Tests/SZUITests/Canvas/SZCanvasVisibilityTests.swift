// SPDX-License-Identifier: AGPL-3.0-only
// Viewport culling math for the preview watch set: cards in view (± overscan) are visible, far
// cards aren't, pan/zoom move the boundary. Uses compact (.none-body) nodes so the expected rects
// are gate-independent — preview-inset geometry has its own serialized suite.
import CoreGraphics
import Testing
@testable import SZUI
import SZCore

private func node(at x: Double, _ y: Double) -> SZNode {
    SZNode(kind: .generated, title: "N",
           contract: SZNodeContract(title: "N", sfSymbol: "circle", summary: "s",
                                    outputs: [SZPort(name: "output", type: .texture)]),
           position: SZPoint(x: x, y: y), body: SZNodeBody(mode: .none))
}

@Test func onScreenAndFarOffScreenSplitCorrectly() {
    let near = node(at: 400, 300)
    let far = node(at: 10_000, 10_000)
    let graph = SZGraph(nodes: [near, far])
    let visible = SZCanvasVisibility.visibleNodes(in: graph, camera: SZCanvasCamera(),
                                                  viewSize: CGSize(width: 800, height: 600))
    #expect(visible == [near.id])
}

@Test func overscanKeepsJustOffscreenCardsVisible() {
    // 800pt viewport + 25% overscan → the world boundary sits at x = 1000. A card centered at 1050
    // (left edge ≈ 942, base width 216) pokes into the band → visible; centered at 1600 (left edge
    // ≈ 1492) it's beyond → culled.
    let justOff = node(at: 1050, 300)
    let wellOff = node(at: 1600, 300)
    let graph = SZGraph(nodes: [justOff, wellOff])
    let visible = SZCanvasVisibility.visibleNodes(in: graph, camera: SZCanvasCamera(),
                                                  viewSize: CGSize(width: 800, height: 600))
    #expect(visible == [justOff.id])
}

@Test func panMovesTheWindow() {
    let far = node(at: 10_000, 10_000)
    let graph = SZGraph(nodes: [far])
    var camera = SZCanvasCamera()
    camera.pan(by: CGSize(width: -9_600, height: -9_700))   // world 10k lands mid-viewport
    let visible = SZCanvasVisibility.visibleNodes(in: graph, camera: camera,
                                                  viewSize: CGSize(width: 800, height: 600))
    #expect(visible == [far.id])
}

@Test func zoomingOutWidensTheSet() {
    let spread = (0..<6).map { node(at: Double($0) * 1_000, 300) }
    let graph = SZGraph(nodes: spread)
    let size = CGSize(width: 800, height: 600)
    let atOne = SZCanvasVisibility.visibleNodes(in: graph, camera: SZCanvasCamera(), viewSize: size)
    var zoomedOut = SZCanvasCamera()
    zoomedOut.applyZoom(SZCanvasCamera.zoomRange.lowerBound, pivot: .zero, from: zoomedOut)
    let atMin = SZCanvasVisibility.visibleNodes(in: graph, camera: zoomedOut, viewSize: size)
    #expect(atMin.count > atOne.count)
    #expect(atOne.isSubset(of: atMin))
}

@Test func degenerateViewportIsEmpty() {
    let graph = SZGraph(nodes: [node(at: 0, 0)])
    #expect(SZCanvasVisibility.visibleNodes(in: graph, camera: SZCanvasCamera(), viewSize: .zero).isEmpty)
}
