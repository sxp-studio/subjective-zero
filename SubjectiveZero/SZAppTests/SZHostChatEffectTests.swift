// SPDX-License-Identifier: AGPL-3.0-only
// The `requestBuild` effect's HOST lane, on a bare host (no project, no provider): the
// effect MINTS the run — never a direct start, because the delivering turn still holds the
// Director transcript — carrying the instruction into the pending slot, where a newer mint
// supersedes and an active run refuses with one honest Director line. (The full traversal
// needs compiled steps + a provider CLI, so it lives in the SZAITests engine suite and the
// SZRuntimeTests compiled-step pins; this smoke covers the app-side wiring those can't
// reach.)
import Foundation
import Testing
import SZAI
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostChatEffectTests {

    @Test func theRequestBuildEffectMintsTheRun() async {
        let host = SZHost()
        await host.perform(effect: .requestBuild)
        // Minted (a bare effect carries no instruction); the bare host's pump could not
        // admit it (no MCP server), so the run must still be waiting.
        #expect(host.pendingRun == "")
    }

    @Test func theMintCarriesTheMessageAndANewerMintSupersedes() {
        let host = SZHost()
        host.mintRun(instruction: "make it warmer")
        #expect(host.pendingRun == "make it warmer")
        // One pending run: the NEWER ask is the standing one.
        host.mintRun(instruction: "something else")
        #expect(host.pendingRun == "something else")
    }

    @Test func aNotReadyHostAnswersWaitingAndTheSlotSurvives() {
        let host = SZHost()
        // No MCP server, no project: not READY — never a terminal refusal. The mint's
        // pump pass leaves the slot for the release that can finally admit it.
        #expect(host.startRun(instruction: "warmer") == .waiting)
        host.mintRun(instruction: "warmer")
        #expect(host.pendingRun == "warmer")
    }

    @Test func admissionWaitsOutAHeldDirectorTranscript() {
        let host = SZHost()
        let turn = SZClaimToken(label: "director chat")
        #expect(host.ledger.tryAcquire([.transcript(.director)], as: turn))
        host.mintRun(instruction: "later")
        // Deferred, not dropped: the held transcript blocks admission and the slot stays;
        // the release re-fires the pump (and, bare, parks at waiting again).
        #expect(host.pendingRun == "later")
        host.ledger.releaseAll(of: turn)
        #expect(host.pendingRun == "later")
    }

    @Test func mintingDuringAnActiveRunSkipsWithOneNarratedLine() {
        let host = SZHost()
        let claim = SZClaimToken(label: "test run")
        #expect(host.ledger.tryAcquire([.run], as: claim))
        defer { host.ledger.releaseAll(of: claim) }
        host.mintRun(instruction: "again")
        #expect(host.pendingRun == nil)
        #expect(host.store.messages(for: .director).contains {
            $0.text.contains("skipped") && $0.text.contains("already active")
        })
    }
}
