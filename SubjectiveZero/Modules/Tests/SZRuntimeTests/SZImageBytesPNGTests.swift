// SPDX-License-Identifier: AGPL-3.0-only
// `SZImageBytes.pngData(maxDimension:)` — the downscale-on-encode behind `agent_view_frame`. Keeps the
// captured frame within an agent's token budget (billed by image dimensions), never upscales.
import Testing
import Foundation
import ImageIO
@testable import SZRuntime

/// Decode PNG bytes to their pixel dimensions (round-trips through ImageIO, matching how an agent's
/// harness would decode the returned image).
private func pngSize(_ data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    return (image.width, image.height)
}

/// A solid-gray 1280×800 frame (the runtime's default render size) — content doesn't matter, only dims.
private func frame1280x800() -> SZImageBytes {
    SZImageBytes(width: 1280, height: 800, bgra: [UInt8](repeating: 128, count: 1280 * 800 * 4))
}

@Test func downscalesLongEdgeToMaxDimension() throws {
    let png = try #require(frame1280x800().pngData(maxDimension: 768))
    let size = try #require(pngSize(png))
    // 1280×800 scaled so the long edge is 768 → 768×480 (800 * 768/1280).
    #expect(size.width == 768)
    #expect(size.height == 480)
}

@Test func downscaleRespectsSmallerMax() throws {
    let png = try #require(frame1280x800().pngData(maxDimension: 512))
    let size = try #require(pngSize(png))
    #expect(size.width == 512)   // long edge
    #expect(size.height == 320)
}

@Test func neverUpscalesBeyondSource() throws {
    // maxDimension ≥ the long edge → full-res, not enlarged.
    let png = try #require(frame1280x800().pngData(maxDimension: 4000))
    let size = try #require(pngSize(png))
    #expect(size.width == 1280)
    #expect(size.height == 800)
}

@Test func maxDimensionEqualToLongEdgeIsFullRes() throws {
    // Boundary of the `longEdge > maxDimension` guard: equal → no downscale.
    let png = try #require(frame1280x800().pngData(maxDimension: 1280))
    let size = try #require(pngSize(png))
    #expect(size.width == 1280)
    #expect(size.height == 800)
}

@Test func downscalesPortraitByLongEdge() throws {
    // Long edge is HEIGHT here — exercises the width/height swap the landscape cases don't.
    let tall = SZImageBytes(width: 800, height: 1280, bgra: [UInt8](repeating: 128, count: 800 * 1280 * 4))
    let png = try #require(tall.pngData(maxDimension: 768))
    let size = try #require(pngSize(png))
    #expect(size.height == 768)   // long edge clamped
    #expect(size.width == 480)
}

@Test func tinyMaxDimensionFloorsAtOnePixel() throws {
    // The `max(1, …)` floor must keep the short edge from rounding to 0.
    let png = try #require(frame1280x800().pngData(maxDimension: 1))
    let size = try #require(pngSize(png))
    #expect(size.width == 1)
    #expect(size.height == 1)
}
