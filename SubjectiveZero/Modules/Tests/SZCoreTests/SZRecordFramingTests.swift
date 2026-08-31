// SPDX-License-Identifier: AGPL-3.0-only
// Pins the recording framing math: output sizes per ratio/tier, the crop-derived render size and
// its 4K-class cap, ratio re-fitting, and the drag clamp.
import Testing
@testable import SZCore

private let hd = (width: 1920, height: 1080)

@Test func outputSizesFollowRatioAndTier() {
    #expect(SZRecordFraming.outputSize(ratio: .wide, tier: .p1080, crop: .unit, picture: hd) == (1920, 1080))
    #expect(SZRecordFraming.outputSize(ratio: .tall, tier: .p1080, crop: .unit, picture: hd) == (1080, 1920))
    #expect(SZRecordFraming.outputSize(ratio: .square, tier: .p1080, crop: .unit, picture: hd) == (1080, 1080))
    #expect(SZRecordFraming.outputSize(ratio: .portrait, tier: .p1080, crop: .unit, picture: hd) == (1080, 1350))
    #expect(SZRecordFraming.outputSize(ratio: .wide, tier: .p720, crop: .unit, picture: hd) == (1280, 720))
    #expect(SZRecordFraming.outputSize(ratio: .wide, tier: .p2160, crop: .unit, picture: hd) == (3840, 2160))
}

@Test func freeRatioUsesTheCropsOwnAspect() {
    // full-frame free crop on a 16:9 picture is 16:9
    #expect(SZRecordFraming.outputSize(ratio: .free, tier: .p1080, crop: .unit, picture: hd) == (1920, 1080))
    // a square crop of that picture is square
    let square = SZRect(x: 0, y: 0, width: 0.5625, height: 1)   // 1080x1080 pixels
    let out = SZRecordFraming.outputSize(ratio: .free, tier: .p1080, crop: square, picture: hd)
    #expect(out == (1080, 1080))
}

@Test func renderSizeDividesByTheCropFraction() {
    // recording a 9:16 1080x1920 from a centered vertical crop of a 16:9 picture: the full frame
    // renders at 1920 / (1080/1920 x cropWidth...) — concretely, crop w = 0.31640625 → 3413-ish wide
    let crop = SZRect(x: 0.34, y: 0, width: 0.31640625, height: 1)
    let size = SZRecordFraming.renderSize(output: (1080, 1920), crop: crop)
    #expect(size.height == 1920)
    #expect(abs(size.width - 3414) <= 2)
    // both axes even
    #expect(size.width % 2 == 0 && size.height % 2 == 0)
}

@Test func renderSizeCapsTheLongSide() {
    // a tiny crop would ask for a huge full frame; the cap scales both axes proportionally
    let size = SZRecordFraming.renderSize(output: (3840, 2160), crop: SZRect(x: 0, y: 0, width: 0.25, height: 0.25))
    #expect(max(size.width, size.height) <= 4096)
    let aspect = Double(size.width) / Double(size.height)
    #expect(abs(aspect - 16.0 / 9.0) < 0.01)
}

@Test func fittedCentersAndFills() {
    // fitting 9:16 into a 16:9 picture: full height, centered on the old center
    let fitted = SZRecordFraming.fitted(.unit, toAspect: 9.0 / 16.0, picture: hd)
    #expect(fitted.height == 1)
    #expect(abs(fitted.width - 0.31640625) < 0.0001)
    #expect(abs(fitted.x - (1 - fitted.width) / 2) < 0.0001)
    // fitting 16:9 into itself: unchanged unit
    let same = SZRecordFraming.fitted(.unit, toAspect: 16.0 / 9.0, picture: hd)
    #expect(abs(same.width - 1) < 0.0001 && abs(same.height - 1) < 0.0001)
    // a corner-hugging crop stays inside the unit square after the re-fit
    let corner = SZRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1)
    let refit = SZRecordFraming.fitted(corner, toAspect: 1.0, picture: hd)
    #expect(refit.x >= 0 && refit.y >= 0)
    #expect(refit.x + refit.width <= 1.0001 && refit.y + refit.height <= 1.0001)
}

@Test func clampKeepsTheCropInTheUnitSquare() {
    let dragged = SZRect(x: -0.2, y: 0.8, width: 0.5, height: 0.5)
    let clamped = SZRecordFraming.clamped(dragged)
    #expect(clamped.x == 0 && clamped.y == 0.5)
    // and enforces the minimum size
    let tiny = SZRecordFraming.clamped(SZRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001))
    #expect(tiny.width >= 0.05 && tiny.height >= 0.05)
}

@Test func outputSizeCapsExtremeFreeCrops() {
    // a thin free strip must not ask the encoder for a 38000-pixel-wide frame
    let strip = SZRect(x: 0, y: 0.4, width: 1, height: 0.05)
    let out = SZRecordFraming.outputSize(ratio: .free, tier: .p1080, crop: strip, picture: hd)
    #expect(max(out.width, out.height) <= 4096)
    #expect(out.width % 2 == 0 && out.height % 2 == 0)
    // even-rounding a ~115-pixel height moves the aspect a little; ~3% is the honest bound
    let aspect = Double(out.width) / Double(out.height)
    #expect(abs(aspect - SZRecordFraming.cropAspect(strip, picture: hd)) / aspect < 0.03)
}

@Test func aspectResizedHoldsTheRatioAtTheEdges() {
    // dragging a square-ratio crop's bottom-right corner way past the picture edge: the crop
    // stops at the unit square WITHOUT breaking the lock (a per-axis clamp would)
    let r = SZRecordFraming.aspectResized(anchor: (x: 0.2, y: 0.2), dirX: 1, dirY: 1,
                                          desiredWidth: 2.0, aspect: 1.0, picture: hd)
    #expect(r.x + r.width <= 1.0001 && r.y + r.height <= 1.0001)
    #expect(abs(SZRecordFraming.cropAspect(r, picture: hd) - 1.0) < 0.001)
    // and from the opposite corner (negative growth direction)
    let l = SZRecordFraming.aspectResized(anchor: (x: 0.9, y: 0.9), dirX: -1, dirY: -1,
                                          desiredWidth: 2.0, aspect: 9.0 / 16.0, picture: hd)
    #expect(l.x >= -0.0001 && l.y >= -0.0001)
    #expect(abs(SZRecordFraming.cropAspect(l, picture: hd) - 9.0 / 16.0) < 0.001)
    // a tiny drag still respects the minimum size on both axes
    let s = SZRecordFraming.aspectResized(anchor: (x: 0.5, y: 0.5), dirX: 1, dirY: 1,
                                          desiredWidth: 0.001, aspect: 1.0, picture: hd)
    #expect(s.width >= 0.05 - 0.0001 && s.height >= 0.05 - 0.0001)
}
