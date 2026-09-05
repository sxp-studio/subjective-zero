// SPDX-License-Identifier: AGPL-3.0-only
// When a scope's agent session pin is kept, dropped, or refused: a run's receipt retires the
// Director thread, disabling or switching a provider drops its threads and is refused while
// agents own the project, a not-ready pinned provider falls back to a fresh session, and a
// failed resume drops its pin exactly once.
import Foundation
import Testing
import SZAI
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostSessionPinTests {

    private let director = SZChatScope.director.key
    private func pin(_ provider: String, _ id: String) -> SZAgentSession {
        SZAgentSession(providerID: provider, sessionID: id, envelope: SZRouteEnvelope(providerID: provider))
    }
    private func host() -> SZHost {
        let host = SZHost()
        host.disabledProviderIDs = []
        _ = host.setActiveProvider("claude")
        return host
    }
    private func liveRun(_ host: SZHost, _ label: String) -> SZRunState {
        let node = SZNodeID()
        let claim = SZClaimToken(label: label)
        #expect(host.ledger.tryAcquire([.node(node), .transcript(.node(node))], as: claim))
        let run = SZRunState(taskID: UUID(), claim: claim, instruction: label,
                             ownsGraphOp: false, workSet: [node])
        host.activeRuns[run.taskID] = run
        return run
    }

    /// A failed turn leaves no pin, except one the host's own budget stopped: that session holds
    /// the work, and the next attempt continues it instead of starting the node over.
    @Test func aTimedOutTurnKeepsItsSessionAndAFailedOneDoesNot() {
        #expect(SZHost.keepsSession(pin: true, slotUnchanged: true, failed: false, timedOut: false))
        #expect(SZHost.keepsSession(pin: true, slotUnchanged: true, failed: true, timedOut: true))
        #expect(!SZHost.keepsSession(pin: true, slotUnchanged: true, failed: true, timedOut: false))
        #expect(!SZHost.keepsSession(pin: true, slotUnchanged: false, failed: true, timedOut: true))
        #expect(!SZHost.keepsSession(pin: false, slotUnchanged: true, failed: false, timedOut: false))
    }

    @Test func aReceiptRetiresTheDirectorThreadAndLeavesNodePins() {
        let host = host()
        let node = SZChatScope.node(SZNodeID()).key
        host.agentSessions[director] = pin("claude", "old")
        host.agentSessions[node] = pin("claude", "n")
        host.narrateRunReceipt(SZChatReceipt.forEnding(implemented: 1, failed: 0, work: "Glow"),
                               seconds: 1, thread: UUID())
        #expect(host.agentSessions[director] == nil)
        #expect(host.agentSessions[node]?.sessionID == "n")
        #expect(host.store.messages(for: .director).last?.receipt != nil)
    }

    @Test func stoppingARunLeavesASiblingRunsThread() {
        let host = host()
        let a = liveRun(host, "a"), b = liveRun(host, "b")
        b.directorSession = pin("claude", "B")
        host.agentSessions[director] = pin("claude", "old")
        host.cancelRun(a)
        #expect(host.agentSessions[director] == nil)
        #expect(b.directorSession?.sessionID == "B")
        #expect(host.isLive(b))
    }

    @Test func disablingAProviderDropsItsPinsOnly() {
        let host = host()
        host.agentSessions[director] = pin("codex", "c")
        host.agentSessions["n"] = pin("claude", "k")
        #expect(host.setProviderEnabled("codex", false))
        #expect(host.agentSessions[director] == nil)
        #expect(host.agentSessions["n"]?.sessionID == "k")
    }

    @Test func disablingAndSwitchingAreRefusedWhileAgentsOwnTheProject() {
        let host = host()
        host.agentSessions[director] = pin("claude", "c")
        let claim = SZClaimToken(label: "delivery")
        #expect(host.ledger.tryAcquire(SZHost.turnResources(for: .director), as: claim))
        #expect(!host.setProviderEnabled("codex", false))
        #expect(!host.setActiveProvider("codex"))
        #expect(host.agentSessions[director]?.sessionID == "c")
        host.ledger.releaseAll(of: claim)
        #expect(host.setActiveProvider("codex"))
        #expect(host.agentSessions[director] == nil)
    }

    @Test func aPinToADisabledProviderFallsBackToAFreshSession() {
        let host = host()
        host.disabledProviderIDs = ["codex"]
        host.agentSessions[director] = pin("codex", "c")
        guard case .ready(let looked, let session, let note) = host.providerForTurn(.director, heal: false)
        else { Issue.record("refused"); return }
        #expect(looked.id == "claude" && session == nil && note != nil)
        #expect(host.agentSessions[director] != nil)   // enqueue only looks
        guard case .ready(_, _, _) = host.providerForTurn(.director, heal: true)
        else { Issue.record("refused"); return }
        #expect(host.agentSessions[director] == nil)
    }

    @Test func aReadyPinIsKeptAndANotReadyFallbackIsRefused() {
        let host = host()
        host.agentSessions[director] = pin("claude", "c")
        guard case .ready(_, let session, let note) = host.providerForTurn(.director, heal: true)
        else { Issue.record("refused"); return }
        #expect(session?.sessionID == "c" && note == nil)
        host.disabledProviderIDs = ["claude"]
        host.agentSessions[director] = nil
        guard case .refused(let why) = host.providerForTurn(.director, heal: true)
        else { Issue.record("ready"); return }
        #expect(why.contains("not ready"))
    }

    @Test func aPinIsKeptWhenNoProviderCouldTakeTheTurn() {
        let host = host()
        host.disabledProviderIDs = ["claude"]   // pinned AND active
        host.agentSessions[director] = pin("claude", "c")
        guard case .refused(let why) = host.providerForTurn(.director, heal: true)
        else { Issue.record("ready"); return }
        #expect(why.contains("not ready"))
        #expect(host.agentSessions[director]?.sessionID == "c")
    }

    @Test func aFailedResumeDropsItsPinOnce() {
        let host = host()
        host.agentSessions[director] = pin("claude", "c")
        #expect(host.dropSessionAfterFailedResume(.director))
        #expect(host.agentSessions[director] == nil)
        #expect(!host.dropSessionAfterFailedResume(.director))
    }
}
