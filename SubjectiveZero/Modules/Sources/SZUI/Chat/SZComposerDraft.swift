// SPDX-License-Identifier: AGPL-3.0-only
// Composer draft values — the dumb value types the mention-aware composer trades with the host.
// A draft is a segment list (SZCore's SZMessageSegment: literal text + mention tokens); the panel
// edits it as attributed runs, the host receives `canonicalText` (SZMentionMarkup) through the
// unchanged `onSend(String, [URL])` seam, and injects pre-drafted messages (context-menu
// suggestions) as `SZComposerDraftInjection` events.
import Foundation
import SZCore

/// One pickable @mention in the composer autocomplete: the project, every node (broadcast), or a
/// single node. `title` is the display the token freezes at pick time ("project" / "all" / the
/// node's title); the host computes the candidate list from the live graph.
public struct SZMentionCandidate: Identifiable, Equatable, Sendable {
    public let target: SZMentionTarget
    public let title: String
    public let sfSymbol: String
    public let subtitle: String   // what picking it means ("Director Agent" / "Coding Agent" / …)

    public var id: SZMentionTarget { target }

    public init(target: SZMentionTarget, title: String, sfSymbol: String, subtitle: String) {
        self.target = target
        self.title = title
        self.sfSymbol = sfSymbol
        self.subtitle = subtitle
    }
}

/// The composer's content as values: what the text view edits, what suggestions inject, what a
/// send serializes. Mentions stay atomic tokens here; only `canonicalText` flattens them to markup.
public struct SZComposerDraft: Equatable, Sendable {
    public var segments: [SZMessageSegment]

    public init(segments: [SZMessageSegment] = []) { self.segments = segments }

    /// Parse canonical markup back into a draft (injection built host-side, token copy/paste).
    public init(canonicalText: String) { segments = SZMentionMarkup.parse(canonicalText) }

    /// The wire form — mention markup inline (`@[Blur](node:UUID)`), what `onSend` carries.
    public var canonicalText: String { SZMentionMarkup.encode(segments) }

    /// The human-readable form — mentions as `@display` (drives canSend / emptiness).
    public var plainText: String {
        segments.map { segment in
            switch segment {
            case .text(let t): t
            case .mention(_, let display): "@\(display)"
            }
        }.joined()
    }

    public var isEmpty: Bool {
        plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Drop a redundant LEADING `@project` mention (plus the space after it): inside the Project
    /// tab you already address the Director, so seeding "@project …" reads oddly. The message still
    /// routes to the Director (no leading mention → the active Project tab). Non-leading `@project`
    /// or `@all` / node references are untouched.
    public func strippingLeadingProjectMention() -> SZComposerDraft {
        guard case .mention(.project, _)? = segments.first else { return self }
        var rest = Array(segments.dropFirst())
        if case .text(let t)? = rest.first {
            let trimmed = String(t.drop(while: { $0 == " " }))
            if trimmed.isEmpty { rest.removeFirst() } else { rest[0] = .text(trimmed) }
        }
        return SZComposerDraft(segments: rest)
    }
}

/// A host-authored draft landing in the composer (a context-menu suggestion click, the HUD's
/// pending-work beacon). `id` is the event identity — the panel consumes each injection exactly
/// once (`onConsumePendingDraft`), so a re-render can never re-inject over the user's edits.
/// Applied only when the panel shows `scope`. `replacesNonEmpty: false` = a SOFT injection (the
/// beacon): it lands only in an empty composer and is dropped otherwise — an explicit menu pick
/// replaces, a nudge never stomps.
public struct SZComposerDraftInjection: Equatable, Sendable {
    public let id: UUID
    public let scope: SZChatScope
    public let draft: SZComposerDraft
    public let replacesNonEmpty: Bool

    public init(id: UUID = UUID(), scope: SZChatScope, draft: SZComposerDraft,
                replacesNonEmpty: Bool = true) {
        self.id = id
        self.scope = scope
        self.draft = draft
        self.replacesNonEmpty = replacesNonEmpty
    }
}
