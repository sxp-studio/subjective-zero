// SPDX-License-Identifier: AGPL-3.0-only
// PNG encoding for captured frames. Lives with `SZImageBytes` in SZRuntime (it's a graphics concern,
// excluded from SZCore by the no-Metal/graphics rule) — capture + encode stay together, as the type's
// own doc note anticipated ("PNG encoding layers on when a consumer needs it"; e.g. agent_view_frame).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public extension SZImageBytes {
    /// Encode the BGRA8 pixels as PNG, or nil on failure.
    func pngData() -> Data? {
        guard let cgImage = cgImage() else { return nil }
        return Self.encodePNG(cgImage)
    }

    /// Encode as PNG downscaled so the long edge is at most `maxDimension` (never upscales), or nil on
    /// failure. Used by `agent_view_frame` to fit the frame in an agent's token budget — the model is
    /// billed by image dimensions, so a smaller image is a cheaper look.
    func pngData(maxDimension: Int) -> Data? {
        guard let source = cgImage() else { return nil }
        let longEdge = max(width, height)
        guard maxDimension > 0, longEdge > maxDimension else { return Self.encodePNG(source) }
        let scale = Double(maxDimension) / Double(longEdge)
        let w = max(1, Int((Double(width) * scale).rounded()))
        let h = max(1, Int((Double(height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = context.makeImage() else { return nil }
        return Self.encodePNG(scaled)
    }

    /// Wrap the BGRA8 pixels in a `CGImage` (no copy of the byte layout), or nil on failure.
    private func cgImage() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        // BGRA8 little-endian == premultiplied-first ARGB byte order.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// ImageIO-encode a `CGImage` as PNG bytes, or nil on failure.
    private static func encodePNG(_ cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
