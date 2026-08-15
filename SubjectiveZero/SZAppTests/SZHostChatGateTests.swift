// SPDX-License-Identifier: AGPL-3.0-only
// The chat lane holds the same library gate the build lane does: a graph only traverses
// out of a library that VALIDATES. Chat is where an edited pack first runs, and graph-
// shape defects (an unleashed cycle, a dangling edge, an empty seat) exist only in
// `validate` — a prose delivery that skipped it would traverse a broken graph unbounded.
// Pinned with a library that LOADS clean but does not validate (a lone seatless debug
// pack: both seats empty, its door step folder missing), so the refusal proven here can
// only come from the validate pass.
import Foundation
import Testing
import SZAI
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostChatGateTests {

    @Test func aLibraryThatDoesNotValidateRefusesBeforeAnyTurn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "sz-chat-gate-\(UUID().uuidString)")
        let debug = root.appending(path: "debug")
        try FileManager.default.createDirectory(at: debug, withIntermediateDirectories: true)
        try #"{ "id": "debug" }"#
            .write(to: debug.appending(path: "agent.json"), atomically: true, encoding: .utf8)
        try #"{ "nodes": [ { "id": "door", "step": "door" } ], "edges": [] }"#
            .write(to: debug.appending(path: "graph.json"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("SZ_AGENT_PACKS", root.path, 1)
        defer { unsetenv("SZ_AGENT_PACKS") }

        let host = SZHost()
        do {
            _ = try await host.runProseDelivery(
                scope: .debug, message: "hi", existing: nil, providerID: "none",
                extras: SZBriefExtras(),
                turn: { _ in
                    Issue.record("a defective library must refuse before any turn runs")
                    throw SZChatTraversalFailure(detail: "unreachable")
                })
            Issue.record("expected the library gate to refuse the delivery")
        } catch let failure as SZChatTraversalFailure {
            #expect(failure.detail.contains("does not validate"))
        }
    }
}
