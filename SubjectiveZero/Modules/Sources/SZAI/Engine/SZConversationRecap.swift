// SPDX-License-Identifier: AGPL-3.0-only
// The bytes a cold turn reads ABOVE its brief when its node declares `context: conversation`: the
// scope's prior conversation as `SZWorld.conversation` projects it, labeled and tail-bounded
// (last 20 messages / ~8 KB). Data only — the transcript IS the context, no framing prose
// beyond the one-line header. The seam a future memory system replaces.
import Foundation
import SZCore

public enum SZConversationRecap {
    public static let messageLimit = 20
    public static let characterLimit = 8_000

    /// nil when there is nothing to catch up on.
    public static func render(_ messages: [SZChatMessage],
                              nodes: [(id: SZNodeID, title: String)]) -> String? {
        guard !messages.isEmpty else { return nil }
        let tail = messages.suffix(messageLimit)
        var lines: [String] = []
        if tail.count < messages.count { lines.append("(…\(messages.count - tail.count) earlier turns omitted)") }
        for message in tail {
            // A build's receipt is not something anyone SAID: labelled as the event it is,
            // not as the agent's own prior words.
            let label = if message.receipt != nil { "build" } else {
                switch message.role {
                case .user: "user"
                case .assistant: "assistant"
                case .director: "director agent"
                }
            }
            // Mentions replay as readable `@display`; ONE aggregate manifest below re-expands them.
            lines.append("\(label): \(SZMentionMarkup.plainText(message.text))")
            // Durable attachment copies are readable by absolute path on this machine; staging-only
            // attachments (nil bundlePath) are gone by now and stay unmentioned.
            for attachment in message.attachments where attachment.bundlePath != nil {
                lines.append("[attached: \(attachment.url.path)]")
            }
        }
        if let manifest = SZMentionExpansion.recapManifest(for: tail.map(\.text), nodes: nodes) {
            lines.append("")
            lines.append(manifest)
        }
        var body = lines.joined(separator: "\n")
        if body.count > characterLimit { body = "(…truncated)\n" + String(body.suffix(characterLimit)) }
        return """
        Prior conversation restored from the project (you are a fresh session; catch up from this):
        ---
        \(body)
        ---
        """
    }
}
