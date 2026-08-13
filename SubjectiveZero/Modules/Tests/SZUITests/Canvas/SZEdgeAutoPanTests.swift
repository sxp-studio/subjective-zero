// SPDX-License-Identifier: AGPL-3.0-only
// Edge auto-pan math, headless: the per-edge quadratic intensity ramp and the screen-space velocity
// it feeds. Signs matter — revealing content to the right must SHRINK canvasOffset.width.
import CoreGraphics
import Testing
@testable import SZUI

private let size = CGSize(width: 800, height: 600)

@Test func centerOfALargeViewIsInert() {
    #expect(SZEdgeAutoPan.velocity(cursor: CGPoint(x: 400, y: 300), in: size) == .zero)
    #expect(!SZEdgeAutoPan.intensities(cursor: CGPoint(x: 400, y: 300), in: size).isActive)
}

@Test func rightEdgePansAtMaxSpeedLeftward() {
    let v = SZEdgeAutoPan.velocity(cursor: CGPoint(x: 800, y: 300), in: size)
    #expect(v.width == -SZEdgeAutoPan.maxSpeed)
    #expect(v.height == 0)
}

@Test func exactlyAtTheZoneBoundaryIsStillInert() {
    let v = SZEdgeAutoPan.velocity(cursor: CGPoint(x: SZEdgeAutoPan.zone, y: 300), in: size)
    #expect(v == .zero)
}

@Test func insideTheZoneSpeedIsBoundedAndSignedPerEdge() {
    // 15pt from the left edge → pan right-to-left reveal (offset grows): positive width.
    let v = SZEdgeAutoPan.velocity(cursor: CGPoint(x: 15, y: 300), in: size)
    #expect(v.width >= SZEdgeAutoPan.minSpeed && v.width <= SZEdgeAutoPan.maxSpeed)
    #expect(v.height == 0)
    // 15pt from the bottom edge → negative height.
    let vb = SZEdgeAutoPan.velocity(cursor: CGPoint(x: 400, y: 590), in: size)
    #expect(vb.width == 0)
    #expect(vb.height <= -SZEdgeAutoPan.minSpeed && vb.height >= -SZEdgeAutoPan.maxSpeed)
}

@Test func pastTheEdgeSaturatesAtMaxSpeed() {
    let v = SZEdgeAutoPan.velocity(cursor: CGPoint(x: 900, y: -40), in: size)
    #expect(v.width == -SZEdgeAutoPan.maxSpeed)
    #expect(v.height == SZEdgeAutoPan.maxSpeed)
}

@Test func zeroSizeViewIsInert() {
    #expect(SZEdgeAutoPan.velocity(cursor: CGPoint(x: 10, y: 10), in: .zero) == .zero)
}

@Test func intensityFallsOffMonotonicallyAndQuadratically() {
    var last: CGFloat = 1.1
    for x in stride(from: CGFloat(0), through: SZEdgeAutoPan.zone, by: 5) {
        let i = SZEdgeAutoPan.intensities(cursor: CGPoint(x: x, y: 300), in: size).left
        #expect(i < last)
        last = i
    }
    // Spot-check the quadratic shape: halfway into the zone → (1 − 0.5)² = 0.25.
    let half = SZEdgeAutoPan.intensities(cursor: CGPoint(x: SZEdgeAutoPan.zone / 2, y: 300), in: size)
    #expect(abs(half.left - 0.25) < 0.0001)
}

@Test func cornerActivatesBothAxes() {
    let v = SZEdgeAutoPan.velocity(cursor: CGPoint(x: 795, y: 595), in: size)
    #expect(v.width < 0 && v.height < 0)
}
