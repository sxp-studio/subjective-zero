// SPDX-License-Identifier: AGPL-3.0-only
// THE message vocabulary — one enum the whole orchestration layer speaks. Queue intent,
// message-node port, and delivery record all use this type; there is deliberately no
// second spelling anywhere (the previous architecture kept four parallel string
// vocabularies for this concept, and every seam between them leaked).
import Foundation

/// What one agent message IS. An agent is a mailbox plus graphs; every graph opens at its
/// message node, whose ports are the kinds it accepts, and a delivered message leaves by
/// the port bearing its own name — then flows through the graph to ITS OWN conclusion.
/// One message, one traversal, one record; nothing re-enters. (The fleet's reply used to
/// be a fifth kind, `settled`, re-entering the sender's graph as a second traversal — that
/// era's dispatch concluded on send. A dispatch now waits for its set, so the reply is the
/// dispatch node's own outcome, not a message.)
public enum SZMessageKind: String, Codable, Sendable, CaseIterable {
    /// Human prose — ONE kind for everything someone says, whoever they say it to. What a
    /// message MEANS is not a kind: the graph rules on content (the triage ask), so "answer
    /// me" and "build this" arrive identically and part ways inside the picture.
    case message
    /// The granted build — machine provenance, minted when a run is actually started (the
    /// Build press, or a `message` whose triage ruled `implement`). Carries the standing
    /// instruction into the build lane. Supersedable while queued.
    case build
    /// One dispatched unit of a run's work set — a node's coding assignment, addressed to
    /// the seat that implements it.
    case work
    /// A structured proxied operation (split/merge …) — routed on its payload, never prose.
    case request
    /// A note folded into the recipient's NEXT brief. The one kind that is never delivered
    /// into a graph: the host drains steers into facts, and conclusion sweeps leftovers.
    /// Its exceptional nature is stated here, once.
    case steer

    /// Kinds a message node may carry a port for — everything except `steer`. Doubles as
    /// the message form's declared outcome set, so "that is not a kind" and "steer may
    /// never be routed" are both refused by the ordinary undeclared-outcome check.
    public static let deliverable: Set<SZMessageKind> =
        [.message, .build, .work, .request]
}
