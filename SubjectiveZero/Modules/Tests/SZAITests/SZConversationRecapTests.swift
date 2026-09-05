// SPDX-License-Identifier: AGPL-3.0-only
// The bytes a cold turn reads above its brief: labels by role (a build's receipt is an event,
// not the agent's words), durable attachments by path, one aggregate mention manifest, and the
// tail bounds. Pinned here because the app used to own this text and the move must not move it.
import Foundation
import Testing
import SZCore
@testable import SZAI

struct SZConversationRecapTests {

    @Test func nothingToCatchUpOnIsNil() {
        #expect(SZConversationRecap.render([], nodes: []) == nil)
    }

    @Test func everySpeakerIsLabelledAndABuildIsAnEvent() throws {
        let receipt = SZChatReceipt(label: "built Warm Orange", conclusion: .ended)
        let recap = try #require(SZConversationRecap.render([
            SZChatMessage(role: .user, text: "warm it up"),
            SZChatMessage(role: .assistant, text: "on it"),
            SZChatMessage(role: .director, text: "scheduling"),
            SZChatMessage(role: .assistant, text: "built Warm Orange", receipt: receipt),
        ], nodes: []))
        #expect(recap == """
        Prior conversation restored from the project (you are a fresh session; catch up from this):
        ---
        user: warm it up
        assistant: on it
        director agent: scheduling
        build: built Warm Orange
        ---
        """)
    }

    @Test func onlyDurableAttachmentsAreNamed() throws {
        let durable = SZChatAttachment(filename: "ref.png", url: URL(filePath: "/tmp/ref.png"),
                                       bundlePath: "attachments/ref.png", byteCount: 1, isImage: true)
        let staging = SZChatAttachment(filename: "gone.png", url: URL(filePath: "/tmp/gone.png"),
                                       byteCount: 1, isImage: true)
        let recap = try #require(SZConversationRecap.render(
            [SZChatMessage(role: .user, text: "like this", attachments: [durable, staging])], nodes: []))
        #expect(recap.contains("[attached: /tmp/ref.png]"))
        #expect(!recap.contains("gone.png"))
    }

    @Test func mentionsReplayInlineWithOneManifest() throws {
        let node = SZNodeID()
        let text = SZMentionMarkup.encode([.text("tweak "), .mention(.node(node), display: "Glow")])
        let recap = try #require(SZConversationRecap.render(
            [SZChatMessage(role: .user, text: text), SZChatMessage(role: .user, text: text)],
            nodes: [(id: node, title: "Glow")]))
        #expect(recap.contains("user: tweak @Glow"))
        #expect(recap.components(separatedBy: "Mentioned in the conversation above:").count == 2)
    }

    @Test func theTailIsBoundedByMessagesAndCharacters() throws {
        let many = (1...25).map { SZChatMessage(role: .user, text: "m\($0)") }
        let recap = try #require(SZConversationRecap.render(many, nodes: []))
        // The opening message rides above the cut; the four between it and the tail are omitted.
        #expect(recap.hasPrefix("""
        Prior conversation restored from the project (you are a fresh session; catch up from this):
        ---
        user: m1
        (…4 earlier turns omitted)
        user: m6
        """))
        #expect(!recap.contains("user: m5\n"))
        #expect(recap.contains("user: m25"))

        let long = [SZChatMessage(role: .user, text: String(repeating: "x", count: 9_000))]
        let clipped = try #require(SZConversationRecap.render(long, nodes: []))
        #expect(clipped.contains("(…truncated)"))
        #expect(clipped.count < 8_200)
    }

    /// The character budget drops WHOLE older messages, never shears one in half: a sheared
    /// message lost its label and its first words, and the shear once ate the user's brief.
    @Test func theCharacterBudgetDropsWholeOlderMessages() throws {
        let many = (1...30).map { SZChatMessage(role: .user, text: String(repeating: "y", count: 600) + "\($0)") }
        let recap = try #require(SZConversationRecap.render(many, nodes: []))
        #expect(!recap.contains("(…truncated)"))
        #expect(recap.contains("user: yyy"))
        #expect(recap.contains("y1\n(…"))                       // the brief, then the omission header
        #expect(recap.contains("y30\n"))                         // the newest message, whole
        let kept = recap.components(separatedBy: "user: ").count - 1
        #expect(kept < 20 && kept > 8)                           // budget-bound, not message-bound
        #expect(recap.contains("(…\(30 - kept) earlier turns omitted)"))
        #expect(recap.count < 8_800)
    }

    /// The first thing the user said is what the conversation is for. It stays in view with its
    /// attachment when the tail has long moved past it, and is not repeated while the tail holds it.
    @Test func theOpeningMessageIsPinnedAboveTheTailWithItsAttachment() throws {
        let photo = SZChatAttachment(filename: "wall.jpg", url: URL(filePath: "/tmp/wall.jpg"),
                                     bundlePath: "attachments/wall.jpg", byteCount: 1, isImage: true)
        let brief = SZChatMessage(role: .user, text: "projection mapping on this wall", attachments: [photo])
        var messages = [brief]
        for i in 1...29 { messages.append(SZChatMessage(role: i.isMultiple(of: 2) ? .assistant : .user, text: "t\(i)")) }
        let recap = try #require(SZConversationRecap.render(messages, nodes: []))
        #expect(recap.contains("user: projection mapping on this wall\n[attached: /tmp/wall.jpg]\n(…9 earlier turns omitted)"))
        #expect(recap.components(separatedBy: "projection mapping").count == 2)

        let short = try #require(SZConversationRecap.render(Array(messages.prefix(3)), nodes: []))
        #expect(short.components(separatedBy: "projection mapping").count == 2)
        #expect(!short.contains("omitted"))
    }

    /// The budget is spent on the user's words: an agent's own past reply is cut, the user's and a
    /// build's never are.
    @Test func anAgentsOwnPastReplyIsCutAndTheUsersIsNot() throws {
        let long = String(repeating: "z", count: 2_000)
        let recap = try #require(SZConversationRecap.render([
            SZChatMessage(role: .user, text: long),
            SZChatMessage(role: .assistant, text: long),
            SZChatMessage(role: .director, text: long),
            SZChatMessage(role: .assistant, text: long, receipt: SZChatReceipt(label: long, conclusion: .ended)),
        ], nodes: []))
        #expect(recap.contains("user: " + long + "\n"))
        #expect(recap.contains("assistant: " + String(repeating: "z", count: 600) + " […]\n"))
        #expect(recap.contains("director agent: " + String(repeating: "z", count: 600) + " […]\n"))
        #expect(recap.contains("build: " + long + "\n"))
    }

    @Test func aRunReplaysInOrderWithItsReceipt() throws {
        let receipt = SZChatReceipt(label: "built Warm Orange", conclusion: .ended)
        let recap = try #require(SZConversationRecap.render([
            SZChatMessage(role: .user, text: "warm it up"),
            SZChatMessage(role: .assistant, text: "adding a tint", graphRunID: UUID()),
            SZChatMessage(role: .assistant, text: "done"),
            SZChatMessage(role: .assistant, text: "built Warm Orange", receipt: receipt),
        ], nodes: []))
        #expect(recap.contains("user: warm it up\nassistant: adding a tint\nassistant: done\nbuild: built Warm Orange"))
    }
}
