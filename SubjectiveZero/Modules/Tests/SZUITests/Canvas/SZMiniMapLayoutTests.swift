// SPDX-License-Identifier: AGPL-3.0-only
// The mini map's geometry: the shown extent covers graph AND viewport, the fit preserves aspect,
// world↔map round-trips, and the click / drag navigation math lands the camera where the pointer
// says. Headless, like the camera + culling suites beside it.
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

private func close(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat = 1e-6) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
}

@Test func viewportWorldRectIsTheCameraInverseOfTheScreen() {
    let camera = SZCanvasCamera(zoom: 2, offset: CGSize(width: 100, height: -50))
    let rect = SZMiniMapLayout.viewportWorldRect(camera: camera, viewSize: CGSize(width: 800, height: 600))
    #expect(close(rect.origin, camera.worldPoint(screen: .zero)))
    #expect(abs(rect.width - 400) < 1e-9)   // 800 / zoom 2
    #expect(abs(rect.height - 300) < 1e-9)
}

@Test func extentCoversBothGraphAndViewportAndFitPreservesAspect() {
    let graph = SZGraph(nodes: [node(at: 0, 0), node(at: 3000, 200)])
    let bounds = SZGraphCanvasModel.worldBounds(of: graph)!
    let viewport = CGRect(x: -2000, y: -2000, width: 800, height: 600)   // far off the graph
    let layout = SZMiniMapLayout(graphBounds: bounds, viewport: viewport)
    #expect(layout.extent.contains(bounds))
    #expect(layout.extent.contains(viewport))
    let mapped = layout.mapRect(world: layout.extent)
    #expect(mapped.width <= layout.size.width + 1e-9)
    #expect(mapped.height <= layout.size.height + 1e-9)
    #expect(abs(mapped.width - layout.size.width) < 1e-6 || abs(mapped.height - layout.size.height) < 1e-6)
    // Centered along the slack axis.
    #expect(abs(mapped.midX - layout.size.width / 2) < 1e-6)
    #expect(abs(mapped.midY - layout.size.height / 2) < 1e-6)
}

@Test func emptyGraphShowsJustTheViewport() {
    let viewport = CGRect(x: 10, y: 20, width: 800, height: 600)
    let layout = SZMiniMapLayout(graphBounds: nil, viewport: viewport)
    #expect(layout.extent.contains(viewport))
    #expect(layout.extent.insetBy(dx: 100, dy: 100).width < viewport.width)   // padded by the margin only
}

@Test func worldAndMapPointsRoundTrip() {
    let layout = SZMiniMapLayout(graphBounds: CGRect(x: -300, y: 50, width: 900, height: 400),
                                 viewport: CGRect(x: 0, y: 0, width: 800, height: 600))
    let world = CGPoint(x: 123.4, y: -56.7)
    #expect(close(layout.worldPoint(map: layout.mapPoint(world: world)), world))
}

@Test func clickingANodeOnTheMapCentersTheViewportOnIt() {
    let target = node(at: 2400, 900)
    let graph = SZGraph(nodes: [node(at: 0, 0), target])
    let viewSize = CGSize(width: 800, height: 600)
    let camera = SZCanvasCamera(zoom: 1.3, offset: CGSize(width: 40, height: 40))
    let layout = SZMiniMapLayout(graphBounds: SZGraphCanvasModel.worldBounds(of: graph),
                                 viewport: SZMiniMapLayout.viewportWorldRect(camera: camera, viewSize: viewSize))
    let click = layout.mapPoint(world: CGPoint(x: 2400, y: 900))
    let centered = layout.cameraCentering(mapPoint: click, camera: camera, viewSize: viewSize)
    #expect(centered.zoom == camera.zoom)
    let underCenter = centered.worldPoint(screen: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    #expect(close(underCenter, CGPoint(x: 2400, y: 900), tolerance: 1e-6))
}

@Test func draggingTheMapMovesTheViewportTheSameWorldDistance() {
    let viewSize = CGSize(width: 800, height: 600)
    let start = SZCanvasCamera(zoom: 0.8, offset: CGSize(width: -120, height: 30))
    let layout = SZMiniMapLayout(graphBounds: CGRect(x: 0, y: 0, width: 4000, height: 3000),
                                 viewport: SZMiniMapLayout.viewportWorldRect(camera: start, viewSize: viewSize))
    let translation = CGSize(width: 30, height: -12)   // map points
    let dragged = layout.cameraDragging(by: translation, from: start)
    let before = SZMiniMapLayout.viewportWorldRect(camera: start, viewSize: viewSize)
    let after = SZMiniMapLayout.viewportWorldRect(camera: dragged, viewSize: viewSize)
    #expect(dragged.zoom == start.zoom)
    #expect(abs((after.minX - before.minX) - translation.width / layout.scale) < 1e-6)
    #expect(abs((after.minY - before.minY) - translation.height / layout.scale) < 1e-6)
}
