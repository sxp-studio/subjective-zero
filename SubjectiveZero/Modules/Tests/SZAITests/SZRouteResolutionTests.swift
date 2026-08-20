// SPDX-License-Identifier: AGPL-3.0-only
// An envelope's landing on a provider: merge over the stored baseline, clamp through the
// one clamp point, and surface — never hide — a model the live catalog wouldn't honour.
// The old role-routing spec's cases, re-anchored on envelopes.
import Testing
import SZAI
import SZCore

/// Two models, distinct effort menus, fast mode honoured only on m-fast.
private struct TwoModelProvider: SZProvider {
    let id = "stub"
    let models = [
        SZProviderModel(id: "m-big", displayName: "Big",
                        supportedReasoningEfforts: ["low", "high"], defaultReasoningEffort: "high"),
        SZProviderModel(id: "m-fast", displayName: "Fast", supportsFastMode: true),
    ]
    let defaultModel = "m-big"
    let defaultReasoningEffort = "low"
    let supportedReasoningEfforts = ["low"]
    let supportsFastMode = false
    let healthArgs = ["stub", "--version"]
    let installCommand = "echo install"
    let loginCommand = "echo login"
    func launch(_ request: SZAgentRunRequest, preallocatedSessionID: String?) -> SZLaunch {
        SZLaunch(executable: "/usr/bin/env", arguments: ["stub"])
    }
    func parse(output: String, exitCode: Int32, preallocatedSessionID: String?) -> SZAgentOutcome {
        SZAgentOutcome(sessionID: nil, failed: exitCode != 0)
    }
}

/// A dynamic-catalog provider before its first fetch: an empty model list.
private struct EmptyCatalogProvider: SZProvider {
    let id = "empty"
    let models: [SZProviderModel] = []
    let defaultModel = ""
    let defaultReasoningEffort = ""
    let healthArgs = ["empty", "--version"]
    let installCommand = "echo install"
    let loginCommand = "echo login"
    func launch(_ request: SZAgentRunRequest, preallocatedSessionID: String?) -> SZLaunch {
        SZLaunch(executable: "/usr/bin/env", arguments: ["empty"])
    }
    func parse(output: String, exitCode: Int32, preallocatedSessionID: String?) -> SZAgentOutcome {
        SZAgentOutcome(sessionID: nil, failed: exitCode != 0)
    }
}

@Suite
struct SZRouteResolutionTests {

    @Test func anEnvelopeModelLandsAsAskedWithItsOwnClamp() {
        let routed = TwoModelProvider().routedGenerationSettings(
            envelope: SZRouteEnvelope(providerID: "stub", model: "m-big", reasoningEffort: "high"),
            baseline: SZProviderGenerationSettings())
        #expect(routed.settings.model == "m-big")
        #expect(routed.settings.reasoningEffort == "high")
        #expect(routed.substitutedModel == nil)
    }

    @Test func anEffortOnlyEnvelopeKeepsTheBaselineModel() {
        let routed = TwoModelProvider().routedGenerationSettings(
            envelope: SZRouteEnvelope(providerID: "stub", reasoningEffort: "low"),
            baseline: SZProviderGenerationSettings(model: "m-big", reasoningEffort: "high"))
        #expect(routed.settings.model == "m-big")
        #expect(routed.settings.reasoningEffort == "low")
        #expect(routed.substitutedModel == nil)
    }

    @Test func aModelOffTheCatalogIsSubstitutedLoudly() {
        // The clamp lands the provider's default; the asked-for id is surfaced so the host
        // can say so — never a silent substitution.
        let routed = TwoModelProvider().routedGenerationSettings(
            envelope: SZRouteEnvelope(providerID: "stub", model: "m-gone"),
            baseline: SZProviderGenerationSettings())
        #expect(routed.settings.model == "m-big")
        #expect(routed.substitutedModel == "m-gone")
    }

    @Test func anEmptyPreFetchCatalogRefusesAModelClaim() {
        // A dynamic provider before its first fetch can't vouch for any model id.
        let routed = EmptyCatalogProvider().routedGenerationSettings(
            envelope: SZRouteEnvelope(providerID: "empty", model: "anything"),
            baseline: SZProviderGenerationSettings())
        #expect(routed.substitutedModel == "anything")
    }

    @Test func fastModeClampsToTheRoutedModelsCapability() {
        let denied = TwoModelProvider().routedGenerationSettings(
            envelope: SZRouteEnvelope(providerID: "stub", model: "m-big", fastMode: true),
            baseline: SZProviderGenerationSettings())
        #expect(denied.settings.fastMode == false)   // m-big doesn't honour it

        let honoured = TwoModelProvider().routedGenerationSettings(
            envelope: SZRouteEnvelope(providerID: "stub", model: "m-fast", fastMode: true),
            baseline: SZProviderGenerationSettings())
        #expect(honoured.settings.fastMode == true)
    }

    @Test func anOffMenuEffortDegradesToTheModelsDefault() {
        let routed = TwoModelProvider().routedGenerationSettings(
            envelope: SZRouteEnvelope(providerID: "stub", model: "m-big", reasoningEffort: "bogus"),
            baseline: SZProviderGenerationSettings())
        #expect(routed.settings.reasoningEffort == "high")   // m-big's own default
        #expect(routed.substitutedModel == nil)              // efforts clamp silently, as stored rows do
    }
}
