// SPDX-License-Identifier: AGPL-3.0-only
// The visual cue for edge auto-pan: a soft gradient band on each active edge, ported from the
// shipping editor's EdgePanIndicatorView. Band width/opacity scale with sqrt(intensity) to counter
// the quadratic ramp — the cue appears as soon as panning starts instead of only near the edge.
import SwiftUI

struct SZEdgePanIndicatorView: View {
    let edges: SZEdgeAutoPan.Intensities

    var body: some View {
        ZStack {
            band(edges.left, at: .leading, from: .leading, to: .trailing)
            band(edges.right, at: .trailing, from: .trailing, to: .leading)
            band(edges.top, at: .top, from: .top, to: .bottom)
            band(edges.bottom, at: .bottom, from: .bottom, to: .top)
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: edges)
    }

    private func band(_ intensity: CGFloat, at edge: Alignment,
                      from start: UnitPoint, to end: UnitPoint) -> some View {
        let strength = sqrt(intensity)
        let horizontal = edge == .leading || edge == .trailing
        return LinearGradient(colors: [Color.accentColor.opacity(0.25 * strength), .clear],
                              startPoint: start, endPoint: end)
            .frame(width: horizontal ? SZEdgeAutoPan.zone * strength : nil,
                   height: horizontal ? nil : SZEdgeAutoPan.zone * strength)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge)
    }
}
