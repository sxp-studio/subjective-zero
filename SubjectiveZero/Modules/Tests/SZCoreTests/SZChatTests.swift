// SPDX-License-Identifier: AGPL-3.0-only
// The chat transcript ops on SZStore (the shared path for the chat panel + ui_send_chat)
// and the SZChatScope string-key round-trip used by ui_send_chat / debug_chat_transcript.
import Foundation
import Testing
@testable import SZCore

@MainActor
@Test func chatAppendAndStream() {
    let store = SZStore()
    let scope = SZChatScope.node(SZNodeID())

    store.appendChatMessage(SZChatMessage(role: .user, text: "more contrast"), to: scope)
    let assistantID = store.appendChatMessage(SZChatMessage(role: .assistant, text: ""), to: scope)
    store.appendChatText("On ", to: assistantID, in: scope)
    store.appendChatText("it.", to: assistantID, in: scope)

    let messages = store.messages(for: scope)
    #expect(messages.count == 2)
    #expect(messages[0].role == .user)
    #expect(messages[0].text == "more contrast")
    #expect(messages[1].role == .assistant)
    #expect(messages[1].text == "On it.")   // streamed deltas concatenate in order
    // transcripts are scoped — a different scope is empty
    #expect(store.messages(for: .director).isEmpty)
}

@MainActor
@Test func chatRestoreReplacesAllTranscripts() {
    let store = SZStore()
    let nodeKey = SZNodeID().uuidString
    store.appendChatMessage(SZChatMessage(role: .user, text: "pre-restore"), to: .debug)

    store.restoreChat([
        SZChatScope.directorKey: [SZChatMessage(role: .user, text: "restored")],
        nodeKey: [SZChatMessage(role: .assistant, text: "node history")],
    ])

    #expect(store.messages(for: .director).first?.text == "restored")
    #expect(store.chat[nodeKey]?.first?.text == "node history")
    #expect(store.messages(for: .debug).isEmpty)   // one-shot REPLACE, not merge
}

@MainActor
@Test func chatRemoveScopePrunesOnlyThatScope() {
    let store = SZStore()
    let scope = SZChatScope.node(SZNodeID())
    store.appendChatMessage(SZChatMessage(role: .user, text: "bye"), to: scope)
    store.appendChatMessage(SZChatMessage(role: .user, text: "stay"), to: .director)

    store.removeChat(scopeKey: scope.key)
    #expect(store.messages(for: scope).isEmpty)
    #expect(store.chat[scope.key] == nil)   // pruned, not emptied
    #expect(store.messages(for: .director).count == 1)
}

@MainActor
@Test func chatStreamToMissingMessageIsNoOp() {
    let store = SZStore()
    store.appendChatText("ignored", to: UUID(), in: .director)
    #expect(store.messages(for: .director).isEmpty)
}

@Test func chatScopeKeyRoundTrips() {
    let id = SZNodeID()
    #expect(SZChatScope.node(id).key == id.uuidString)
    #expect(SZChatScope.director.key == "director")
    #expect(SZChatScope(key: id.uuidString) == .node(id))
    #expect(SZChatScope(key: "director") == .director)
    #expect(SZChatScope(key: "debug") == .debug)
    #expect(SZChatScope(key: "not-a-uuid") == nil)   // unparseable → nil (MCP boundary surfaces it)
}

// MARK: - Codable (the persisted sidecar shape — append-tolerant by design)

@Test func chatMessageCodableRoundTrip() throws {
    let attachment = SZChatAttachment(
        filename: "ref.png", url: URL(fileURLWithPath: "/tmp/staging/ref.png"),
        bundlePath: "attachments/ABC/ref.png", byteCount: 1234, isImage: true)
    let message = SZChatMessage(role: .assistant, text: "done", thinking: "traced it",
                                duration: 4.2, attachments: [attachment])
    let data = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(SZChatMessage.self, from: data)

    #expect(decoded.id == message.id)
    #expect(decoded.role == .assistant)
    #expect(decoded.text == "done")
    #expect(decoded.thinking == "traced it")
    #expect(decoded.duration == 4.2)
    #expect(decoded.timestamp.timeIntervalSince(message.timestamp).magnitude < 0.001)
    #expect(decoded.attachments.count == 1)
    let a = try #require(decoded.attachments.first)
    #expect(a.id == attachment.id)
    #expect(a.filename == "ref.png")
    #expect(a.bundlePath == "attachments/ABC/ref.png")
    #expect(a.byteCount == 1234)
    #expect(a.isImage)
}

@Test func chatMessageMinimalJSONDecodesWithDefaults() throws {
    // A bare-bones sidecar entry (or one written before optional fields existed) must load.
    let json = Data(#"{"role": "user"}"#.utf8)
    let decoded = try JSONDecoder().decode(SZChatMessage.self, from: json)
    #expect(decoded.role == .user)
    #expect(decoded.text.isEmpty)
    #expect(decoded.thinking.isEmpty)
    #expect(decoded.duration == nil)
    #expect(decoded.attachments.isEmpty)
}

@Test func chatMessageUnknownFieldsIgnored() throws {
    // Forward compat: a sidecar written by a NEWER build (e.g. with a message-origin flag) must
    // decode against this one.
    let json = Data(#"{"role": "assistant", "text": "hi", "origin": "canvas-gesture"}"#.utf8)
    let decoded = try JSONDecoder().decode(SZChatMessage.self, from: json)
    #expect(decoded.role == .assistant)
    #expect(decoded.text == "hi")
}

@Test func chatMessageNilDurationOmitsKey() throws {
    let data = try JSONEncoder().encode(SZChatMessage(role: .user, text: "hey"))
    let raw = String(decoding: data, as: UTF8.self)
    #expect(!raw.contains("\"duration\""))
}

@Test func chatMessageTransientRoundTripsAndDefaultsFalse() throws {
    // Non-transient (the common case) omits the key entirely; transient round-trips; a file
    // written before the field existed decodes as non-transient.
    let plain = String(decoding: try JSONEncoder().encode(SZChatMessage(role: .user, text: "hi")), as: UTF8.self)
    #expect(!plain.contains("transient"))

    let note = SZChatMessage(role: .assistant, text: "(busy)", transient: true)
    let decoded = try JSONDecoder().decode(SZChatMessage.self, from: try JSONEncoder().encode(note))
    #expect(decoded.transient)

    let old = try JSONDecoder().decode(SZChatMessage.self, from: Data(#"{"role":"assistant","text":"OK"}"#.utf8))
    #expect(!old.transient)
}

@Test func chatAttachmentDoesNotEncodeURL() throws {
    // Absolute machine paths must never land in the portable sidecar; the host re-derives `url`
    // from `bundlePath` on restore.
    let attachment = SZChatAttachment(
        filename: "clip.wav", url: URL(fileURLWithPath: "/var/folders/xx/staging/clip.wav"),
        bundlePath: "attachments/DEF/clip.wav", byteCount: 9, isImage: false)
    let raw = String(decoding: try JSONEncoder().encode(attachment), as: UTF8.self)
    #expect(!raw.contains("url"))
    #expect(!raw.contains("/var/folders"))

    let decoded = try JSONDecoder().decode(SZChatAttachment.self, from: Data(raw.utf8))
    #expect(decoded.bundlePath == "attachments/DEF/clip.wav")
    // Dangling placeholder until host fixup — just needs to be derived from bundlePath.
    #expect(decoded.url.path.hasSuffix("attachments/DEF/clip.wav"))
}
