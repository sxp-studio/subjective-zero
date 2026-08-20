// SPDX-License-Identifier: AGPL-3.0-only
// The profile router's cascade, as a table: a fleet child's primed grade pick, then the
// call's slot as the profile fills it, then the app default; queries resolve their ask slot
// the same way. An empty table is indistinguishable from the identity router. Session
// affinity is the choice's own rule (`honoringSession`): pinned threads keep their envelope
// unless the route still names the same provider·model — unrouted choices pass through.
import Testing
import SZAI
import SZCore

private let fallback = SZModelChoice(providerID: "claude", model: "claude-opus-5",
                                     reasoningEffort: "high")

@Suite
struct SZProfileRouterTests {

    @Test func anEmptyTableAnswersEveryCallWithTheFallback() {
        let router = SZProfileRouter(fallback: fallback)
        for call in [SZModelCall(class: .turn, agent: "director", slot: "planner"),
                     SZModelCall(class: .turn, agent: "coding"),
                     SZModelCall(class: .query, agent: "director", slot: "sorter")] {
            let choice = router.resolve(call)
            #expect(choice.providerID == "claude")
            #expect(choice.model == "claude-opus-5")
            #expect(choice.via == nil)   // the fallback is the default, not a route
        }
    }

    @Test func aFilledSlotServesItsCallsAndOnlyThem() {
        let codex = SZModelChoice(providerID: "codex", via: "p · coding/builder-default")
        let router = SZProfileRouter(
            fallback: fallback,
            agents: ["coding": ["builder-default": codex]])

        #expect(router.resolve(SZModelCall(class: .turn, agent: "coding", slot: "builder-default"))
                    .providerID == "codex")
        // An unfilled slot of the same agent, a slotless turn, and another agent's slot of
        // the same name all ride the fallback — (agent, slot) is the whole key.
        #expect(router.resolve(SZModelCall(class: .turn, agent: "coding", slot: "assistant"))
                    .providerID == "claude")
        #expect(router.resolve(SZModelCall(class: .turn, agent: "coding")).providerID == "claude")
        #expect(router.resolve(SZModelCall(class: .turn, agent: "director", slot: "builder-default"))
                    .providerID == "claude")
    }

    @Test func aPrimedGradeBeatsTheSlot() {
        let heavy = SZModelChoice(providerID: "claude", model: "claude-opus-5",
                                  fastMode: true, via: "p · coding/builder-heavy")
        let router = SZProfileRouter(
            fallback: fallback,
            agents: ["coding": ["builder-default": SZModelChoice(providerID: "codex", via: "p")]])

        // Unprimed: the turn's slot wins as usual.
        #expect(router.resolve(SZModelCall(class: .turn, agent: "coding", slot: "builder-default"))
                    .providerID == "codex")
        // Primed for this delivery (a fleet child whose task the Director graded heavy —
        // the host already resolved the grade through the pack's mapping).
        let primed = router.primed(graded: heavy)
        #expect(primed.resolve(SZModelCall(class: .turn, agent: "coding", slot: "builder-default"))
                    .fastMode == true)
        // Priming with nil changes nothing.
        #expect(router.primed(graded: nil)
                    .resolve(SZModelCall(class: .turn, agent: "coding", slot: "builder-default"))
                    .providerID == "codex")
    }

    @Test func aGradeNeverTouchesAQuery() {
        let small = SZModelChoice(providerID: "claude", model: "claude-haiku-4-5", via: "p · sorter")
        let router = SZProfileRouter(
            fallback: fallback,
            agents: ["coding": ["sorter": small]],
            graded: SZModelChoice(providerID: "grok", via: "p · heavy"))

        // A sorting question under a heavy task is still a sorting question.
        #expect(router.resolve(SZModelCall(class: .query, agent: "coding", slot: "sorter"))
                    .model == "claude-haiku-4-5")
        // A slotless ask rides the fallback, never the graded pick.
        #expect(router.resolve(SZModelCall(class: .query, agent: "coding")).providerID == "claude")
    }
}

@Suite
struct SZSessionAffinityTests {

    private let session = SZAgentSession(
        providerID: "claude", sessionID: "s-1",
        envelope: SZRouteEnvelope(providerID: "claude", model: "claude-opus-5",
                                  reasoningEffort: "high", fastMode: false))

    @Test func anUnroutedChoicePassesThroughUntouched() {
        // Routing off (via == nil) = the pre-routing app, byte-identical: the pin is inert
        // even when it disagrees (the catalog-drift edge stays exactly as it was).
        let choice = SZModelChoice(providerID: "claude", model: "claude-sonnet-5")
        let resolved = choice.honoringSession(session)
        #expect(resolved.model == "claude-sonnet-5")
        #expect(resolved.via == nil)
    }

    @Test func aRoutedResumeKeepsThePinWhenTheRouteMoved() {
        let moved = SZModelChoice(providerID: "codex", model: "gpt-5.6-terra", via: "p · coding")
        let resolved = moved.honoringSession(session)
        #expect(resolved.providerID == "claude")
        #expect(resolved.model == "claude-opus-5")
        #expect(resolved.reasoningEffort == "high")
        #expect(resolved.via == "session")
    }

    @Test func aRouteStillNamingTheThreadsModelPassesLiveSettings() {
        // Same provider·model: live effort/fast retune the thread (the setModel doctrine).
        let retuned = SZModelChoice(providerID: "claude", model: "claude-opus-5",
                                    reasoningEffort: "low", fastMode: true, via: "p · director")
        let resolved = retuned.honoringSession(session)
        #expect(resolved.reasoningEffort == "low")
        #expect(resolved.fastMode == true)
        #expect(resolved.via == "p · director")
    }

    @Test func aColdStartAndAPinlessSessionResolveTheRoute() {
        let routed = SZModelChoice(providerID: "codex", via: "p · coding")
        #expect(routed.honoringSession(nil).providerID == "codex")
        // A pre-routing session file (no envelope) can't pin — the route runs.
        let legacy = SZAgentSession(providerID: "claude", sessionID: "s-0")
        #expect(routed.honoringSession(legacy).providerID == "codex")
    }
}
