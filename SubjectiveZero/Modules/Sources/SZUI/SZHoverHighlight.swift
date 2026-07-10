// SPDX-License-Identifier: AGPL-3.0-only
// One place for the "brighten under the cursor" boilerplate repeated across the node cards, card
// pills, HUD buttons, and composer controls: track pointer hover into a bound flag and animate the
// change with a standard quick ease. The VISUAL (fill / scale / brightness) stays at each call site
// — only the plumbing is shared.
import SwiftUI

extension View {
    func trackingHover(_ flag: Binding<Bool>, duration: Double = 0.1) -> some View {
        onHover { flag.wrappedValue = $0 }
            .animation(.easeOut(duration: duration), value: flag.wrappedValue)
    }
}
