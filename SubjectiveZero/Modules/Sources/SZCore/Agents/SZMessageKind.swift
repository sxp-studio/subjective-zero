// SPDX-License-Identifier: AGPL-3.0-only
// THE message vocabulary — one enum the whole orchestration layer speaks. Queue intent,
// message-node port, and delivery record all use this type; there is deliberately no
// second spelling anywhere (the previous architecture kept four parallel string
// vocabularies for this concept, and every seam between them leaked).
import Foundation

/// What one agent message IS. An agent is a mailbox plus graphs; every graph opens at its
/// message node, whose ports are the kinds it accepts, and a delivered message leaves by
/// the port bearing its own name.
public enum SZMessageKind: String, Codable, Sendable, CaseIterable {
    /// One reply on a scope's transcript.
    case chat
    /// Open a fleet thread over the project's work set (the Build press, or a chat turn's
    /// requestBuild effect). Supersedable while queued.
    case build
    /// One dispatched work item, addressed to one agent.
    case item
    /// A dispatch set's single terminal reply, re-entering the sender's graph through its
    /// message node — the reply is a message like any other, delivered to the sender.
    case settled
    /// A structured proxied operation (split/merge …) — routed on its payload, never prose.
    case request
    /// A note folded into the recipient's NEXT brief. The one kind that is never delivered
    /// into a graph: the thread machine drains steers into facts, and conclusion sweeps
    /// leftovers. Its exceptional nature is stated here, once.
    case steer

    /// Kinds a message node may carry a port for — everything except `steer`. Doubles as
    /// the message form's declared outcome set, so "that is not a kind" and "steer may
    /// never be routed" are both refused by the ordinary undeclared-outcome check.
    public static let deliverable: Set<SZMessageKind> =
        [.chat, .build, .item, .settled, .request]

    /// The FACTS lane this message reasons in. A `settled` reply re-reads the same live
    /// build picture one round later — it publishes no facts of its own, renders no brief
    /// of its own, and its effects are the build set's — so it folds into `build`. Every
    /// other kind is its own lane.
    ///
    /// One home, deliberately: the fold used to sit inline in the traversal host, which
    /// left `SZEffectCatalog.cases(kind: "settled")` (empty) reachable from the engine and
    /// would have refused a settled traversal's `captureStatuses`.
    public var lane: SZMessageKind { self == .settled ? .build : self }
}
