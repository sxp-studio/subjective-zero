// SPDX-License-Identifier: AGPL-3.0-only
// Recipient resolution — the routing policy seam (docs/AGENT_ORCHESTRATION.md "Message routing").
// One pure function decides who receives a message and every send path funnels through it, so
// swapping the policy is an edit here and nowhere else.
//
// Policy (2026-08-18, with the single chat panel): every user message goes to the Director's door,
// which triages it. A mention is not an address — it stays in the words as a targeting hint the
// triage reads, so "@Blur make it softer" is still unambiguous while passing through the one thing
// that schedules work. The direct-to-node lane went because with tasks running concurrently, a
// message reaching a coding agent without passing the Director could mutate a node a scheduled or
// live task holds — it would be fence-refused or race. Routing through the scheduler claims every
// mutation and makes every conflict visible to the thing that resolves conflicts. A node question
// still reaches its agent: the Director relays it with `ui_send_chat`.
import Foundation

public enum SZChatRouting {
    /// Resolve the agent a user message goes to. Always the Director — an agent's own explicit
    /// scope is never re-routed, and never comes through here.
    public static func resolveRecipient(message: String) -> SZChatScope { .director }
}
