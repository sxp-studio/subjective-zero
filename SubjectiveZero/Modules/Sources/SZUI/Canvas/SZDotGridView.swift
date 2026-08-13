// SPDX-License-Identifier: AGPL-3.0-only
// The node canvas's dotted background grid. Drawn in SCREEN space (a sibling of the transformed
// content layer, not inside it): a world grid point at k·pitch lands at k·(pitch·zoom) + offset, so
// tiling dots at `pitch·zoom` starting from `offset mod spacing` tracks pan/zoom exactly while dot
// radius stays constant on screen (no scaleEffect blur) and the grid is infinite for free. Purely
// decorative — the caller disables hit testing so the background's tap/marquee gestures keep working.
import SwiftUI

struct SZDotGridView: View {
    let zoom: CGFloat
    let offset: CGSize

    /// The node canvas background tone. Shared so the cursor-trail overlay can knock base dots out from
    /// under its glyphs by painting this exact colour (that trick assumes a flat, opaque background).
    static let canvasBackground = Color(white: 0.09)

    var body: some View {
        Canvas { context, size in
            let spacing = Self.effectiveSpacing(pitch: SZNodeLayout.gridPitch, zoom: zoom)
            let phaseX = Self.phase(offset: offset.width, spacing: spacing)
            let phaseY = Self.phase(offset: offset.height, spacing: spacing)
            var dots = Path()
            var y = phaseY - spacing   // one row/column beyond each edge so dots never pop at borders
            while y < size.height + spacing {
                var x = phaseX - spacing
                while x < size.width + spacing {
                    dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    x += spacing
                }
                y += spacing
            }
            context.fill(dots, with: .color(.white.opacity(0.16)))
        }
    }

    /// On-screen spacing between dots: the world pitch scaled by zoom, then doubled (Figma-style)
    /// until it clears `minSpacing` — bounding dot density however far the canvas zooms out.
    static func effectiveSpacing(pitch: CGFloat, zoom: CGFloat, minSpacing: CGFloat = 16) -> CGFloat {
        var spacing = pitch * max(zoom, 0.1)
        while spacing < minSpacing { spacing *= 2 }
        return spacing
    }

    /// Screen position of the first grid line, in [0, spacing) — the pan offset wrapped into one tile.
    static func phase(offset: CGFloat, spacing: CGFloat) -> CGFloat {
        let p = offset.truncatingRemainder(dividingBy: spacing)
        return p < 0 ? p + spacing : p
    }
}
