// SPDX-License-Identifier: AGPL-3.0-only
// THE message vocabulary — one enum the whole orchestration layer speaks. Queue intent,
// graph kind, entry key, and delivery record all use this type; there is deliberately no
// second spelling anywhere (the previous architecture kept four parallel string
// vocabularies for this concept, and every seam between them leaked).
import Foundation

/// What one agent message IS. An agent is a mailbox plus graphs; every graph declares which
/// kinds it handles, and a delivered message enters the handling graph at that kind's entry.
public enum SZMessageKind: String, Codable, Sendable, CaseIterable {
    /// One reply on a scope's transcript.
    case chat
    /// Open a fleet thread over the project's work set (the Build press, or a chat turn's
    /// requestBuild effect). Supersedable while queued.
    case build
    /// One dispatched work item, addressed to one agent.
    case item
    /// A dispatch set's single terminal reply, re-entering the sender's graph.
    case settled
    /// A structured proxied operation (split/merge …) — routed on its payload, never prose.
    case request
    /// A note folded into the recipient's NEXT brief. The one kind that never enters a
    /// graph: the thread machine drains steers into facts, and conclusion sweeps leftovers.
    /// Its exceptional nature is stated here, once.
    case steer

    /// Kinds a graph may declare an entry for. Everything except `steer`.
    public static let graphEntryKinds: Set<SZMessageKind> =
        [.chat, .build, .item, .settled, .request]
}
