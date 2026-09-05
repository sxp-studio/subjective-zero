// SPDX-License-Identifier: AGPL-3.0-only
// The bytes a cold turn reads ABOVE its brief when its node declares `context: conversation`: the
// scope's prior conversation as `SZWorld.conversation` projects it, labeled and bounded. The user's
// opening message always rides (it is what the conversation is for), then the tail: the last 20
// messages within ~8 KB, whole messages dropped oldest-first when the budget runs out, and the
// agents' own past replies cut to 600 characters so the budget goes to what the user said. Data
// only — the transcript IS the context, no framing prose beyond the one-line header. The seam a
// future memory system replaces.
import Foundation
import SZCore

public enum SZConversationRecap {
    public static let messageLimit = 20
    public static let characterLimit = 8_000
    /// An assistant's or Director's own past reply is kept to this many characters. User words and
    /// build receipts are never cut: a Director that wrote 3 KB a turn once pushed the user's brief
    /// out of an 8 KB window by turn four and spent the night building the wrong shape.
    public static let narrationLimit = 600

    /// nil when there is nothing to catch up on.
    public static func render(_ messages: [SZChatMessage],
                              nodes: [(id: SZNodeID, title: String)]) -> String? {
        guard !messages.isEmpty else { return nil }
        let brief = messages.first { $0.role == .user }
        let briefBlock = brief.map(block)
        // Newest to oldest over the tail, whole messages, until the budget is spent. The newest
        // block always stays, however large.
        var kept: [(message: SZChatMessage, block: String)] = []
        var spent = briefBlock?.count ?? 0
        for message in messages.suffix(messageLimit).reversed() {
            let rendered = block(message)
            if !kept.isEmpty, spent + rendered.count > characterLimit { break }
            kept.insert((message, rendered), at: 0)
            spent += rendered.count
        }
        // The opening message is pinned only when the tail no longer holds it.
        let pinned = brief.flatMap { first in kept.contains { $0.message.id == first.id } ? nil : first }
        let omitted = messages.count - kept.count - (pinned == nil ? 0 : 1)

        var lines: [String] = []
        if let pinned { lines.append(block(pinned)) }
        if omitted > 0 { lines.append("(…\(omitted) earlier turns omitted)") }
        var body = kept.map(\.block).joined(separator: "\n")
        // One message alone past the budget (a giant paste) is cut from the front, as before.
        if kept.count == 1, body.count > characterLimit {
            body = "(…truncated)\n" + String(body.suffix(characterLimit))
        }
        lines.append(body)
        // Mentions replay as readable `@display`; ONE aggregate manifest below re-expands them.
        let texts = (pinned.map { [$0.text] } ?? []) + kept.map(\.message.text)
        if let manifest = SZMentionExpansion.recapManifest(for: texts, nodes: nodes) {
            lines.append("")
            lines.append(manifest)
        }
        return """
        Prior conversation restored from the project (you are a fresh session; catch up from this):
        ---
        \(lines.joined(separator: "\n"))
        ---
        """
    }

    /// One message as the recap prints it: a role label, the words, and any durable attachment.
    private static func block(_ message: SZChatMessage) -> String {
        // A build's receipt is not something anyone SAID: labelled as the event it is, not as
        // the agent's own prior words. An agent's own reply is cut; the user's never is.
        var text = SZMentionMarkup.plainText(message.text)
        let label: String
        if message.receipt != nil {
            label = "build"
        } else if message.role == .user {
            label = "user"
        } else {
            label = message.role == .director ? "director agent" : "assistant"
            if text.count > narrationLimit { text = String(text.prefix(narrationLimit)) + " […]" }
        }
        var lines = ["\(label): \(text)"]
        // Durable attachment copies are readable by absolute path on this machine; staging-only
        // attachments (nil bundlePath) are gone by now and stay unmentioned.
        for attachment in message.attachments where attachment.bundlePath != nil {
            lines.append("[attached: \(attachment.url.path)]")
        }
        return lines.joined(separator: "\n")
    }
}
