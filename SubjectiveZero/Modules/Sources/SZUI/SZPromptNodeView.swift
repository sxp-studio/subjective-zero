// SPDX-License-Identifier: AGPL-3.0-only
// A prompt (pre-gen) node — an editable, auto-growing rounded text field showing
// the prompt, a flow socket on each side, and a status pill above. Typing commits to the prompt via
// `onCommit` (→ store.updateNode(prompt:)); `onEditingChanged` lets the panel suppress canvas pan while
// the field is focused. Flow sockets are pinned to the card's left/right vertical center via alignment,
// so growth never disturbs them — matching SZNodeLayout's flow position (node center ± width/2).
import SwiftUI
import SZCore

struct SZPromptNodeView: View, Equatable {
    let node: SZNode
    let status: SZNodeStatus
    var isSelected: Bool = false
    var locked: Bool = false
    var showPill: Bool = true
    var errorDetail: String? = nil   // full build diagnostic → clickable error pill (agent failures)
    var autoFocus: Bool = false      // freshly added (＋ / double-click) → open editing + grab the field
    let onCommit: (String) -> Void
    let onEditingChanged: (Bool) -> Void

    /// Value-props-only equality (closures excluded; `position` ignored — the panel positions the card
    /// externally via `.position()`). See SZNodeView's `==` for the rationale; a skipped body also
    /// leaves the field's in-flight `text` / focus state untouched.
    nonisolated static func == (lhs: SZPromptNodeView, rhs: SZPromptNodeView) -> Bool {
        var rnode = rhs.node
        rnode.position = lhs.node.position
        return lhs.node == rnode
            && lhs.status == rhs.status
            && lhs.isSelected == rhs.isSelected
            && lhs.locked == rhs.locked
            && lhs.showPill == rhs.showPill
            && lhs.errorDetail == rhs.errorDetail
    }

    @State private var text: String
    @State private var editing = false   // live TextField only while editing (see body) — idle cards are plain Text
    @State private var cardHover = false   // card hover lift; view-local (per-card), excluded from ==
    @FocusState private var focused: Bool

    private static let cornerRadius: CGFloat = 16

    init(node: SZNode, status: SZNodeStatus, isSelected: Bool = false, locked: Bool = false,
         showPill: Bool = true, errorDetail: String? = nil, autoFocus: Bool = false,
         onCommit: @escaping (String) -> Void, onEditingChanged: @escaping (Bool) -> Void) {
        self.node = node
        self.status = status
        self.isSelected = isSelected
        self.locked = locked
        self.showPill = showPill
        self.errorDetail = errorDetail
        self.autoFocus = autoFocus
        self.onCommit = onCommit
        self.onEditingChanged = onEditingChanged
        _text = State(initialValue: node.prompt ?? "")
    }

    var body: some View {
        // The live TextField exists only WHILE EDITING. An idle prompt card renders plain Text: an
        // AppKit-backed NSTextField per card made every canvas pan/zoom/drag tick re-run AppKit layout
        // for all of them — profiled at 400–700ms main-thread stalls on a 30-node graph, starving the
        // Metal viewport. Tap the text (as before — clicking the text used to focus the field) to edit.
        Group {
            if editing {
                TextField("Describe a visual behavior…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onAppear { focused = true }
            } else {
                Text(text.isEmpty ? "Describe a visual behavior…" : text)
                    .opacity(text.isEmpty ? 0.4 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !locked else { return }
                        text = node.prompt ?? ""   // seed the editing session from the live prompt
                        editing = true
                    }
            }
        }
            .font(.system(size: 13))
            .foregroundStyle(.white.opacity(locked ? 0.6 : 0.92))
            .disabled(locked)              // can't edit a node while an agent is implementing it
            .frame(width: SZNodeLayout.width - 32, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: SZNodeLayout.width)                 // fixed width; height grows with the text
            .background(
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    // Hover changes fill/stroke only, never the shadow — see SZNodeView: animating
                    // shadow(radius:) re-rasterizes each frame and .onHover fires per-card on drags.
                    .fill(cardHover ? SZNodeCardStyle.promptHoverFill : SZNodeCardStyle.promptFill)
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .stroke(isSelected ? SZNodeCardStyle.selectionStroke
                                : (cardHover ? Color.white.opacity(0.22) : SZNodeCardStyle.cardStroke),
                            lineWidth: isSelected ? 1.6 : (cardHover ? 1 : 0.75)))
            .trackingHover($cardHover, duration: 0.12)
            .overlay(alignment: .top) {
                SZNodeBadges(status: status, showPill: showPill, locked: locked, errorDetail: errorDetail)
                    .offset(y: -(SZNodeLayout.statusPillHeight + 4))
            }
            .graphOpGlow(status, cornerRadius: Self.cornerRadius)
            .onChange(of: focused) { _, isFocused in
                onEditingChanged(isFocused)
                if !isFocused {
                    onCommit(text)                 // commit on blur, then fall back to static Text
                    editing = false
                }
            }
            .onChange(of: node.prompt) { _, newValue in
                if !focused { text = newValue ?? "" }   // external edits when not actively typing
            }
            // Freshly added → drop straight into editing; the live TextField's own onAppear grabs
            // the keyboard, so a new node is ready to type into with no extra click.
            .onAppear { if autoFocus, !locked { editing = true } }
    }
}
