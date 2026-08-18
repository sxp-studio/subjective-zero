// SPDX-License-Identifier: AGPL-3.0-only
// Recipient resolution — THE routing policy seam (docs/AGENT_ORCHESTRATION.md "Message routing").
// One pure function decides which agent receives a message; every send path funnels through it, so
// swapping the policy (or, later, making it data-driven) is an edit here and nowhere else.
//
// Policy (2026-08-18, with the single chat panel): EVERY user message goes to the Director's door,
// which triages it. A mention is no longer an address — it stays in the words as a targeting HINT
// the triage reads, so "@Blur make it softer" is still unambiguous while passing through the one
// thing that schedules work.
//
// Why the direct-to-node lane went: with tasks running concurrently, a message that reached a
// coding agent without passing the Director could mutate a node a scheduled or live task holds —
// it would be fence-refused or race. Routing everything through the scheduler means every mutation
// is claimed, and every conflict is visible to the thing that resolves conflicts. A node question
// still reaches its agent: the Director relays it with `ui_send_chat`.
import Foundation

public enum SZChatRouting {
    /// Resolve the agent a USER message goes to. Always the Director — an agent's own explicit
    /// scope is never re-routed, and never comes through here.
    public static func resolveRecipient(message: String) -> SZChatScope { .director }
}
