// SPDX-License-Identifier: AGPL-3.0-only
// A lightweight hover tooltip for the node-card buttons. The system `.help()` tooltip is unreliable for
// views inside the editor canvas because an ancestor applies `.scaleEffect(zoom)` (SZNodeEditorPanel) —
// so we draw our own little capsule on hover. Driven by `.onHover`, which fires here (the same reason the
// buttons are clickable), with a short delay so it doesn't flash while the cursor passes over.
import SwiftUI

struct SZHoverTip: ViewModifier {
    let text: String
    @State private var hovering = false
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .onHover { h in
                hovering = h
                if h {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        if hovering { show = true }   // still hovering after the delay → reveal
                    }
                } else {
                    show = false
                }
            }
            .overlay(alignment: .top) {
                if show {
                    Text(text)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .fixedSize()                          // never wrap/clip; extend past the small button
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color(white: 0.12)))
                        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                        .offset(y: -22)                       // float just above the button
                        .allowsHitTesting(false)              // never intercept the click it describes
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(.easeOut(duration: 0.12), value: show)
    }
}

extension View {
    /// A small hover tooltip that works inside the zoomable canvas (where system `.help()` is flaky).
    func hoverTip(_ text: String) -> some View { modifier(SZHoverTip(text: text)) }
}
