// SPDX-License-Identifier: AGPL-3.0-only
// A node socket dot. Both flow and data sockets are circles, told apart by colour (data = blue; flow =
// violet, matching its intent edge); unconnected sockets read lighter, and a port the running build was
// never compiled against is a ring. Sized + placed by SZNodeLayout so the connection layer's edges land
// on them.
import SwiftUI
import SZCore

struct SZPortSocket: View {
    let kind: SZConnectionKind
    var isConnected: Bool = false
    /// The port is declared but the running build was not compiled against it (`SZNode.portsNotInBuild`) —
    /// drawn as a ring, so a dot that carries nothing yet can't be read as one that does. Same size, so
    /// nothing moves when the build lands.
    var notInBuild: Bool = false

    var body: some View {
        Circle()
            .fill(notInBuild ? Color.clear : fill)
            .overlay(outline)
            .frame(width: SZNodeLayout.socketSize, height: SZNodeLayout.socketSize)
    }

    /// A built port keeps the hairline that separates its dot from the card. A port the build has no code
    /// for is the port's own colour with nothing inside — drawn with `strokeBorder` so the ring stays
    /// within the dot's bounds, and left hollow rather than filled with the card's grey, because half of
    /// every socket sits out on the canvas where card grey would read as a solid disc.
    @ViewBuilder private var outline: some View {
        if notInBuild {
            Circle().strokeBorder(fill, lineWidth: 2)
        } else {
            Circle().stroke(Color.black.opacity(0.5), lineWidth: 1)
        }
    }

    private var base: Color { kind == .flow ? SZEdgeStyle.intentViolet : .blue }
    private var fill: Color { isConnected ? base : base.opacity(0.45) }
}
