// SPDX-License-Identifier: AGPL-3.0-only
// The always-on attention pulse, shared by the node editor (Build badge, graph-op glow) and the chat
// panel (working-tab dot, typing indicator, Stop breathe). Lives in its own file because it is a
// cross-panel primitive — it was defined inside SZNodeEditorPanel while SZChatPanel used it.
import SwiftUI

/// A slow breathing pulse that costs ZERO main-thread frames: a repeatForever animation on OPACITY
/// (CA-animatable) runs entirely on the render server. The `TimelineView(.animation)` shape this
/// replaces re-entered SwiftUI on every display frame for the life of the view — a standing
/// full-window layout flush whose per-flush cost scaled with the canvas zoom (big scaled layers).
/// Use this for any always-on attention pulse; TimelineView stays the tool for FINITE effects.
struct SZPulsingOpacity<Content: View>: View {
    let range: ClosedRange<Double>
    let halfPeriod: TimeInterval
    @ViewBuilder let content: () -> Content
    @State private var bright = false

    var body: some View {
        content()
            .opacity(bright ? range.upperBound : range.lowerBound)
            .onAppear {
                withAnimation(.easeInOut(duration: halfPeriod).repeatForever(autoreverses: true)) {
                    bright = true
                }
            }
    }
}
