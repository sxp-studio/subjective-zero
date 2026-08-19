// SPDX-License-Identifier: AGPL-3.0-only
// The scheduled-task sidecar: an ask that never started is still wanted after a restart, and a
// task that WAS running must never come back as one — its claim, fleet and traversal died with
// the process, and re-admitting it would redo work that may already have landed.
import Foundation
import Testing
@testable import SZCore

@Test func pendingTasksSurviveARestartInOrder() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "sz-tasks-\(UUID()).subz")
    defer { try? FileManager.default.removeItem(at: dir) }

    let first = SZTask(title: "make it warmer", instruction: "make it warmer")
    let second = SZTask(title: "add a glow", instruction: "add a glow", workSet: [SZNodeID()])
    try SZTaskQueueIO.save([first, second], projectURL: dir)

    let restored = SZTaskQueueIO.load(projectURL: dir).tasks
    #expect(restored.map(\.id) == [first.id, second.id])
    #expect(restored.map(\.instruction) == ["make it warmer", "add a glow"])
    #expect(restored.last?.workSet == second.workSet)
}

@Test func aRunningTaskIsNeverPersistedOrRestored() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "sz-tasks-\(UUID()).subz")
    defer { try? FileManager.default.removeItem(at: dir) }

    let running = SZTask(title: "already building", instruction: "x", state: .running)
    let waiting = SZTask(title: "still waiting", instruction: "y")
    try SZTaskQueueIO.save([running, waiting], projectURL: dir)
    #expect(SZTaskQueueIO.load(projectURL: dir).tasks.map(\.title) == ["still waiting"])

    // And the filter applies on the way IN too, so a hand-edited file cannot resurrect one.
    #expect(SZTaskQueueIO.persistable([running, waiting]).map(\.title) == ["still waiting"])
}

@Test func anEmptyQueueLeavesNoHuskAndAMissingFileIsNotAnError() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "sz-tasks-\(UUID()).subz")
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(SZTaskQueueIO.load(projectURL: dir).tasks.isEmpty)   // never opened: no file, no throw
    try SZTaskQueueIO.save([SZTask(title: "t", instruction: "t")], projectURL: dir)
    #expect(FileManager.default.fileExists(atPath: SZTaskQueueIO.fileURL(projectURL: dir).path))
    try SZTaskQueueIO.save([], projectURL: dir)
    #expect(!FileManager.default.fileExists(atPath: SZTaskQueueIO.fileURL(projectURL: dir).path))
}

@Test func theSidecarLivesUnderStagingSoACopiedBundleCannotBuildItself() {
    let dir = URL(fileURLWithPath: "/tmp/Whatever.subz")
    // Same reasoning as the message queue: a task SPENDS TOKENS when it starts, so it must not
    // travel in a bundle someone else opens.
    #expect(SZTaskQueueIO.fileURL(projectURL: dir).path.hasSuffix("/.staging/tasks.json"))
}

@Test func aBrokenEntryDropsAloneInsteadOfSinkingTheFile() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "sz-tasks-\(UUID()).subz")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir.appending(path: ".staging"),
                                            withIntermediateDirectories: true)
    let good = SZTask(title: "kept", instruction: "kept")
    let json = """
    { "tasks": { "formatVersion": 1, "tasks": [
        { "nonsense": true },
        { "id": "\(good.id.uuidString)", "title": "kept", "instruction": "kept",
          "state": "pending", "workSet": [], "createdAt": 0 }
    ] } }
    """
    try Data(json.utf8).write(to: SZTaskQueueIO.fileURL(projectURL: dir))
    #expect(SZTaskQueueIO.load(projectURL: dir).tasks.map(\.title) == ["kept"])
}

@Test func aStopsHoldTravelsWithTheQueueItFroze() throws {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "sz-tasks-\(UUID().uuidString).subz")
    defer { try? FileManager.default.removeItem(at: dir) }
    let task = SZTask(title: "frozen", instruction: "make it snow")

    try SZTaskQueueIO.save([task], suspended: true, projectURL: dir)

    // Without this the app relaunched and immediately admitted every task the Stop had frozen —
    // token spend on asks the user had just killed.
    #expect(SZTaskQueueIO.load(projectURL: dir).suspended)
    try SZTaskQueueIO.save([task], suspended: false, projectURL: dir)
    #expect(!SZTaskQueueIO.load(projectURL: dir).suspended)
}
