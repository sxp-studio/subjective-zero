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

/// A project directory that exists next to `url`, so a save does not prune it as gone.
private func existingProject(_ name: String, beside url: URL) throws -> URL {
    let project = url.deletingLastPathComponent().appending(path: name)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    return project
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
    let projectA = try existingProject("a.subz", beside: url)
    let projectB = try existingProject("b.subz", beside: url)
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
    let projectA = try existingProject("a.subz", beside: url)
    let projectB = try existingProject("b.subz", beside: url)
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

@Test func sessionsSavePrunesProjectsThatNoLongerExist() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let projectA = try existingProject("a.subz", beside: url)
    let projectB = try existingProject("b.subz", beside: url)
    let sessionA = [SZChatScope.directorKey: SZAgentSession(providerID: "claude", sessionID: "a-1")]
    let sessionB = [SZChatScope.directorKey: SZAgentSession(providerID: "codex", sessionID: "b-1")]
    try SZAgentSessionIO.save(sessionA, projectURL: projectA, to: url)
    try SZAgentSessionIO.save(sessionB, projectURL: projectB, to: url)

    try FileManager.default.removeItem(at: projectA)
    try SZAgentSessionIO.save(sessionB, projectURL: projectB, to: url)

    #expect(SZAgentSessionIO.load(projectURL: projectA, from: url).isEmpty)
    #expect(SZAgentSessionIO.load(projectURL: projectB, from: url) == sessionB)
    let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    #expect(!raw.contains("a.subz"))
}

@Test func sessionsConcurrentSavesKeepBothProjects() async throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let projectA = try existingProject("a.subz", beside: url)
    let projectB = try existingProject("b.subz", beside: url)
    let sessionA = [SZChatScope.directorKey: SZAgentSession(providerID: "claude", sessionID: "a-1")]
    let sessionB = [SZChatScope.directorKey: SZAgentSession(providerID: "codex", sessionID: "b-1")]

    await withTaskGroup(of: Void.self) { group in
        group.addTask { for _ in 0..<20 { try? SZAgentSessionIO.save(sessionA, projectURL: projectA, to: url) } }
        group.addTask { for _ in 0..<20 { try? SZAgentSessionIO.save(sessionB, projectURL: projectB, to: url) } }
    }

    #expect(SZAgentSessionIO.load(projectURL: projectA, from: url) == sessionA)
    #expect(SZAgentSessionIO.load(projectURL: projectB, from: url) == sessionB)
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

@Test func sessionsSaveKeepsAProjectWhoseVolumeIsAway() throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "sz-sessions-\(UUID().uuidString)").appending(path: "agent-sessions.json")
    let here = try existingProject("here.subz", beside: url)
    let away = URL(filePath: "/Volumes/\(UUID().uuidString)/away.subz")   // parent does not exist
    try SZAgentSessionIO.save(["d": SZAgentSession(providerID: "claude", sessionID: "1")], projectURL: away, to: url)
    try SZAgentSessionIO.save(["d": SZAgentSession(providerID: "claude", sessionID: "2")], projectURL: here, to: url)
    #expect(SZAgentSessionIO.load(projectURL: away, from: url)["d"]?.sessionID == "1")
}

@Test func sessionsRekeyToAMovedProjectAndLeaveOthersAlone() throws {
    // A relocation writes the live map at the new path and clears the old one, so the bundle left
    // behind cold-starts from its transcripts instead of resuming the same CLI conversation.
    let url = FileManager.default.temporaryDirectory
        .appending(path: "sz-sessions-\(UUID().uuidString)").appending(path: "agent-sessions.json")
    let from = try existingProject("A.subz", beside: url)
    let to = try existingProject("B.subz", beside: url)
    let bystander = try existingProject("C.subz", beside: url)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let live = ["director": SZAgentSession(providerID: "claude", sessionID: "live")]
    try SZAgentSessionIO.save(live, projectURL: from, to: url)
    try SZAgentSessionIO.save(["director": SZAgentSession(providerID: "claude", sessionID: "other")],
                              projectURL: bystander, to: url)

    try SZAgentSessionIO.save(live, projectURL: to, to: url)
    try SZAgentSessionIO.save([:], projectURL: from, to: url)

    #expect(SZAgentSessionIO.load(projectURL: to, from: url)["director"]?.sessionID == "live")
    #expect(SZAgentSessionIO.load(projectURL: from, from: url).isEmpty)
    #expect(SZAgentSessionIO.load(projectURL: bystander, from: url)["director"]?.sessionID == "other")
}

