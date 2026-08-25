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
        #expect(recap.contains("(…5 earlier turns omitted)"))
        #expect(!recap.contains("user: m5\n"))
        #expect(recap.contains("user: m25"))

        let long = [SZChatMessage(role: .user, text: String(repeating: "x", count: 9_000))]
        let clipped = try #require(SZConversationRecap.render(long, nodes: []))
        #expect(clipped.contains("(…truncated)"))
        #expect(clipped.count < 8_200)
    }
}
