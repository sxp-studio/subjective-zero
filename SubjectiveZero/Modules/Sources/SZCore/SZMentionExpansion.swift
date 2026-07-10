// SPDX-License-Identifier: AGPL-3.0-only
// Mention expansion — what a real CLI agent receives in place of mention markup. Every egress to an
// agent (a live send AND the cold-start transcript recap) runs the same expansion, so a mention
// works identically on a fresh session as on a live one. Inline, a mention reads as `@display`
// (frozen — what the user actually said); a trailing manifest resolves each mentioned entity
// against the CURRENT graph (uuid + live title), which is what makes a mention actionable via the
// MCP tools. Mirrors the attachment-manifest pattern (SZHost.attachmentManifest).
import Foundation

public enum SZMentionExpansion {
    /// The agent-facing form of stored message text: markup → `@display` inline, plus a manifest
    /// resolving each mentioned entity. `nodes` is the live graph's (id, title) list, in graph
    /// order — used to resolve current titles, flag deleted nodes, and enumerate what `@all`
    /// means at THIS moment (a recap replays that snapshot honestly).
    public static func agentText(_ text: String, nodes: [(id: SZNodeID, title: String)]) -> String {
        let segments = SZMentionMarkup.parse(text)
        let inline = SZMentionMarkup.plainText(text)
        let lines = manifestLines(for: segments, nodes: nodes)
        guard !lines.isEmpty else { return inline }
        return inline + "\n\nMentioned in this message:\n" + lines.joined(separator: "\n")
    }

    /// The recap's aggregate manifest: one block resolving every DISTINCT entity mentioned across
    /// the replayed messages (per-message manifests would bloat a 20-message replay). nil when the
    /// conversation holds no mentions.
    public static func recapManifest(for texts: [String], nodes: [(id: SZNodeID, title: String)]) -> String? {
        let segments = texts.flatMap { SZMentionMarkup.parse($0) }
        let lines = manifestLines(for: segments, nodes: nodes)
        guard !lines.isEmpty else { return nil }
        return "Mentioned in the conversation above:\n" + lines.joined(separator: "\n")
    }

    /// One manifest line per DISTINCT mentioned entity, in first-mention order.
    private static func manifestLines(
        for segments: [SZMessageSegment], nodes: [(id: SZNodeID, title: String)]
    ) -> [String] {
        var seen = Set<SZMentionTarget>()
        var lines: [String] = []
        for case .mention(let target, let display) in segments where seen.insert(target).inserted {
            switch target {
            case .project:
                lines.append("- @\(display) → this project as a whole")
            case .all:
                let enumerated = nodes.isEmpty
                    ? "(the graph has no nodes)"
                    : nodes.map { "\($0.id.uuidString) (\"\($0.title)\")" }.joined(separator: ", ")
                lines.append("- @\(display) → every node in the graph: \(enumerated)")
            case .node(let id):
                if let current = nodes.first(where: { $0.id == id }) {
                    lines.append("- @\(display) → node \(id.uuidString) (current title \"\(current.title)\")")
                } else {
                    lines.append("- @\(display) → node \(id.uuidString) (no longer in the graph)")
                }
            }
        }
        return lines
    }
}
