// SPDX-License-Identifier: AGPL-3.0-only
// The `requestBuild` chat effect's HOST lane, on a bare host (no project, no provider): the
// chat traversal's effect must land on the queued `pendingDirectorRun` lane — never a direct
// start, because the delivering chat turn still holds the Director transcript — carrying the
// user's message as the run's instruction, deferring to a run the turn already queued
// itself, and skipping with one honest Director line while a run is active. (The full chat
// traversal needs compiled steps + a provider CLI, so it lives in the SZAITests engine suite
// and the SZRuntimeTests compiled-step pins; this smoke covers the app-side wiring those
// can't reach.)
import Foundation
import Testing
import SZAI
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostChatEffectTests {

    @Test func theRequestBuildEffectLandsOnTheQueuedRunLane() async {
        let host = SZHost()
        await host.perform(effect: "requestBuild", kind: .message)
        // Queued (a bare effect name carries no instruction); the bare host's pump could
        // not start it (no MCP server), so the request must still be waiting.
        #expect(host.pendingDirectorRun == "")
    }

    @Test func theChatLaneCarriesTheMessageAndDefersToAQueuedRun() {
        let host = SZHost()
        host.queueChatRequestedBuild(instruction: "make it warmer")
        #expect(host.pendingDirectorRun == "make it warmer")
        // A run the turn already queued itself (`ui_run` mid-turn) wins — one request is
        // enough, and the earlier instruction is the honest one.
        host.queueChatRequestedBuild(instruction: "something else")
        #expect(host.pendingDirectorRun == "make it warmer")
    }

    @Test func requestBuildDuringAnActiveRunSkipsWithOneNarratedLine() async {
        let host = SZHost()
        let claim = SZClaimToken(label: "test run")
        #expect(host.ledger.tryAcquire([.run], as: claim))
        defer { host.ledger.releaseAll(of: claim) }
        await host.perform(effect: "requestBuild", kind: .message)
        #expect(host.pendingDirectorRun == nil)
        #expect(host.store.messages(for: .director).contains {
            $0.text.contains("requestBuild") && $0.text.contains("skipped")
        })
    }
}
