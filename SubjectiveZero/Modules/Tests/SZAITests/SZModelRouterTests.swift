// SPDX-License-Identifier: AGPL-3.0-only
// The routing seam's v1 contract: the identity router answers every call — either class,
// any origin — with the one choice it was built with, fields intact.
import Testing
import SZAI

@Suite
struct SZModelRouterTests {

    @Test func theIdentityRouterAnswersAQueryWithItsOneChoice() {
        let choice = SZModelChoice(providerID: "provider-a", model: "model-x", reasoningEffort: "high")
        let router: any SZModelRouting = SZIdentityRouter(choice: choice)

        let resolved = router.resolve(SZModelCall(
            class: .query, agent: "director", graph: "work", step: "verdict"))
        #expect(resolved.providerID == "provider-a")
        #expect(resolved.model == "model-x")
        #expect(resolved.reasoningEffort == "high")
    }

    @Test func theIdentityRouterAnswersATurnWithTheSameChoice() {
        // A bare choice (provider only) stays bare: nil model/effort defer to the provider's
        // defaults, exactly as the provider seam already reads them.
        let router: any SZModelRouting = SZIdentityRouter(choice: SZModelChoice(providerID: "provider-b"))

        let resolved = router.resolve(SZModelCall(class: .turn, agent: "coding"))
        #expect(resolved.providerID == "provider-b")
        #expect(resolved.model == nil)
        #expect(resolved.reasoningEffort == nil)
    }
}
