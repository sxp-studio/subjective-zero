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

    @Test func aTaskMintedOrAmendedMidTurnTakesThatDeliverysBubblesAsOrigin() {
        let host = SZHost()
        let ask: Set<UUID> = [UUID(), UUID()]
        host.deliveringBubbles[SZChatScope.director.key] = ask
        let id = host.mintRun(instruction: "make it warmer")
        #expect(host.pendingTasks.first?.origin == ask)
        // A later amend, delivered in its own turn, joins its bubbles to the same task.
        let amend: Set<UUID> = [UUID()]
        host.deliveringBubbles[SZChatScope.director.key] = amend
        #expect(host.amendTask(id, with: "blue, not red"))
        #expect(host.pendingTasks.first?.origin == ask.union(amend))
        // Outside any turn (the Build button), nothing scheduled it.
        host.deliveringBubbles = [:]
        host.mintRun(instruction: "")
        #expect(host.pendingTasks.last?.origin.isEmpty == true)
    }

    @Test func theProjectedConversationIsCompletedMessagesMinusTheExcluded() {
        let host = SZHost()
        let first = host.store.appendChatMessage(SZChatMessage(role: .user, text: "A"), to: .director)
        host.store.appendChatMessage(SZChatMessage(role: .assistant, text: "reply"), to: .director)
        let own = host.store.appendChatMessage(SZChatMessage(role: .user, text: "B"), to: .director)
        host.store.appendChatMessage(SZChatMessage(role: .assistant, text: "(busy)", transient: true),
                                     to: .director)
        let placeholder = host.store.appendChatMessage(SZChatMessage(role: .assistant, text: ""),
                                                       to: .director)
        #expect(host.conversation(for: .director, excluding: [own, placeholder]).map(\.text)
                == ["A", "reply"])
        #expect(host.conversation(for: .director).map(\.id).contains(first))
        #expect(host.conversation(for: .debug).isEmpty)
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

    @Test func mintingDuringAnActiveRunQueuesBehindItInTheStrip() {
        let host = SZHost()
        let node = SZNodeID()
        let run = SZRunState(taskID: UUID(), claim: SZClaimToken(label: "test run"),
                             instruction: "first", ownsGraphOp: false, workSet: [node])
        host.activeRuns[run.taskID] = run
        defer { host.activeRuns = [:] }
        host.mintRun(instruction: "again")
        // Queued, not dropped — and shown as a scheduled row, not said. The conversation stays
        // clear of a state the strip holds for the whole time it is true.
        #expect(host.pendingTasks.map(\.instruction) == ["again"])
        #expect(host.scheduledTaskRows.count == 1)
        #expect(host.store.messages(for: .director).isEmpty)
    }
}
