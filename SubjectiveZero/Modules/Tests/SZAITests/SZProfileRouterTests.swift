// SPDX-License-Identifier: AGPL-3.0-only
// The profile router's cascade, as a table: turns resolve grade > agent row > the app
// default; queries resolve the one queries envelope or the default; an empty table is
// indistinguishable from the identity router. Session affinity is the choice's own rule
// (`honoringSession`): pinned threads keep their envelope unless the route still names the
// same provider·model — and unrouted choices always pass through untouched.
import Testing
import SZAI
import SZCore

private let fallback = SZModelChoice(providerID: "claude", model: "claude-opus-5",
                                     reasoningEffort: "high")

@Suite
struct SZProfileRouterTests {

    @Test func anEmptyTableAnswersEveryCallWithTheFallback() {
        let router = SZProfileRouter(fallback: fallback)
        for call in [SZModelCall(class: .turn, agent: "director"),
                     SZModelCall(class: .turn, agent: "coding"),
                     SZModelCall(class: .query, agent: "director")] {
            let choice = router.resolve(call)
            #expect(choice.providerID == "claude")
            #expect(choice.model == "claude-opus-5")
            #expect(choice.via == nil)   // the fallback is the default, not a route
        }
    }

    @Test func anAgentRowCatchesEveryTurnOfThatAgent() {
        let codex = SZModelChoice(providerID: "codex", via: "fast-fleet · coding")
        let router = SZProfileRouter(fallback: fallback, agents: ["coding": codex])

        #expect(router.resolve(SZModelCall(class: .turn, agent: "coding")).providerID == "codex")
        // Another agent's turns stay on the default.
        #expect(router.resolve(SZModelCall(class: .turn, agent: "director")).providerID == "claude")
    }

    @Test func aPrimedGradeBeatsTheAgentRow() {
        let heavy = SZModelChoice(providerID: "claude", model: "claude-opus-5",
                                  fastMode: true, via: "p · heavy")
        let router = SZProfileRouter(
            fallback: fallback,
            agents: ["coding": SZModelChoice(providerID: "codex", via: "p · coding")],
            grades: ["heavy": heavy])

        // Unprimed: the agent row wins as usual.
        #expect(router.resolve(SZModelCall(class: .turn, agent: "coding")).providerID == "codex")
        // Primed for this delivery (a fleet child whose task the Director graded heavy).
        let primed = router.primed(grade: "heavy")
        #expect(primed.resolve(SZModelCall(class: .turn, agent: "coding")).fastMode == true)
        // Priming with an unmapped grade changes nothing — the rung simply doesn't match.
        #expect(router.primed(grade: "light")
                    .resolve(SZModelCall(class: .turn, agent: "coding")).providerID == "codex")
    }

    @Test func gradesNeverTouchAQuery() {
        let small = SZModelChoice(providerID: "claude", model: "claude-haiku-4-5", via: "p · queries")
        let router = SZProfileRouter(
            fallback: fallback, queries: small,
            agents: ["director": SZModelChoice(providerID: "codex", via: "p · director")],
            grades: ["heavy": SZModelChoice(providerID: "grok", via: "p · heavy")])

        // A triage ask under a heavy task is still a triage ask.
        #expect(router.primed(grade: "heavy")
                    .resolve(SZModelCall(class: .query, agent: "director"))
                    .model == "claude-haiku-4-5")
        // No queries envelope → the default, not the agent's turn route.
        let bare = SZProfileRouter(fallback: fallback,
                                   agents: ["director": SZModelChoice(providerID: "codex", via: "p")])
        #expect(bare.resolve(SZModelCall(class: .query, agent: "director")).providerID == "claude")
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
