// SPDX-License-Identifier: AGPL-3.0-only
// Shared typography + palette for the node-card family (card, inline port controls, status pills) —
// the single place the card look is tuned. Two deliberate tiers: proportional semibold = identity
// (the title, scanned across a zoomed-out graph), monospaced = data (port labels, values, status).
// Geometry lives in SZNodeLayout (which stays SwiftUI-free for headless tests); this is the paint.
import SwiftUI

enum SZNodeCardStyle {
    // Identity tier — proportional scans faster and truncates later at the fixed card width.
    static let titleFont = Font.system(size: 12, weight: .semibold)

    // Data tier — monospaced throughout.
    static let labelFont = Font.system(size: 10, design: .monospaced)
    static let valueFont = Font.system(size: 9, design: .monospaced)
    static let chevronFont = Font.system(size: 7, weight: .bold, design: .monospaced)
    static let pillFont = Font.system(size: 9, weight: .semibold, design: .monospaced)

    static let cardFill = Color(white: 0.16)
    static let cardHoverFill = Color(white: 0.20)   // card / action-pill fill under the cursor
    static let cardStroke = Color.white.opacity(0.12)
    static let previewPlaceholderFill = Color.black.opacity(0.35)   // thumb well before the first frame
    static let previewCornerRadius: CGFloat = 6                     // thumb rounding inside a card body
    static let selectionStroke = Color.cyan.opacity(0.9)
    /// The user/mention accent — the chat panel's user blue, shared by composer mention tokens,
    /// transcript mention chips, and the context menu's suggestion glyphs (one voice = one color).
    static let mentionAccent = Color(red: 0.50, green: 0.64, blue: 1.0)
    // Prompt cards read deliberately lighter than generated cards — a draft, not a machine.
    static let promptFill = Color(white: 0.22)
    static let promptHoverFill = Color(white: 0.26)   // prompt card fill under the cursor
    static let labelColor = Color.white.opacity(0.7)
    // Values read brighter than labels — they're the content; .secondary was too dim on the dark card.
    static let valueColor = Color.white.opacity(0.9)
    // Read-only numbers share the editable wells' shape; dimmer text is what says "not yours to type in".
    static let readOnlyValueColor = Color.white.opacity(0.55)
    static let chipFill = Color.white.opacity(0.08)

    // Keyboard-editable fields read as inset WELLS (darker fill, hairline border, square-ish corners) —
    // distinct from the raised capsule chips, which are pick-from-a-list (dropdowns) or read-only.
    static let fieldFill = Color.black.opacity(0.28)
    static let fieldStroke = Color.white.opacity(0.14)
    static let fieldCornerRadius: CGFloat = 5
}
