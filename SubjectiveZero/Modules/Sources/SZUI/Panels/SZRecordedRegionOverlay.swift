// SPDX-License-Identifier: AGPL-3.0-only
// While a cropped take rolls, the viewport shows what the file is getting: the region outlined in
// the recording red and everything outside it dimmed (lighter than the framing editor's shade, so
// the live picture stays readable). Never intercepts the mouse.
import SwiftUI
import SZCore

/// The four dim rectangles around a crop rect — shared by the framing editor and the rolling-take
/// overlay. Anchored top-leading at full size by the caller; offsets here are absolute.
struct SZCropShades: View {
    let rect: CGRect
    let size: CGSize
    let opacity: Double

    var body: some View {
        let dim = Color.black.opacity(opacity)
        ZStack(alignment: .topLeading) {
            dim.frame(width: size.width, height: max(rect.minY, 0))
            dim.frame(width: size.width, height: max(size.height - rect.maxY, 0))
                .offset(y: rect.maxY)
            dim.frame(width: max(rect.minX, 0), height: max(rect.height, 0))
                .offset(y: rect.minY)
            dim.frame(width: max(size.width - rect.maxX, 0), height: max(rect.height, 0))
                .offset(x: rect.maxX, y: rect.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

public struct SZRecordedRegionOverlay: View {
    private let picture: (width: Int, height: Int)
    private let crop: SZRect

    public init(picture: (width: Int, height: Int), crop: SZRect) {
        self.picture = picture
        self.crop = crop
    }

    public var body: some View {
        GeometryReader { proxy in
            let fit = SZRecordFramingOverlay.pictureRect(picture: picture, in: proxy.size)
            let rect = CGRect(x: fit.minX + crop.x * fit.width,
                              y: fit.minY + crop.y * fit.height,
                              width: crop.width * fit.width,
                              height: crop.height * fit.height)
            ZStack(alignment: .topLeading) {
                SZCropShades(rect: rect, size: proxy.size, opacity: 0.35)
                Rectangle()
                    .strokeBorder(Color.red.opacity(0.8), lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}
