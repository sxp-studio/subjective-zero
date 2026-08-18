// SPDX-License-Identifier: AGPL-3.0-only
// The `requestBuild` effect's HOST lane, on a bare host (no project, no provider): the
// effect SCHEDULES a task — never a direct start, because the delivering turn still holds the
// Director transcript — carrying the instruction, and a second ask QUEUES behind the first
// instead of being dropped. (The full traversal needs compiled steps + a provider CLI, so it
// lives in the SZAITests engine suite and the SZRuntimeTests compiled-step pins; this smoke
// covers the app-side wiring those can't reach.)
import Foundation
import Testing
import SZAI
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostChatEffectTests {

    @Test func theRequestBuildEffectSchedulesATask() async {
        let host = SZHost()
        await host.perform(effect: .requestBuild)
        // Scheduled (a bare effect carries no instruction); the bare host's pump could not
        // admit it (no MCP server), so the task must still be pending.
        #expect(host.pendingTasks.map(\.instruction) == [""])
    }

    @Test func theMintCarriesTheMessageAndASecondAskQueuesBehindIt() {
        let host = SZHost()
        host.mintRun(instruction: "make it warmer")
        #expect(host.pendingTasks.map(\.instruction) == ["make it warmer"])
        // Both stand, oldest first — a second ask is scheduled, not a replacement.
        host.mintRun(instruction: "something else")
        #expect(host.pendingTasks.map(\.instruction) == ["make it warmer", "something else"])
    }

    @Test func aScheduledTaskCanBeWithdrawnUntilItStarts() {
        let host = SZHost()
        let id = host.mintRun(instruction: "never mind")
        #expect(host.withdrawTask(id))
        #expect(host.pendingTasks.isEmpty)
        #expect(!host.withdrawTask(id))   // gone once, gone for good
    }

    @Test func aNotReadyHostAnswersWaitingAndTheSlotSurvives() {
        let host = SZHost()
        // No MCP server, no project: not READY — never a terminal refusal. The mint's
        // pump pass leaves the slot for the release that can finally admit it.
        #expect(host.startRun(instruction: "warmer") == .waiting)
        host.mintRun(instruction: "warmer")
        #expect(host.pendingTasks.map(\.instruction) == ["warmer"])
    }

    @Test func admissionWaitsOutAHeldDirectorTranscript() {
        let host = SZHost()
        let turn = SZClaimToken(label: "director chat")
        #expect(host.ledger.tryAcquire([.transcript(.director)], as: turn))
        host.mintRun(instruction: "later")
        // Deferred, not dropped: the held transcript blocks admission and the slot stays;
        // the release re-fires the pump (and, bare, parks at waiting again).
        #expect(host.pendingTasks.map(\.instruction) == ["later"])
        host.ledger.releaseAll(of: turn)
        #expect(host.pendingTasks.map(\.instruction) == ["later"])
    }

    @Test func mintingDuringAnActiveRunQueuesBehindItWithOneNarratedLine() {
        let host = SZHost()
        let claim = SZClaimToken(label: "test run")
        #expect(host.ledger.tryAcquire([.run], as: claim))
        defer { host.ledger.releaseAll(of: claim) }
        host.mintRun(instruction: "again")
        // Queued, not dropped — and said so once.
        #expect(host.pendingTasks.map(\.instruction) == ["again"])
        #expect(host.store.messages(for: .director).contains { $0.text.contains("Queued") })
    }
}
