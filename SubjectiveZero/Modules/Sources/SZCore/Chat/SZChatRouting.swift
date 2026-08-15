// SPDX-License-Identifier: AGPL-3.0-only
// Recipient resolution — THE routing policy seam (docs/AGENT_ORCHESTRATION.md "Message routing").
// One pure function decides which agent receives a message; every send path funnels through it, so
// swapping the policy (or, later, making it data-driven) is an edit here and nowhere else.
//
// V1 policy (design conversation 2026-07-05):
// - A message that LEADS with a mention is addressed to that entity: a node → its Coding Agent,
//   DIRECT (no relay turn inside the tight iterate-on-a-node loop); `@project` / `@all` → the
//   Director Agent (project-wide + broadcast intent both need global context).
// - No leading mention → the active tab's agent (DM-thread semantics: typing in a node's transcript
//   IS addressing that node; requiring `@Blur` inside Blur's own thread would be noise).
// - Non-leading mentions never route — they're references, expanded for the recipient
//   (SZMentionExpansion). A message is NEVER duplicated to multiple Coding Agents: multi-node asks
//   lead with `@project` and the Director Agent reroutes via `ui_send_chat`.
import Foundation

public enum SZChatRouting {
    /// Resolve the agent a message goes to. `activeScope` is the tab the message was composed in —
    /// the fallback recipient when the message doesn't lead with a mention.
    public static func resolveRecipient(message: String, activeScope: SZChatScope) -> SZChatScope {
        switch SZMentionMarkup.leadingMention(in: message) {
        case .node(let id): .node(id)
        case .project, .all: .director
        case nil: activeScope
        }
    }
}
