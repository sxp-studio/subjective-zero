// SPDX-License-Identifier: AGPL-3.0-only
// SZChatTranscriptIO — per-scope transcript sidecars: round trip, the forgiving load path
// (missing/corrupt files are "no history", never a project-open error), the empty-save prune,
// and the debug/junk exclusions.
import Foundation
import Testing
@testable import SZCore

private func temporaryProjectURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "sz-transcript-tests-\(UUID().uuidString).subz")
}

private func sampleMessages() -> [SZChatMessage] {
    [
        SZChatMessage(role: .user, text: "more contrast"),
        SZChatMessage(role: .assistant, text: "On it.", thinking: "adjusting curve", duration: 3.5),
        SZChatMessage(role: .director, text: "unblock: use the pinned contract"),
    ]
}

@Test func transcriptRoundTripPreservesMessages() throws {
    let projectURL = temporaryProjectURL()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    let messages = sampleMessages()

    try SZChatTranscriptIO.save(messages, scopeKey: SZChatScope.directorKey, projectURL: projectURL)
    let loaded = try #require(SZChatTranscriptIO.load(scopeKey: SZChatScope.directorKey, projectURL: projectURL))

    #expect(loaded.count == 3)
    #expect(loaded.map(\.id) == messages.map(\.id))
    #expect(loaded.map(\.role) == [.user, .assistant, .director])
    #expect(loaded[1].text == "On it.")
    #expect(loaded[1].thinking == "adjusting curve")
    #expect(loaded[1].duration == 3.5)
}

@Test func transcriptMissingFileLoadsAsNil() {
    #expect(SZChatTranscriptIO.load(scopeKey: SZChatScope.directorKey, projectURL: temporaryProjectURL()) == nil)
}

@Test func transcriptCorruptFileLoadsAsNil() throws {
    let projectURL = temporaryProjectURL()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    let url = SZChatTranscriptIO.fileURL(projectURL: projectURL, scopeKey: SZChatScope.directorKey)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json {{{".utf8).write(to: url)
    #expect(SZChatTranscriptIO.load(scopeKey: SZChatScope.directorKey, projectURL: projectURL) == nil)
}

@Test func transcriptDocumentWithoutVersionStillDecodes() throws {
    // A sidecar written before formatVersion existed (or hand-trimmed) still loads.
    let projectURL = temporaryProjectURL()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    let url = SZChatTranscriptIO.fileURL(projectURL: projectURL, scopeKey: SZChatScope.directorKey)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"transcript":{"messages":[{"role":"user","text":"hi"}]}}"#.utf8).write(to: url)

    let loaded = try #require(SZChatTranscriptIO.load(scopeKey: SZChatScope.directorKey, projectURL: projectURL))
    #expect(loaded.count == 1)
    #expect(loaded[0].text == "hi")
}

@Test func saveEmptyMessagesRemovesFile() throws {
    let projectURL = temporaryProjectURL()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    try SZChatTranscriptIO.save(sampleMessages(), scopeKey: SZChatScope.directorKey, projectURL: projectURL)
    let url = SZChatTranscriptIO.fileURL(projectURL: projectURL, scopeKey: SZChatScope.directorKey)
    #expect(FileManager.default.fileExists(atPath: url.path))

    try SZChatTranscriptIO.save([], scopeKey: SZChatScope.directorKey, projectURL: projectURL)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(SZChatTranscriptIO.load(scopeKey: SZChatScope.directorKey, projectURL: projectURL) == nil)
}

@Test func debugScopeIsNeverPersistedNorLoaded() throws {
    let projectURL = temporaryProjectURL()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    try SZChatTranscriptIO.save(sampleMessages(), scopeKey: SZChatScope.debugKey, projectURL: projectURL)
    let url = SZChatTranscriptIO.fileURL(projectURL: projectURL, scopeKey: SZChatScope.debugKey)
    #expect(!FileManager.default.fileExists(atPath: url.path))

    // Even a hand-dropped debug.json must not load (belt AND braces).
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"transcript":{"messages":[{"role":"user","text":"scratch"}]}}"#.utf8).write(to: url)
    #expect(SZChatTranscriptIO.load(scopeKey: SZChatScope.debugKey, projectURL: projectURL) == nil)
    #expect(SZChatTranscriptIO.loadAll(projectURL: projectURL).isEmpty)
}

@Test func loadAllReturnsScopesAndSkipsJunk() throws {
    let projectURL = temporaryProjectURL()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    let nodeID = SZNodeID()
    try SZChatTranscriptIO.save(sampleMessages(), scopeKey: SZChatScope.directorKey, projectURL: projectURL)
    try SZChatTranscriptIO.save([SZChatMessage(role: .user, text: "node chat")],
                                scopeKey: nodeID.uuidString, projectURL: projectURL)

    // Junk neighbors: a non-json file, a json file whose name isn't a scope key, a corrupt node file.
    let dir = SZChatTranscriptIO.fileURL(projectURL: projectURL, scopeKey: "x").deletingLastPathComponent()
    try Data("notes".utf8).write(to: dir.appending(path: "notes.txt"))
    try Data("{}".utf8).write(to: dir.appending(path: "garbage-name.json"))
    try Data("not json {{{".utf8).write(to: dir.appending(path: "\(SZNodeID().uuidString).json"))

    let all = SZChatTranscriptIO.loadAll(projectURL: projectURL)
    #expect(all.count == 2)
    #expect(all[SZChatScope.directorKey]?.count == 3)
    #expect(all[nodeID.uuidString]?.first?.text == "node chat")
}

@Test func loadAllOnBundleWithoutTranscriptsDirIsEmpty() {
    #expect(SZChatTranscriptIO.loadAll(projectURL: temporaryProjectURL()).isEmpty)
}

@Test func removeDeletesSidecar() throws {
    let projectURL = temporaryProjectURL()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    try SZChatTranscriptIO.save(sampleMessages(), scopeKey: SZChatScope.directorKey, projectURL: projectURL)
    SZChatTranscriptIO.remove(scopeKey: SZChatScope.directorKey, projectURL: projectURL)
    #expect(SZChatTranscriptIO.load(scopeKey: SZChatScope.directorKey, projectURL: projectURL) == nil)
}
