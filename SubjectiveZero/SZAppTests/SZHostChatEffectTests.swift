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
