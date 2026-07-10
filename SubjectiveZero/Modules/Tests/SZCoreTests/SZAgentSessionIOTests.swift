// SPDX-License-Identifier: AGPL-3.0-only
// SZAgentSessionIO — the machine-local agent-sessions.json store: per-project round trip, the
// forgiving load path, cross-project isolation, and the empty-map prune.
import Foundation
import Testing
@testable import SZCore

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "sz-sessions-tests-\(UUID().uuidString)")
        .appending(path: "agent-sessions.json")
}

@Test func sessionsRoundTripPerProject() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let projectURL = URL(fileURLWithPath: "/tmp/demo.subz")
    let sessions = [
        SZChatScope.directorKey: SZAgentSession(providerID: "claude", sessionID: "abc-123"),
        SZNodeID().uuidString: SZAgentSession(providerID: "codex", sessionID: "thread-9"),
    ]

    try SZAgentSessionIO.save(sessions, projectURL: projectURL, to: url)
    #expect(SZAgentSessionIO.load(projectURL: projectURL, from: url) == sessions)
}

@Test func sessionsMissingFileLoadsAsEmpty() {
    #expect(SZAgentSessionIO.load(projectURL: URL(fileURLWithPath: "/tmp/x.subz"), from: temporaryURL()).isEmpty)
}

@Test func sessionsCorruptFileLoadsAsEmpty() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json {{{".utf8).write(to: url)
    #expect(SZAgentSessionIO.load(projectURL: URL(fileURLWithPath: "/tmp/x.subz"), from: url).isEmpty)
}

@Test func sessionsForTwoProjectsDoNotClobberEachOther() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let projectA = URL(fileURLWithPath: "/tmp/a.subz")
    let projectB = URL(fileURLWithPath: "/tmp/b.subz")
    let sessionA = [SZChatScope.directorKey: SZAgentSession(providerID: "claude", sessionID: "a-1")]
    let sessionB = [SZChatScope.directorKey: SZAgentSession(providerID: "codex", sessionID: "b-1")]

    try SZAgentSessionIO.save(sessionA, projectURL: projectA, to: url)
    try SZAgentSessionIO.save(sessionB, projectURL: projectB, to: url)

    #expect(SZAgentSessionIO.load(projectURL: projectA, from: url) == sessionA)
    #expect(SZAgentSessionIO.load(projectURL: projectB, from: url) == sessionB)
}

@Test func sessionsEmptyMapPrunesTheProjectEntry() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let projectA = URL(fileURLWithPath: "/tmp/a.subz")
    let projectB = URL(fileURLWithPath: "/tmp/b.subz")
    try SZAgentSessionIO.save([SZChatScope.directorKey: SZAgentSession(providerID: "claude", sessionID: "a-1")],
                              projectURL: projectA, to: url)
    try SZAgentSessionIO.save([SZChatScope.directorKey: SZAgentSession(providerID: "codex", sessionID: "b-1")],
                              projectURL: projectB, to: url)

    try SZAgentSessionIO.save([:], projectURL: projectA, to: url)
    #expect(SZAgentSessionIO.load(projectURL: projectA, from: url).isEmpty)
    #expect(!SZAgentSessionIO.load(projectURL: projectB, from: url).isEmpty)   // B untouched

    let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    #expect(!raw.contains("a.subz"))   // pruned, not just emptied
}

@Test func sessionsPartialEntryFailsDecodeAsAbsent() throws {
    // A session missing sessionID is useless — the whole document decode fails and load degrades
    // to empty (forgiving), rather than a half-usable entry sneaking in.
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"formatVersion":1,"projects":{"/tmp/x.subz":{"director":{"providerID":"claude"}}}}"#.utf8)
        .write(to: url)
    #expect(SZAgentSessionIO.load(projectURL: URL(fileURLWithPath: "/tmp/x.subz"), from: url).isEmpty)
}
