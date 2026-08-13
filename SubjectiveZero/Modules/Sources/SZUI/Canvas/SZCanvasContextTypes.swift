// SPDX-License-Identifier: AGPL-3.0-only
// Canvas context-menu values — the dumb rows the custom right-click menu renders. The menu never
// computes rows: the host derives suggestions (drafted MESSAGES, per the run-UX paradigm — the
// menu is "what can I say here"), the panel assembles the action rows from its own inputs, and
// every activation routes back through closures.
import CoreGraphics
import Foundation
import SZCore

/// What was under the right-click: a single node, the current multi-selection (the clicked node is
/// a member), or empty canvas (project-wide).
public enum SZCanvasContextTarget: Equatable, Sendable {
    case node(SZNodeID)
    case selection(Set<SZNodeID>)
    case canvas
}

/// One suggestion row — a complete draft message (mention tokens included). Clicking it lands the
/// draft in the composer (V1 ruling: compose, never auto-send). `label` is the row's one-line
/// preview (usually the draft's plainText).
public struct SZContextSuggestion: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let label: String
    public let draft: SZComposerDraft

    public init(id: UUID = UUID(), label: String? = nil, draft: SZComposerDraft) {
        self.id = id
        self.label = label ?? draft.plainText
        self.draft = draft
    }
}

/// One open right-click menu: the target under the click, the click point (panel space), and the
/// suggestion rows SNAPSHOTTED at open (mid-run promotes don't reshuffle an open menu).
struct SZContextMenuSession: Identifiable {
    let id = UUID()
    let target: SZCanvasContextTarget
    let anchor: CGPoint
    let suggestions: [SZContextSuggestion]

    /// Shift-clamped placement: the menu opens at the click point and slides inward near the
    /// right/bottom edges (8pt margin), NSMenu-like.
    func origin(menuSize: CGSize, in viewSize: CGSize) -> CGPoint {
        CGPoint(x: max(8, min(anchor.x, viewSize.width - menuSize.width - 8)),
                y: max(8, min(anchor.y, viewSize.height - menuSize.height - 8)))
    }

    func frame(menuSize: CGSize, in viewSize: CGSize) -> CGRect {
        CGRect(origin: origin(menuSize: menuSize, in: viewSize), size: menuSize)
    }
}

/// A plain (non-message) action row: open transcript / open Node.swift / add a node here. Distinct
/// glyphs on purpose — bubble = say something, transcript glyph = read, doc = the source file,
/// plus = a direct structural edit (the deterministic node add, not a message).
public struct SZContextAction: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case openTranscript(SZNodeID), openSource(SZNodeID), addNode
    }
    public let kind: Kind
    public let label: String
    public let sfSymbol: String

    public var id: String { label }

    public init(kind: Kind, label: String, sfSymbol: String) {
        self.kind = kind
        self.label = label
        self.sfSymbol = sfSymbol
    }
}
