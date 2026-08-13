// SPDX-License-Identifier: AGPL-3.0-only
// Drop-target feedback drawn while a wire is being dragged: every socket a drop would legally
// connect to gets a soft ring, and the one the free end is currently snapped to (the releasable
// target) gets a brighter, breathing glow — so "you can land here" and "let go now" read at a
// glance. Purely a world-space overlay owned by SZNodeEditorPanel (a sibling of the wire preview);
// it never touches the frozen socket layer, so it costs nothing on the content subtree. Colored by
// connection kind (violet = flow, blue = data), matching SZPortSocket and the drag preview.
import SwiftUI
import SZCore

struct SZWireTargetHighlight: View {
    let kind: SZConnectionKind
    /// The socket the free end is snapped to right now — the one a drop would connect. Reads as the
    /// call to action (brighter ring + pulsing halo); the rest are calm "compatible" rings.
    var isActiveTarget: Bool = false

    private var color: Color { kind == .flow ? SZEdgeStyle.intentViolet : .blue }
    /// A hair larger than the 12pt socket so the ring hugs the dot without hiding it.
    private var diameter: CGFloat { SZNodeLayout.socketSize + 8 }

    var body: some View {
        if isActiveTarget {
            // Pulse off the SAME shared clock as the status pill / structural-op glow, so every
            // breathing element in the UI swells in lockstep (see SZGraphOpGlow).
            TimelineView(.animation) { ctx in
                let p = SZPulse.phase(at: ctx.date)
                Circle()
                    .stroke(color, lineWidth: 2)
                    .frame(width: diameter, height: diameter)
                    .shadow(color: color.opacity(0.9), radius: 4 + 5 * p)
                    .shadow(color: color.opacity(0.6), radius: 4 + 5 * p)
                    .opacity(0.7 + 0.3 * p)
            }
            .allowsHitTesting(false)
        } else {
            Circle()
                .stroke(color.opacity(0.55), lineWidth: 1.5)
                .frame(width: diameter, height: diameter)
                .allowsHitTesting(false)
        }
    }
}
