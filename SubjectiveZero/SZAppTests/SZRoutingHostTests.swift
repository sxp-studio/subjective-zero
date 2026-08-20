// SPDX-License-Identifier: AGPL-3.0-only
// The host's routing resolution on a bare host: profile selection (app-state vs the launch
// pin), envelope → concrete-choice resolution with its narrated drops, the once-per-state
// note dedupe, and the byte-identity of the no-profile router. State is assigned directly —
// the persisting mutators write the real app-state.json and belong to the live QA pass.
import Foundation
import Testing
import SZAI
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZRoutingHostTests {

    /// A host whose routing state is exactly what the test says — nothing inherited from
    /// this machine's real app-state.json.
    private func bareHost(profiles: [SZRoutingProfile] = [], active: String? = nil) -> SZHost {
        let host = SZHost()
        host.routingProfiles = profiles
        host.activeRoutingProfileName = active
        host.disabledProviderIDs = []
        host.narratedRoutingNotes = []
        return host
    }

    private var fastFleet: SZRoutingProfile {
        SZRoutingProfile(
            name: "fast-fleet",
            agents: ["director": ["planner": SZRouteEnvelope(providerID: "claude")],
                     "coding": ["builder-default": SZRouteEnvelope(providerID: "codex")]])
    }

    // MARK: - Selection

    @Test func noActiveProfileMeansRoutingOff() throws {
        let host = bareHost(profiles: [fastFleet], active: nil)
        #expect(try host.activeRoutingProfile(env: nil) == nil)
    }

    @Test func aStalePersistedNameDegradesToOff() throws {
        // The stored-raw rule: a name whose profile was deleted elsewhere is a stale
        // preference, not an error.
        let host = bareHost(profiles: [], active: "gone")
        #expect(try host.activeRoutingProfile(env: nil) == nil)
    }

    @Test func theKillSwitchBeatsThePersistedActiveName() throws {
        let host = bareHost(profiles: [fastFleet], active: "fast-fleet")
        #expect(try host.activeRoutingProfile(env: "0") == nil)
        #expect(try host.activeRoutingProfile(env: nil)?.name == "fast-fleet")
        #expect(try host.activeRoutingProfile(env: "1")?.name == "fast-fleet")
    }

    @Test func anEnvPinNamesItsProfileOrRefuses() {
        let host = bareHost(profiles: [fastFleet], active: nil)
        #expect((try? host.activeRoutingProfile(env: "fast-fleet"))?.name == "fast-fleet")
        // An unknown env name REFUSES rather than guessing (the SZ_AGENT_PACKS rule).
        #expect(throws: SZRoutingRefusal.self) {
            try host.activeRoutingProfile(env: "no-such-profile")
        }
    }

    // MARK: - The no-profile router is the identity tuple

    @Test func withNoProfileTheRouterIsTheIdentityTuple() throws {
        let host = bareHost()
        let (router, notes) = try host.makeRouter(providerID: "claude")
        #expect(notes.isEmpty)
        let choice = router.resolve(SZModelCall(class: .turn, agent: "director"))
        // Exactly the tuple the lanes used to derive: the provider's clamped stored row.
        let generation = host.resolvedGenerationSettings(for: "claude")
        #expect(choice.providerID == "claude")
        #expect(choice.model == generation.model)
        #expect(choice.reasoningEffort == generation.reasoningEffort)
        #expect(choice.fastMode == (generation.fastMode ?? false))
        #expect(choice.via == nil)
    }

    // MARK: - Table resolution

    @Test func aProfileRoutesItsAgentsAndStampsProvenance() throws {
        let host = bareHost(profiles: [fastFleet], active: "fast-fleet")
        let (router, notes) = try host.makeRouter(providerID: "claude")
        #expect(notes.isEmpty)
        let coding = router.resolve(SZModelCall(class: .turn, agent: "coding", slot: "builder-default"))
        #expect(coding.providerID == "codex")
        #expect(coding.via == "fast-fleet · coding · builder-default")
        // A slot the profile doesn't fill — and any slotless turn — rides the fallback.
        let debug = router.resolve(SZModelCall(class: .turn, agent: "debug", slot: "assistant"))
        #expect(debug.providerID == "claude")
        #expect(debug.via == nil)
    }

    @Test func anUnknownProviderDropsItsRungWithASentence() throws {
        var profile = fastFleet
        profile.agents["coding"] = ["builder-default": SZRouteEnvelope(providerID: "no-such-cli")]
        let host = bareHost(profiles: [profile], active: "fast-fleet")
        let (router, notes) = try host.makeRouter(providerID: "claude")
        // The slot is gone — its turns fall to the default — and the drop is a sentence.
        #expect(router.resolve(SZModelCall(class: .turn, agent: "coding", slot: "builder-default"))
                    .providerID == "claude")
        #expect(notes.count == 1)
        #expect(notes[0].contains("no-such-cli"))
        #expect(notes[0].contains("AI Settings"))
    }

    @Test func anOffCatalogModelRunsTheClampWithASentence() throws {
        var profile = fastFleet
        profile.agents["coding"] = ["builder-default": SZRouteEnvelope(providerID: "codex", model: "gpt-imaginary")]
        let host = bareHost(profiles: [profile], active: "fast-fleet")
        let (router, notes) = try host.makeRouter(providerID: "claude")
        // The provider still serves the turn — on a model it actually lists.
        let coding = router.resolve(SZModelCall(class: .turn, agent: "coding", slot: "builder-default"))
        #expect(coding.providerID == "codex")
        #expect(coding.model != "gpt-imaginary")
        #expect(notes.count == 1)
        #expect(notes[0].contains("gpt-imaginary"))
    }

    @Test func aSentenceIsSaidOncePerProfileState() throws {
        var profile = fastFleet
        profile.agents["coding"] = ["builder-default": SZRouteEnvelope(providerID: "no-such-cli")]
        let host = bareHost(profiles: [profile], active: "fast-fleet")
        #expect(try host.makeRouter(providerID: "claude").notes.count == 1)
        // The next delivery resolves the same drop silently — the user already read it.
        #expect(try host.makeRouter(providerID: "claude").notes.isEmpty)
        // A profile-state change says it again.
        host.narratedRoutingNotes = []
        #expect(try host.makeRouter(providerID: "claude").notes.count == 1)
    }

    @Test func aGradeIsWriteWinsUntilDispatchThenFrozen() {
        let host = bareHost()
        let node = SZNodeID()
        host.recordNodeGrade(node, "light")
        host.recordNodeGrade(node, "heavy")   // a reconcile re-brief may regrade
        #expect(host.nodeGrades[node] == "heavy")
        host.dispatchPrompts[node] = "built"  // a coding turn ran for it
        host.recordNodeGrade(node, "light")   // frozen — the retry must resolve identically
        #expect(host.nodeGrades[node] == "heavy")
        // A FIRST grade arriving after dispatch is refused for the same reason.
        let late = SZNodeID()
        host.dispatchPrompts.updateValue(nil, forKey: late)   // dispatched promptless (key present)
        host.recordNodeGrade(late, "light")
        #expect(host.nodeGrades[late] == nil)
    }

    @Test func sorterAndGradeSlotsResolveIntoTheTable() throws {
        var profile = fastFleet
        profile.setEnvelope(SZRouteEnvelope(providerID: "claude", model: "claude-haiku-4-5"),
                            agent: "coding", slot: "sorter")
        profile.setEnvelope(SZRouteEnvelope(providerID: "claude", model: "claude-opus-5"),
                            agent: "coding", slot: "builder-heavy")
        let host = bareHost(profiles: [profile], active: "fast-fleet")
        let (router, notes) = try host.makeRouter(providerID: "claude")
        #expect(notes.isEmpty)
        // The sorter slot serves the door's questions.
        #expect(router.resolve(SZModelCall(class: .query, agent: "coding", slot: "sorter"))
                    .model == "claude-haiku-4-5")
        // The grade path: the host resolves a grade through the pack's mapping into a
        // choice and primes the child router with it.
        guard let table = router as? SZProfileRouter else {
            Issue.record("expected the profile router"); return
        }
        let heavy = table.choice(agent: "coding", slot: "builder-heavy")
        #expect(heavy?.model == "claude-opus-5")
        #expect(table.primed(graded: heavy)
                    .resolve(SZModelCall(class: .turn, agent: "coding", slot: "builder-default"))
                    .model == "claude-opus-5")
    }

    // MARK: - The Routing pane's mapping

    @Test func creationActivatesOnlyIntoSilence() {
        // Fill silence, never steal a running arm, defer to the launch env in every form.
        #expect(SZHost.createShouldActivate(active: nil, env: nil))
        #expect(SZHost.createShouldActivate(active: nil, env: "1"))
        #expect(!SZHost.createShouldActivate(active: nil, env: "0"))
        #expect(!SZHost.createShouldActivate(active: nil, env: "fast-fleet"))
        #expect(!SZHost.createShouldActivate(active: "fast-fleet", env: nil))
    }

    @Test func offCardsStateEachSlotsLiveResolutionWithNothingPickable() {
        // The Off row (and the no-profiles empty state): every row is resolve-only — the
        // full "Default (…)" truth as its label, no options for the pane to render.
        let host = bareHost()
        let cards = host.routingAgentCards(editedName: nil)
        #expect(!cards.isEmpty)
        for row in cards.flatMap(\.rows) {
            #expect(!row.isSet && row.options.isEmpty)
            #expect(row.selectionLabel.hasPrefix("Default ("))
            #expect(row.selectionLabel == row.clearLabel)
        }
        // A vanished requested name resolves the same way — never a phantom profile.
        #expect(host.routingAgentCards(editedName: "gone").flatMap(\.rows).allSatisfy { !$0.isSet })
    }

    @Test func editedProfileCardsKeepTheOneWordDefaultOnUnsetRows() {
        let host = bareHost(profiles: [fastFleet], active: nil)
        let rows = host.routingAgentCards(editedName: "fast-fleet").flatMap(\.rows)
        // Filled positions read their envelope; unfilled ones the one-word "Default" with
        // the live resolution kept to the menu's clear row.
        #expect(rows.contains { $0.isSet })
        let unset = rows.filter { !$0.isSet }
        #expect(!unset.isEmpty)
        for row in unset {
            #expect(row.selectionLabel == "Default")
            #expect(row.clearLabel.hasPrefix("Default ("))
            #expect(!row.options.isEmpty)
        }
    }
}
