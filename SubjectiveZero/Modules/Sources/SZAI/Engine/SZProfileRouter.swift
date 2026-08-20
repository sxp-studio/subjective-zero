// SPDX-License-Identifier: AGPL-3.0-only
// The profile-backed router — a finished lookup table. Every choice in it is already
// concrete: the host resolved the active profile's envelopes against the registry, the
// live catalogs, and the one clamp point, narrating anything it dropped. The router only
// looks up, so resolution is pure, synchronous, and table-testable.
import SZCore

/// Resolution, most specific first. Turns: this delivery's grade pick (a fleet child's,
/// primed by the host at dispatch), then the call's slot as the profile fills it, then the
/// app default. Queries resolve their ask slot the same way — grades never touch one (a
/// sorting question under a heavy task is still a sorting question).
public struct SZProfileRouter: SZModelRouting {
    /// The app default — today's provider + clamped settings, the cascade's floor.
    public var fallback: SZModelChoice
    /// agent id → slot id → the profile's resolved choice.
    public var agents: [String: [String: SZModelChoice]]
    /// THIS delivery's grade-selected choice — set only on a fleet child's copy, frozen at
    /// dispatch. The engine never learns about grading; the host primes the router.
    public var graded: SZModelChoice?

    public init(fallback: SZModelChoice, agents: [String: [String: SZModelChoice]] = [:],
                graded: SZModelChoice? = nil) {
        self.fallback = fallback
        self.agents = agents
        self.graded = graded
    }

    public func resolve(_ call: SZModelCall) -> SZModelChoice {
        if case .turn = call.class, let graded { return graded }
        return call.slot.flatMap { agents[call.agent]?[$0] } ?? fallback
    }

    /// The profile's choice for one (agent, slot); nil = unfilled.
    public func choice(agent: String, slot: String?) -> SZModelChoice? {
        slot.flatMap { agents[agent]?[$0] }
    }

    /// A fleet child's copy, primed with its task's grade pick (already resolved through
    /// the pack's grade → slot mapping by the host). nil changes nothing.
    public func primed(graded choice: SZModelChoice?) -> SZProfileRouter {
        var child = self
        child.graded = choice
        return child
    }
}

extension SZModelChoice {
    /// Session affinity: under an active profile, a resumed thread keeps the envelope that
    /// opened it — unless the route still names the same provider·model, in which case the
    /// live choice passes through so effort/fast changes keep retuning the thread (the
    /// setModel doctrine). Unrouted choices (`via == nil`) always pass through untouched:
    /// routing off is byte-identical to the pre-routing app.
    public func honoringSession(_ session: SZAgentSession?) -> SZModelChoice {
        guard via != nil, let pin = session?.envelope else { return self }
        if pin.providerID == providerID, pin.model == model { return self }
        return SZModelChoice(providerID: pin.providerID, model: pin.model,
                             reasoningEffort: pin.reasoningEffort,
                             fastMode: pin.fastMode ?? false, via: "session")
    }
}
