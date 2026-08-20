// SPDX-License-Identifier: AGPL-3.0-only
// The profile-backed router — a finished lookup table. Every choice in it is already
// concrete: the host resolved the active profile's envelopes against the registry, the
// live catalogs, and the one clamp point, narrating anything it dropped. The router only
// looks up, so resolution is pure, synchronous, and table-testable.
import SZCore

/// Resolution, most specific first. Turns: this delivery's grade pick, then the turn's
/// duty word, then the agent's floor, then the app default. Queries: the profile's one
/// queries envelope, else the default — grades and duties never touch a query (a triage
/// ask under a heavy node is still a triage ask).
public struct SZProfileRouter: SZModelRouting {
    /// The app default — today's provider + clamped settings, the cascade's floor.
    public var fallback: SZModelChoice
    /// Every step ask, all agents.
    public var queries: SZModelChoice?
    /// Agent id → its every-turn choice.
    public var agents: [String: SZModelChoice]
    /// "agent/duty-word" → choice.
    public var duties: [String: SZModelChoice]
    /// Grade word → choice, for priming fleet children.
    public var grades: [String: SZModelChoice]
    /// THIS delivery's grade-selected choice — set only on a fleet child's copy, frozen at
    /// dispatch. The engine never learns about grading; the host primes the router.
    public var graded: SZModelChoice?

    public init(fallback: SZModelChoice, queries: SZModelChoice? = nil,
                agents: [String: SZModelChoice] = [:], duties: [String: SZModelChoice] = [:],
                grades: [String: SZModelChoice] = [:], graded: SZModelChoice? = nil) {
        self.fallback = fallback
        self.queries = queries
        self.agents = agents
        self.duties = duties
        self.grades = grades
        self.graded = graded
    }

    public func resolve(_ call: SZModelCall) -> SZModelChoice {
        switch call.class {
        case .query:
            return queries ?? fallback
        case .turn:
            if let graded { return graded }
            if let duty = call.duty, let hit = duties["\(call.agent)/\(duty)"] { return hit }
            return agents[call.agent] ?? fallback
        }
    }

    /// A fleet child's copy, primed with its node's grade pick. An unmapped grade word
    /// changes nothing — the grade rung simply doesn't match.
    public func primed(grade: String) -> SZProfileRouter {
        var child = self
        child.graded = grades[grade]
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
