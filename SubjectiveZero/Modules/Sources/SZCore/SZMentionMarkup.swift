// SPDX-License-Identifier: AGPL-3.0-only
// @mention substrate — the canonical inline markup mentions live as inside stored chat text
// (docs/UI.md "Mentions"). A mention addresses a graph ENTITY (`@project`, `@all`, a node by title);
// routing resolves the entity to its agent (SZChatRouting). The markup is markdown-link-shaped —
// `@[Blur](node:UUID)` — so a renderer that knows nothing about mentions still shows something sane,
// and the stored form is self-describing: transcripts stay portable with no side-table of ranges.
// Display text is frozen at pick time (what the user actually said); the CURRENT title is resolved
// at render / expansion time by whoever holds the graph.
import Foundation

/// The entity a mention addresses. Stable ids, not display titles — titles drift, ids don't.
public enum SZMentionTarget: Hashable, Sendable {
    /// The project as a whole — routed to the project's Director Agent.
    case project
    /// Every node in the graph (broadcast INTENT — routed to the Director Agent, which fans out;
    /// never N parallel sends). Expansion enumerates the node set at egress time.
    case all
    case node(SZNodeID)

    /// The canonical target string inside the markup parens: `project`, `all`, or `node:<uuid>`.
    public var key: String {
        switch self {
        case .project: "project"
        case .all: "all"
        case .node(let id): "node:\(id.uuidString)"
        }
    }

    /// Parse a target string. nil for anything unrecognized — the parser degrades that markup to
    /// literal text instead of guessing.
    public init?(key: String) {
        if key == "project" {
            self = .project
        } else if key == "all" {
            self = .all
        } else if key.hasPrefix("node:"), let id = SZNodeID(uuidString: String(key.dropFirst(5))) {
            self = .node(id)
        } else {
            return nil
        }
    }
}

/// One run of a chat message: literal text, or a mention token.
public enum SZMessageSegment: Equatable, Sendable {
    case text(String)
    /// `display` is the title as picked (WITHOUT the leading `@`); rendered as `@display`.
    case mention(SZMentionTarget, display: String)
}

/// Encode/parse the canonical mention markup. Pure functions — no graph, no UI.
public enum SZMentionMarkup {
    /// `@[Blur](node:UUID)` — see header. Display text is sanitized so it can't break the markup.
    public static func encode(_ segments: [SZMessageSegment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let text): text
            case .mention(let target, let display):
                "@[\(sanitizedDisplay(display))](\(target.key))"
            }
        }.joined()
    }

    /// Parse stored text into segments. Malformed or unknown-target markup degrades to literal
    /// text (never dropped, never guessed); adjacent text runs are merged.
    public static func parse(_ text: String) -> [SZMessageSegment] {
        var segments: [SZMessageSegment] = []
        var pendingText = ""
        var rest = Substring(text)

        func flushText() {
            if !pendingText.isEmpty { segments.append(.text(pendingText)); pendingText = "" }
        }

        while let at = rest.range(of: "@[") {
            // A candidate token: @[display](target) with no newline inside the display.
            if let displayEnd = rest.range(of: "](", range: at.upperBound..<rest.endIndex),
               let targetEnd = rest[displayEnd.upperBound...].firstIndex(of: ")"),
               case let display = String(rest[at.upperBound..<displayEnd.lowerBound]),
               !display.contains("\n"),
               let target = SZMentionTarget(key: String(rest[displayEnd.upperBound..<targetEnd])) {
                pendingText += rest[rest.startIndex..<at.lowerBound]
                flushText()
                segments.append(.mention(target, display: display))
                rest = rest[rest.index(after: targetEnd)...]
            } else {
                // Not a valid token — keep the literal "@[" and continue scanning after it.
                pendingText += rest[rest.startIndex..<at.upperBound]
                rest = rest[at.upperBound...]
            }
        }
        pendingText += rest
        flushText()
        return segments
    }

    /// The mentions in a stored message, in order.
    public static func mentions(in text: String) -> [SZMentionTarget] {
        parse(text).compactMap {
            if case .mention(let target, _) = $0 { return target } else { return nil }
        }
    }

    /// The mention a message OPENS with (only whitespace text may precede it) — the recipient
    /// under the leading-mention routing policy. nil when the message doesn't lead with one.
    public static func leadingMention(in text: String) -> SZMentionTarget? {
        for segment in parse(text) {
            switch segment {
            case .text(let t):
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            case .mention(let target, _):
                return target
            }
        }
        return nil
    }

    /// The human-readable form of stored text — mentions as `@display`, markup stripped. What a
    /// plain-text surface (window title, notification, log line) should show.
    public static func plainText(_ text: String) -> String {
        parse(text).map { segment in
            switch segment {
            case .text(let t): t
            case .mention(_, let display): "@\(display)"
            }
        }.joined()
    }

    /// Display text can't contain the markup's own delimiters or newlines.
    private static func sanitizedDisplay(_ display: String) -> String {
        display
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "](", with: "] (")
    }
}
