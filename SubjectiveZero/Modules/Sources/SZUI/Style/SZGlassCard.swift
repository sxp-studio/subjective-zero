// SPDX-License-Identifier: AGPL-3.0-only
// The floating glass card the canvas menus wear: thin material over a dark tint, a hairline, a soft
// shadow. One recipe for the context menu, the mention list and the Library panel's field.
import SwiftUI

extension View {
    func szGlassCard(cornerRadius: CGFloat = 10) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(.ultraThinMaterial, in: shape)
            .background(Color(white: 0.09).opacity(0.55), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}
