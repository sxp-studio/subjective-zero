// SPDX-License-Identifier: AGPL-3.0-only
// SZAgentGraphRunIO — the runs.json sidecar: the round trip that PINS the on-disk format
// (records with every conclusion case, stamped entries, the dispatch tally), the forgiving
// load path (missing/corrupt is "no history", never a project-open error), the empty-save
// prune, and the version-less decode.
import Foundation
import Testing
@testable import SZCore

private func temporaryProjectURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "sz-runs-tests-\(UUID().uuidString).subz")
}

private func sampleRecords() -> [SZAgentGraphRun] {
    let buildID = UUID()

    var build = SZAgentGraphRun(id: buildID, agent: "director", thread: buildID,
                                startedAt: Date(timeIntervalSinceReferenceDate: 100))
    build.note(.init(ordinal: 1, node: "work-left", phase: .running),
               at: Date(timeIntervalSinceReferenceDate: 101))
    build.note(.init(ordinal: 1, node: "work-left", phase: .done, outcome: "yes"),
               at: Date(timeIntervalSinceReferenceDate: 130))
    build.note(.init(ordinal: 2, node: "send", phase: .done, outcome: "settled",
                     tally: .init(settled: 1, total: 2, failed: 0)),
               at: Date(timeIntervalSinceReferenceDate: 130))
    build.seal(conclusion: .ended, at: Date(timeIntervalSinceReferenceDate: 131))

    var child = SZAgentGraphRun(id: UUID(), agent: "coding",
                                thread: buildID, work: UUID().uuidString,
                                startedAt: Date(timeIntervalSinceReferenceDate: 200))
    child.seal(conclusion: .failed(reason: "the turn threw"),
               at: Date(timeIntervalSinceReferenceDate: 210))

    var declined = SZAgentGraphRun(id: UUID(), agent: "director",
                                   startedAt: Date(timeIntervalSinceReferenceDate: 250))
    declined.seal(conclusion: .declined(reason: "the sketch asks for a camera feed"),
                  at: Date(timeIntervalSinceReferenceDate: 260))

    var stopped = SZAgentGraphRun(id: UUID(), agent: "director", thread: buildID,
                                  startedAt: Date(timeIntervalSinceReferenceDate: 300))
    stopped.note(.init(ordinal: 1, node: "door", phase: .running),
                 at: Date(timeIntervalSinceReferenceDate: 301))
    stopped.seal(conclusion: .cancelled, at: Date(timeIntervalSinceReferenceDate: 305))

    var defect = SZAgentGraphRun(id: UUID(), agent: "coding",
                                 startedAt: Date(timeIntervalSinceReferenceDate: 400))
    defect.seal(conclusion: .defect(detail: "unknown node mid-traversal"),
                at: Date(timeIntervalSinceReferenceDate: 401))
    return SZAgentGraphRun.ordered([build, child, declined, stopped, defect])
}

@Test func runsRoundTripPreservesEveryConclusionCase() throws {
    // The conclusion coding becomes on-disk format here — this pins it.
    let projectURL = temporaryProjectURL()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    let records = sampleRecords()

    try SZAgentGraphRunIO.save(records, projectURL: projectURL)
    let loaded = try #require(SZAgentGraphRunIO.load(projectURL: projectURL))

    #expect(loaded == records)
    // Ordered newest-first on the way in, so the conclusion cases read back in that order.
    #expect(loaded.map(\.conclusion) == [
        .defect(detail: "unknown node mid-traversal"),
        .cancelled,
        .declined(reason: "the sketch asks for a camera feed"),
        .failed(reason: "the turn threw"),
        .ended,
    ])
    // The stamps, the tally and the cancel-flipped entry survive the trip — archived runs
    // keep their stats.
    let build = try #require(loaded.last)
    #expect(build.trace[0].duration == 29)
    #expect(build.trace.last?.tally == SZAgentGraphRun.Tally(settled: 1, total: 2, failed: 0))
    let stopped = loaded[1]
    #expect(stopped.trace[0].phase == .cancelled)
}

@Test func runsMissingFileLoadsAsNil() {
    #expect(SZAgentGraphRunIO.load(projectURL: temporaryProjectURL()) == nil)
}

@Test func runsCorruptFileLoadsAsNil() throws {
    let projectURL = temporaryProjectURL()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    let url = SZAgentGraphRunIO.fileURL(projectURL: projectURL)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    try Data("not json {{{".utf8).write(to: url)
    #expect(SZAgentGraphRunIO.load(projectURL: projectURL) == nil)
}

@Test func runsDocumentWithoutVersionStillDecodes() throws {
    let projectURL = temporaryProjectURL()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    let url = SZAgentGraphRunIO.fileURL(projectURL: projectURL)
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    try Data(#"{"runs":{"records":[]}}"#.utf8).write(to: url)
    #expect(SZAgentGraphRunIO.load(projectURL: projectURL) == [])
}

@Test func saveEmptyRecordsRemovesFile() throws {
    let projectURL = temporaryProjectURL()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    try SZAgentGraphRunIO.save(sampleRecords(), projectURL: projectURL)
    let url = SZAgentGraphRunIO.fileURL(projectURL: projectURL)
    #expect(FileManager.default.fileExists(atPath: url.path))

    try SZAgentGraphRunIO.save([], projectURL: projectURL)
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(SZAgentGraphRunIO.load(projectURL: projectURL) == nil)
}

@Test func recordWithoutOptionalFieldsStillDecodes() throws {
    // A minimal record — no thread, no item, no trace, no conclusion, no tally, no end —
    // must decode with defaults rather than demand the keys (the tolerance contract).
    let projectURL = temporaryProjectURL()
    defer { try? FileManager.default.removeItem(at: projectURL) }
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    let json = """
    {"runs": {"formatVersion": 1, "records": [
      {"id": "E277EC37-5EAB-422B-841A-D0BC10A6F302", "agent": "director",
       "startedAt": 807799097.271941}
    ]}}
    """
    try Data(json.utf8).write(to: SZAgentGraphRunIO.fileURL(projectURL: projectURL))
    let records = try #require(SZAgentGraphRunIO.load(projectURL: projectURL))
    #expect(records.count == 1)
    #expect(records[0].trace.isEmpty)
    #expect(records[0].conclusion == nil)
    #expect(records[0].trace.allSatisfy { $0.tally == nil })
    // On disk with no `endedAt` it reads live — a state `save` never writes, decoded
    // honestly rather than invented.
    #expect(records[0].isLive)
}
