// SPDX-License-Identifier: AGPL-3.0-only
// A node socket dot. Both flow and data sockets are circles, told apart by colour (data = blue; flow =
// violet, matching its intent edge); unconnected sockets read lighter. Sized + placed by SZNodeLayout so
// the connection layer's edges land on them.
import SwiftUI
import SZCore

struct SZPortSocket: View {
    let kind: SZConnectionKind
    var isConnected: Bool = false

    var body: some View {
        Circle()
            .fill(fill)
            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
            .frame(width: SZNodeLayout.socketSize, height: SZNodeLayout.socketSize)
    }

    private var base: Color { kind == .flow ? SZEdgeStyle.intentViolet : .blue }
    private var fill: Color { isConnected ? base : base.opacity(0.45) }
}
