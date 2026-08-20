// SPDX-License-Identifier: AGPL-3.0-only
// The routing seam's identity contract: the identity router answers every call — either
// class, any origin — with the one choice it was built with, fields intact. This is the
// byte-identical-off baseline every policy router is measured against.
import Testing
import SZAI

@Suite
struct SZModelRouterTests {

    @Test func theIdentityRouterAnswersAQueryWithItsOneChoice() {
        let choice = SZModelChoice(providerID: "provider-a", model: "model-x", reasoningEffort: "high")
        let router: any SZModelRouting = SZIdentityRouter(choice: choice)

        let resolved = router.resolve(SZModelCall(
            class: .query, agent: "director"))
        #expect(resolved.providerID == "provider-a")
        #expect(resolved.model == "model-x")
        #expect(resolved.reasoningEffort == "high")
        #expect(resolved.fastMode == false)
    }

    @Test func theIdentityRouterAnswersATurnWithTheSameChoice() {
        // A bare choice (provider only) stays bare: nil model/effort defer to the provider's
        // defaults, exactly as the provider seam already reads them.
        let router: any SZModelRouting = SZIdentityRouter(choice: SZModelChoice(providerID: "provider-b"))

        let resolved = router.resolve(SZModelCall(class: .turn, agent: "coding"))
        #expect(resolved.providerID == "provider-b")
        #expect(resolved.model == nil)
        #expect(resolved.reasoningEffort == nil)
        #expect(resolved.fastMode == false)
    }

    @Test func theIdentityRouterCarriesFastModeToEveryTurn() {
        // Fast mode rides the choice — the turn lanes read it verbatim; the query lane's
        // request carries no fast flag at all, whatever the choice says.
        let router: any SZModelRouting = SZIdentityRouter(choice: SZModelChoice(
            providerID: "provider-c", model: "model-y", fastMode: true))

        let turn = router.resolve(SZModelCall(class: .turn, agent: "director", duty: "plan"))
        #expect(turn.fastMode)
        #expect(turn.providerID == "provider-c")
    }
}
