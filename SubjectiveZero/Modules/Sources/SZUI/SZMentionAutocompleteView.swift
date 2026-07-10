// SPDX-License-Identifier: AGPL-3.0-only
// The @mention autocomplete — a floating candidate list above the composer while an `@query`
// session is live. Dumb values in (filtered candidates + highlight index), closures out; the panel
// owns filtering/selection, the text-view coordinator owns session detection, and the relay is the
// SwiftUI→AppKit imperative channel that lands a pick in the buffer (same pattern as the canvas's
// scroll-wheel monitor manager: a tiny stable class threaded as a prop).
import SwiftUI
import SZCore

/// A key routed from the text view to the autocomplete while a mention session is active.
enum SZMentionCommand {
    case up, down, commit, dismiss
}

/// The panel's imperative channel into the composer buffer. Held as stable `@State` by the panel;
/// the representable rewires `insertMention` to its coordinator on every update.
@MainActor
public final class SZComposerCommandRelay {
    var insertMention: ((SZMentionCandidate) -> Void)?
    public init() {}
}

struct SZMentionAutocompleteView: View {
    let candidates: [SZMentionCandidate]
    let highlightIndex: Int
    let onHighlight: (Int) -> Void
    let onPick: (SZMentionCandidate) -> Void

    private static let rowHeight: CGFloat = 26
    private static let maxVisibleRows = 6

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        row(candidate, index: index)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: Self.rowHeight * CGFloat(Self.maxVisibleRows) + 8)
            .fixedSize(horizontal: false, vertical: true)   // shrink to fit when fewer rows
            .onChange(of: highlightIndex) {
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(highlightIndex) }
            }
        }
        .frame(width: 260)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(Color(white: 0.09).opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    // Plain Buttons only — nothing here can steal first responder from the composer's text view.
    private func row(_ candidate: SZMentionCandidate, index: Int) -> some View {
        Button { onPick(candidate) } label: {
            HStack(spacing: 7) {
                Image(systemName: candidate.sfSymbol)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14)
                    .foregroundStyle(.secondary)
                Text("@\(candidate.title)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(candidate.subtitle)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(index == highlightIndex ? Color.white.opacity(0.10) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(index)
        .onHover { if $0 { onHighlight(index) } }
    }
}
