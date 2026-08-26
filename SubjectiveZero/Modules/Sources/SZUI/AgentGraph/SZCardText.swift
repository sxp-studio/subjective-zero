// SPDX-License-Identifier: AGPL-3.0-only
// How wide a card's header text draws, measured with the fonts that draw it.
//
// Card sizing is pure and testable, so it cannot ask SwiftUI. Estimating by character count
// instead was wrong by a word on the strings that matter — a title beside a slot chip lost its
// tail to "Implem…". Memoized: this runs per card per layout pass over a handful of titles.
import AppKit
import CoreText

enum SZCardText {
    /// The two header strings, each naming the font that draws it. A case rather than a CTFont
    /// prop because CTFont is not Sendable, and the font is cheap to ask CoreText for.
    enum Style: Hashable {
        case title   // SZNodeCardStyle.titleFont — 12pt semibold
        case chip    // the slot chip — 8pt semibold monospaced

        /// Asked for by WEIGHT, not by name: the UI font at a size is the regular face, and
        /// measuring "Implement" regular under a semibold title is 3pt short — enough to
        /// ellipsize it on a card whose width was otherwise right.
        fileprivate var font: NSFont {
            switch self {
            case .title: .systemFont(ofSize: 12, weight: .semibold)
            case .chip: .monospacedSystemFont(ofSize: 8, weight: .semibold)
            }
        }
    }

    static func titleWidth(_ text: String) -> CGFloat { width(text, style: .title) }

    /// Text only — the chip's own padding belongs to whoever lays the chip out.
    static func chipWidth(_ text: String) -> CGFloat { width(text, style: .chip) }

    private struct Key: Hashable {
        let text: String
        let style: Style
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: CGFloat] = [:]

    static func width(_ text: String, style: Style) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let key = Key(text: text, style: style)
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: style.font]))
        // The typographic ADVANCE, not the inked bounds: what the layout must reserve is where
        // the next element starts, which a trailing space or a glyph overhang changes.
        let measured = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        cache[key] = measured
        return measured
    }
}
