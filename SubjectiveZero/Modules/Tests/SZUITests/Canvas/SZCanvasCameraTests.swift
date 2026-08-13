// SPDX-License-Identifier: AGPL-3.0-only
// The node-editor camera math — zoom-about-pivot, range clamping, screen↔world round-trips, and the
// Center View / Zoom to Fit framings — pinned headlessly so navigation regressions can't hide behind
// trackpad-only verification.
import CoreGraphics
import Testing
@testable import SZUI

@Test func worldAndScreenPointsRoundTrip() {
    let camera = SZCanvasCamera(zoom: 1.7, offset: CGSize(width: -40, height: 220))
    let screen = CGPoint(x: 123, y: 456)
    let back = camera.screenPoint(world: camera.worldPoint(screen: screen))
    #expect(abs(back.x - screen.x) < 1e-9)
    #expect(abs(back.y - screen.y) < 1e-9)
}

@Test func zoomAboutPivotKeepsTheWorldPointUnderThePivotFixed() {
    var camera = SZCanvasCamera(zoom: 0.8, offset: CGSize(width: 100, height: -50))
    let pivot = CGPoint(x: 300, y: 200)
    let worldBefore = camera.worldPoint(screen: pivot)
    camera.applyZoom(1.6, pivot: pivot, from: camera)
    #expect(camera.zoom == 1.6)
    let worldAfter = camera.worldPoint(screen: pivot)
    #expect(abs(worldAfter.x - worldBefore.x) < 1e-9)
    #expect(abs(worldAfter.y - worldBefore.y) < 1e-9)
}

@Test func pinchReanchorsOnItsStartCameraNotTheLiveOne() {
    // A pinch applies target = anchorZoom · gestureValue against the camera at pinch START — feeding
    // successive ticks through the same anchor must not accumulate drift on the pivot's world point.
    let anchor = SZCanvasCamera(zoom: 1.2, offset: CGSize(width: 30, height: 40))
    let pivot = CGPoint(x: 150, y: 90)
    let held = anchor.worldPoint(screen: pivot)
    var camera = anchor
    for value in [0.9, 1.1, 1.4, 1.05] {
        camera.applyZoom(anchor.zoom * value, pivot: pivot, from: anchor)
        let now = camera.worldPoint(screen: pivot)
        #expect(abs(now.x - held.x) < 1e-9)
        #expect(abs(now.y - held.y) < 1e-9)
    }
}

@Test func zoomClampsToRangeAtBothEndsAndStillHoldsThePivot() {
    let pivot = CGPoint(x: 10, y: 20)
    var camera = SZCanvasCamera()
    let held = camera.worldPoint(screen: pivot)
    camera.applyZoom(99, pivot: pivot, from: camera)
    #expect(camera.zoom == SZCanvasCamera.zoomRange.upperBound)
    #expect(abs(camera.worldPoint(screen: pivot).x - held.x) < 1e-9)
    camera.applyZoom(0.001, pivot: pivot, from: camera)
    #expect(camera.zoom == SZCanvasCamera.zoomRange.lowerBound)
    #expect(abs(camera.worldPoint(screen: pivot).y - held.y) < 1e-9)
}

@Test func panIsAdditiveInScreenSpace() {
    var camera = SZCanvasCamera(zoom: 2, offset: CGSize(width: 5, height: 6))
    camera.pan(by: CGSize(width: 10, height: -4))
    camera.pan(by: CGSize(width: -3, height: 1))
    #expect(camera.offset == CGSize(width: 12, height: 3))
    #expect(camera.zoom == 2)   // pan never touches zoom
}

@Test func centeredMapsBoundsMidpointToViewportCenterAtTheGivenZoom() {
    let bounds = CGRect(x: -200, y: 100, width: 500, height: 240)
    let view = CGSize(width: 1000, height: 800)
    let camera = SZCanvasCamera.centered(on: bounds, in: view, zoom: 1.3)
    #expect(camera.zoom == 1.3)
    let center = camera.screenPoint(world: CGPoint(x: bounds.midX, y: bounds.midY))
    #expect(abs(center.x - 500) < 1e-9)
    #expect(abs(center.y - 400) < 1e-9)
}

@Test func fittingFramesBoundsWithTheProportionalMarginAndCentersThem() {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 300)
    let view = CGSize(width: 1200, height: 900)
    let camera = SZCanvasCamera.fitting(bounds, in: view)
    // The margin is max(80, 0.14·dim) per axis: 140 on x (0.14·1000), 80 on y (floor beats 42).
    let framed = bounds.insetBy(dx: -140, dy: -80)
    #expect(abs(camera.zoom - min(1200 / framed.width, 900 / framed.height)) < 1e-9)
    let center = camera.screenPoint(world: CGPoint(x: framed.midX, y: framed.midY))
    #expect(abs(center.x - 600) < 1e-9)
    #expect(abs(center.y - 450) < 1e-9)
}

@Test func fittingClampsATinyGraphToTheMaxZoom() {
    // A 10×10 graph would need zoom ≫ range to fill the view — the clamp keeps it at the ceiling.
    let camera = SZCanvasCamera.fitting(CGRect(x: 0, y: 0, width: 10, height: 10),
                                        in: CGSize(width: 1000, height: 800))
    #expect(camera.zoom == SZCanvasCamera.zoomRange.upperBound)
}
