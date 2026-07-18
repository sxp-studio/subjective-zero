// SPDX-License-Identifier: AGPL-3.0-only
// The queue sidecar's redelivery contract: .chat-only, .delivering reloads as .queued
// (at-least-once), terminal states and steers never persist, tolerant loads, empty removes
// the file, and append tolerance for future envelope fields.
import Foundation
import Testing
@testable import SZCore

private func tempProjectURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "SZMessageQueueIOTests-\(UUID().uuidString).subz")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func envelope(to recipient: String, text: String,
                      intent: SZMessageIntent = .chat,
                      state: SZMessageDeliveryState = .queued) -> SZMessageEnvelope {
    SZMessageEnvelope(recipient: recipient, sender: "user", intent: intent,
                      message: SZChatMessage(role: .user, text: text), state: state)
}

@Test func roundTripPreservesOrderAndFields() throws {
    let project = try tempProjectURL()
    defer { try? FileManager.default.removeItem(at: project) }
    let node = SZNodeID().uuidString
    let a = envelope(to: SZChatScope.directorKey, text: "first")
    let b = SZMessageEnvelope(recipient: node, sender: "user", intent: .chat,
                              message: SZChatMessage(role: .user, text: "second"),
                              transcriptMessageID: UUID())

    try SZMessageQueueIO.save([a, b], projectURL: project)
    let loaded = SZMessageQueueIO.load(projectURL: project)
    #expect(loaded.map(\.id) == [a.id, b.id])
    #expect(loaded.map(\.message.text) == ["first", "second"])
    #expect(loaded[1].transcriptMessageID == b.transcriptMessageID)
    #expect(loaded[1].sender == "user")
}

@Test func deliveringReloadsAsQueued() throws {
    let project = try tempProjectURL()
    defer { try? FileManager.default.removeItem(at: project) }
    let mid = envelope(to: SZChatScope.directorKey, text: "mid-flight", state: .delivering)

    try SZMessageQueueIO.save([mid], projectURL: project)
    let loaded = SZMessageQueueIO.load(projectURL: project)
    #expect(loaded.count == 1)
    #expect(loaded[0].state == .queued)   // at-least-once: a crash mid-delivery redelivers
}

@Test func terminalAndSteerAndDebugNeverPersist() throws {
    let project = try tempProjectURL()
    defer { try? FileManager.default.removeItem(at: project) }
    let keep = envelope(to: SZChatScope.directorKey, text: "keep")

    try SZMessageQueueIO.save([
        keep,
        envelope(to: SZChatScope.directorKey, text: "done", state: .processed),
        envelope(to: SZChatScope.directorKey, text: "dead", state: .failed),
        envelope(to: SZNodeID().uuidString, text: "steer", intent: .steer),
        envelope(to: SZChatScope.debugKey, text: "scratch"),
    ], projectURL: project)

    let loaded = SZMessageQueueIO.load(projectURL: project)
    #expect(loaded.map(\.id) == [keep.id])
}

@Test func emptySaveRemovesFile() throws {
    let project = try tempProjectURL()
    defer { try? FileManager.default.removeItem(at: project) }
    try SZMessageQueueIO.save([envelope(to: SZChatScope.directorKey, text: "x")],
                              projectURL: project)
    let file = project.appending(path: ".staging").appending(path: "message-queue.json")
    #expect(FileManager.default.fileExists(atPath: file.path))

    // A save with nothing persistable (all steers here) removes the husk.
    try SZMessageQueueIO.save([envelope(to: SZChatScope.directorKey, text: "s", intent: .steer)],
                              projectURL: project)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

@Test func missingAndCorruptFilesLoadEmpty() throws {
    let project = try tempProjectURL()
    defer { try? FileManager.default.removeItem(at: project) }
    #expect(SZMessageQueueIO.load(projectURL: project).isEmpty)   // missing

    let file = project.appending(path: ".staging").appending(path: "message-queue.json")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data("not json {".utf8).write(to: file)
    #expect(SZMessageQueueIO.load(projectURL: project).isEmpty)   // corrupt — never throws
}

@Test func brokenEnvelopeDropsAloneNotTheFile() throws {
    let project = try tempProjectURL()
    defer { try? FileManager.default.removeItem(at: project) }
    let good = envelope(to: SZChatScope.directorKey, text: "good")
    let json = """
    { "queue": { "formatVersion": 1, "envelopes": [
        { "recipient": "director" },
        \(String(data: try SZJSON.encoder().encode(good), encoding: .utf8)!)
    ] } }
    """
    let file = project.appending(path: ".staging").appending(path: "message-queue.json")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(json.utf8).write(to: file)

    let loaded = SZMessageQueueIO.load(projectURL: project)
    #expect(loaded.map(\.id) == [good.id])   // the message-less entry dropped alone
}

@Test func decodeToleratesFutureFields() throws {
    // A document written by a future version with extra fields still decodes today.
    let json = """
    { "queue": { "formatVersion": 7, "someFutureFlag": true, "envelopes": [ {
        "recipient": "director",
        "message": { "role": "user", "text": "hello" },
        "intent": "chat",
        "state": "queued",
        "futureField": { "nested": 1 },
        "priority": "high"
    } ] } }
    """
    let project = try tempProjectURL()
    defer { try? FileManager.default.removeItem(at: project) }
    let file = project.appending(path: ".staging").appending(path: "message-queue.json")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(json.utf8).write(to: file)

    let loaded = SZMessageQueueIO.load(projectURL: project)
    #expect(loaded.count == 1)
    #expect(loaded[0].message.text == "hello")
    // Minimal envelope: only recipient + message are hard-required.
    #expect(loaded[0].intent == .chat)
}
