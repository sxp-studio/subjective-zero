// SPDX-License-Identifier: AGPL-3.0-only
// Pins recording placement: the next "Recording N" is one past the highest existing number,
// whatever the extension, and never lands on an existing file.
import Foundation
import Testing
@testable import SZCore

private func makeProjectDir(takes: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "sztakes-\(UUID().uuidString)").appending(path: "p.subz")
    let dir = root.appending(path: SZProjectMedia.recordingsDirectoryName)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in takes {
        try Data().write(to: dir.appending(path: name))
    }
    return root
}

@Test func firstTakeIsNumberOne() throws {
    let root = try makeProjectDir(takes: [])
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let take = SZProjectMedia.nextRecording(in: root, fileExtension: "mov")
    #expect(take.number == 1)
    #expect(take.url.lastPathComponent == "Recording 1.mov")
}

@Test func aMissingTakesDirectoryStillNamesTakeOne() {
    let root = FileManager.default.temporaryDirectory.appending(path: "sztakes-none-\(UUID().uuidString)")
    let take = SZProjectMedia.nextRecording(in: root, fileExtension: "mov")
    #expect(take.number == 1)
}

@Test func numberingIsOnePastTheHighestAcrossExtensions() throws {
    // deletion gaps stay gaps (monotonic reads better in Finder), and a crash-leftover .mov counts
    let root = try makeProjectDir(takes: ["Recording 1.mp4", "Recording 3.mov", "notes.txt", "Recording x.mp4"])
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let take = SZProjectMedia.nextRecording(in: root, fileExtension: "mov")
    #expect(take.number == 4)
}

@Test func collisionBumpsPastAnExistingFile() throws {
    // "Recording 2.mov" exists but "Recording 2.mp4" makes 2 the max → candidate 3 is free
    let root = try makeProjectDir(takes: ["Recording 2.mp4", "Recording 3.mov"])
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let take = SZProjectMedia.nextRecording(in: root, fileExtension: "mov")
    #expect(take.number == 4)
    #expect(!FileManager.default.fileExists(atPath: take.url.path))
}
