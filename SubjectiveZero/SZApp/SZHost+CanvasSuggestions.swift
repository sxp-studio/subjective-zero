// SPDX-License-Identifier: AGPL-3.0-only
// Canvas context-menu suggestions — the host side of "right-click = what can I say here". Each row
// is a complete DRAFT MESSAGE (mention tokens included) derived from what's under the click; picking
// one (or typing in the free-text row) lands it in the composer via the injection handshake — V1
// ruling: suggestions compose, they never auto-send. Determinism lives downstream in the agent's
// `ui_*` tools (split/merge/run), not in these strings.
import Foundation
import SZCore
import SZUI

extension SZHost {
    /// The suggestion rows for a right-click target. Context-derived, not exhaustive — the menu's
    /// free-text row covers "say anything"; these are the asks the click's context makes obvious.
    func contextSuggestions(for target: SZCanvasContextTarget) -> [SZContextSuggestion] {
        guard let graph = store.project?.graph else { return [] }
        switch target {
        // Row labels are SHORT action phrases (the user sees at a glance what a row will do); the
        // full mention-addressed message only materializes in the composer on pick.
        case .node(let id):
            guard let node = graph.node(id: id) else { return [] }
            var rows: [SZContextSuggestion] = []
            let mention = SZMessageSegment.mention(.node(id), display: Self.mentionTitle(node))
            // A reported blocker becomes a ready-to-send fix request to the node's Coding Agent.
            if let state = nodeAgentState[id], state.phase == .error || state.phase == .needsInput {
                let detail = Self.oneLine(state.errorDetail ?? state.message, cap: 90)
                if !detail.isEmpty {
                    rows.append(SZContextSuggestion(
                        label: "Fix: \(Self.oneLine(detail, cap: 44))",
                        draft: SZComposerDraft(segments: [mention, .text(" fix this: \(detail)")])))
                }
            }
            if node.needsImplementation {
                // A built node whose contract has since moved needs the same work, but the user is looking at a
                // card that still renders — "implement" would read as a lie.
                let rebuild = node.kind == .generated
                rows.append(SZContextSuggestion(
                    label: rebuild ? "Rebuild this node…" : "Implement this node…",
                    draft: SZComposerDraft(segments: [
                        Self.projectMention, .text(rebuild ? " rebuild " : " implement "), mention])))
            } else {
                rows.append(SZContextSuggestion(
                    label: "Split into two stages…",
                    draft: SZComposerDraft(segments: [
                        Self.projectMention, .text(" split "), mention, .text(" into two stages")])))
            }
            return rows
        case .selection(let ids):
            let members = graph.nodes.filter { ids.contains($0.id) }   // graph order, stable
            guard members.count >= 2 else { return [] }
            var segments: [SZMessageSegment] = [Self.projectMention, .text(" merge ")]
            for (index, node) in members.enumerated() {
                if index > 0 { segments.append(.text(index == members.count - 1 ? " and " : ", ")) }
                segments.append(.mention(.node(node.id), display: Self.mentionTitle(node)))
            }
            segments.append(.text(" into one node"))
            return [SZContextSuggestion(label: "Merge these \(members.count) nodes…",
                                        draft: SZComposerDraft(segments: segments))]
        case .canvas:
            let pending = graph.nodes.filter(\.needsImplementation).count
            guard pending > 0 else { return [] }   // free-text "@project …" still covers the canvas
            return [SZContextSuggestion(
                label: "Implement the \(pending) pending node\(pending == 1 ? "" : "s")…",
                draft: SZComposerDraft(segments: [
                    Self.projectMention,
                    .text(" implement the \(pending) pending node\(pending == 1 ? "" : "s")")]))]
        }
    }

    /// A picked suggestion → the composer, on the tab the draft's own routing resolves to.
    func pickContextSuggestion(_ suggestion: SZContextSuggestion) {
        stageComposerDraft(suggestion.draft)
    }

    /// The menu's free-text row → the composer, behind the target's seeded mention (so the recipient
    /// is explicit in the message itself — the menu never relies on implicit routing).
    func contextFreeText(target: SZCanvasContextTarget, text: String) {
        var segments: [SZMessageSegment] = []
        if case .node(let id) = target, let node = store.project?.graph.node(id: id) {
            segments = [.mention(.node(id), display: Self.mentionTitle(node)), .text(" ")]
        } else {
            segments = [Self.projectMention, .text(" ")]
        }
        segments.append(.text(text))
        stageComposerDraft(SZComposerDraft(segments: segments))
    }

    private func stageComposerDraft(_ draft: SZComposerDraft) {
        let scope = SZChatRouting.resolveRecipient(message: draft.canonicalText,
                                                   activeScope: activeChatScope)
        injectComposerDraft(draft, scope: scope)
    }

    private static let projectMention = SZMessageSegment.mention(.project, display: "project")

    private static func mentionTitle(_ node: SZNode) -> String {
        node.title.isEmpty ? "Untitled" : node.title
    }

    /// Collapse a diagnostic to a single capped line so a suggestion row stays a one-liner.
    private static func oneLine(_ text: String, cap: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= cap ? flat : String(flat.prefix(cap)) + "…"
    }
}
