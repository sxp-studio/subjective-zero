// SPDX-License-Identifier: AGPL-3.0-only
// The canvas right-click menu — a custom floating card, NOT an NSMenu/.contextMenu, because its
// rows are draft MESSAGES ("what can I say here"), it hosts an inline free-text field (native menus
// can't), and a later pass sends in place from here (same surface, per the run-UX rulings).
// Dumb values in (suggestion rows + action rows + a free-text placeholder), closures out.
//
// Keyboard: ↑/↓ move the highlight across suggestion + action rows, Return activates, Esc
// dismisses (also from inside the free-text field). Suggestion rows are plain Buttons — clickable
// with no prior focus. Glass styling per the HUD recipe.
import SwiftUI

struct SZCanvasContextMenuView: View {
    let suggestions: [SZContextSuggestion]
    let actions: [SZContextAction]
    let freeTextPlaceholder: String
    let onPickSuggestion: (SZContextSuggestion) -> Void
    let onFreeText: (String) -> Void
    let onPickAction: (SZContextAction) -> Void
    let onDismiss: () -> Void

    @State private var highlight: Int?          // index into the flat suggestions+actions order
    @State private var freeText = ""
    @State private var freeTextHover = false    // the free-text row highlights on hover too (not just focus)
    @FocusState private var menuFocused: Bool
    @FocusState private var fieldFocused: Bool

    private var rowCount: Int { suggestions.count + actions.count }
    // Message rows first, then the direct actions — a stable "what can I say / do here" order.
    private var suggestionOffset: Int { 0 }
    private var actionOffset: Int { suggestions.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            suggestionRows
            freeTextRow
            if !actions.isEmpty {
                menuDivider
                actionRows
            }
        }
        .padding(5)
        .frame(width: 264)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background(Color(white: 0.09).opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        // The menu holds focus while open (parks the canvas's Delete/⌫ handling); the caller
        // restores canvas focus on dismiss.
        .focusable()
        .focusEffectDisabled()
        .focused($menuFocused)
        .onAppear { menuFocused = true }
        .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
        .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
        .onKeyPress(.return) { activateHighlight() }
        .onExitCommand { onDismiss() }
    }

    private var menuDivider: some View {
        Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 2)
    }

    private var suggestionRows: some View {
        ForEach(Array(suggestions.enumerated()), id: \.element.id) { offset, suggestion in
            row(index: suggestionOffset + offset, sfSymbol: "bubble.left",
                label: suggestion.label, accented: true) {
                onPickSuggestion(suggestion)
            }
        }
    }

    private var actionRows: some View {
        ForEach(Array(actions.enumerated()), id: \.element.id) { offset, action in
            row(index: actionOffset + offset, sfSymbol: action.sfSymbol,
                label: action.label, accented: false) {
                onPickAction(action)
            }
        }
    }

    private func moveHighlight(_ delta: Int) {
        guard rowCount > 0 else { return }
        highlight = ((highlight ?? (delta > 0 ? -1 : 0)) + delta + rowCount) % rowCount
    }

    private func activateHighlight() -> KeyPress.Result {
        guard let highlight else { return .ignored }
        if highlight >= actionOffset, highlight < actionOffset + actions.count {
            onPickAction(actions[highlight - actionOffset])
            return .handled
        }
        if highlight >= suggestionOffset, highlight < suggestionOffset + suggestions.count {
            onPickSuggestion(suggestions[highlight - suggestionOffset])
            return .handled
        }
        return .ignored
    }

    private func row(index: Int, sfSymbol: String, label: String, accented: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: sfSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 15)
                    .foregroundStyle(accented ? AnyShapeStyle(SZNodeCardStyle.mentionAccent)
                                              : AnyShapeStyle(.secondary))
                Text(label)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(highlight == index ? Color.white.opacity(0.09) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlight = index } }
    }

    /// The "something else…" row — an inline field whose text lands in the composer behind the
    /// target's seeded mention (a trailing send-to-composer glyph appears once there's text).
    private var freeTextRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left")
                .font(.system(size: 11, weight: .medium))
                .frame(width: 15)
                // The SAME full message-accent as the suggestion rows — both are "say something"
                // rows; a dimmer bubble here read as a different (disabled) kind of row.
                .foregroundStyle(SZNodeCardStyle.mentionAccent)
            // Native TextField placeholders can't be styled, so pass an empty prompt and draw our
            // own ITALIC-tertiary placeholder — it reads as an instruction, not pre-typed text.
            TextField("", text: $freeText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($fieldFocused)
                .onSubmit(submitFreeText)
                .overlay(alignment: .leading) {
                    if freeText.isEmpty {
                        Text(freeTextPlaceholder)
                            .font(.system(size: 12).italic())
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                }
            if !freeText.isEmpty {
                Button(action: submitFreeText) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(SZNodeCardStyle.mentionAccent)
                }
                .buttonStyle(.plain)
                .help("Put this in the composer")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        // Highlight on hover OR focus, same weight as the suggestion rows — a row that never
        // reacts to the cursor reads as disabled.
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(fieldFocused || freeTextHover ? Color.white.opacity(0.09) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering in
            freeTextHover = hovering
            if hovering { highlight = nil }   // don't leave a suggestion row co-highlighted
        }
        .onTapGesture { fieldFocused = true }
    }

    private func submitFreeText() {
        let text = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onFreeText(text)
    }
}
