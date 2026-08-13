// SPDX-License-Identifier: AGPL-3.0-only
// The shared hover treatment for small icon buttons/links in the chat transcript and Profiler:
// a subtle fill + brightened glyph on hover, dimmed while pressed — so every clickable glyph
// LOOKS clickable before it's clicked. (The HUD's big buttons have their own chrome; this is
// for the tiny inline ones.)
import SwiftUI

struct SZIconHoverStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 3).padding(.vertical, 2)
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(hovering ? 0.10 : 0)))
                .opacity(configuration.isPressed ? 0.55 : 1)
                .onHover { hovering = $0 }
        }
    }
}
