// SPDX-License-Identifier: AGPL-3.0-only
// The agent tint palette: pack-declared color NAMES resolved to the app's semantic colors.
// "purple" and "orange" are the Director's flow-edge violet and the coding state's warm
// orange — the same values the chat feed has always used — so a pack claiming them joins
// the app's palette instead of approximating it. Unknown names degrade to nil, never a guess.
import SwiftUI

public enum SZAgentTint {
    public static func color(_ name: String?) -> Color? {
        switch name {
        case "purple": SZEdgeStyle.intentViolet
        case "orange": Color(red: 0.96, green: 0.60, blue: 0.30)
        case "lilac": Color(red: 0.70, green: 0.62, blue: 0.85)
        case "blue": Color(red: 0.50, green: 0.64, blue: 1.0)
        case "green": .green
        case "red": .red
        case "teal": .teal
        case "pink": .pink
        case "yellow": .yellow
        case "gray": .gray
        default: nil
        }
    }
}
