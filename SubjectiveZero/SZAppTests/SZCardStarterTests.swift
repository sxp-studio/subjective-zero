// SPDX-License-Identifier: AGPL-3.0-only
// The hand-authoring starter ("New Custom Card…") IS the card doc's worked example — it must
// compile as shipped, or the first file a user opens greets them with the failed chip.
import Foundation
import Testing
import SZAI
import SZRuntime
@testable import SubjectiveZero

@MainActor @Test func starterCardSourceCompiles() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "SZCardStarter-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let source = dir.appending(path: "Card.swift")
    try SZAgentDocs.cardStarterSource.write(to: source, atomically: true, encoding: .utf8)
    _ = try SZToolchain().compile(cardSource: source, into: dir.appending(path: "build"))
}
