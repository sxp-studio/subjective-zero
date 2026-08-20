// SPDX-License-Identifier: AGPL-3.0-only
// Named routing profiles — the data half of model routing (docs/AI_PROVIDERS.md). A profile
// maps graph positions to generation envelopes: an optional envelope per agent, finer ones
// per duty word (the work-kind label a turn node declares), three grade envelopes for
// dispatched fleet work, and one for step queries. Pure data, stored raw in app-state.json
// and validated at resolution time like every preference — never a node id, never a
// capability fact (those live in Providers/).

/// One route's generation envelope. Every field but the provider inherits when nil, so an
/// envelope can say as little as "codex" or as much as a full tune. Extensible: a future
/// knob is one more optional field, and tolerant decode means no schema churn.
public struct SZRouteEnvelope: Codable, Equatable, Sendable {
    /// The provider that serves the route — an envelope that names no provider routes nothing.
    public var providerID: String
    /// nil = the provider's stored selection (and its clamp) decides.
    public var model: String?
    public var reasoningEffort: String?
    public var fastMode: Bool?

    public init(providerID: String, model: String? = nil, reasoningEffort: String? = nil,
                fastMode: Bool? = nil) {
        self.providerID = providerID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.fastMode = fastMode
    }
}

/// A named, complete routing table. Positions are the agent graphs' own vocabulary — agent
/// ids and duty words — so a profile survives every graph rename and rewire; anything it
/// doesn't map falls back one rung (duty → agent → the app default): coarser, never wrong.
public struct SZRoutingProfile: Codable, Equatable, Sendable, Identifiable {
    /// The profile's identity — what AI Settings lists and SZ_MODEL_ROUTING names.
    public var name: String
    public var id: String { name }
    /// Every step ask, all agents — the small stateless completions.
    public var queries: SZRouteEnvelope?
    /// The Director's grade envelopes for dispatched fleet work (light / standard / heavy).
    public var light: SZRouteEnvelope?
    public var standard: SZRouteEnvelope?
    public var heavy: SZRouteEnvelope?
    /// Per-agent routes, keyed by agent (pack) id.
    public var agents: [String: AgentRoutes]

    public struct AgentRoutes: Codable, Equatable, Sendable {
        /// Every turn of this agent — the floor its duties refine.
        public var all: SZRouteEnvelope?
        /// Finer grain, keyed by the duty words the agent's graph declares.
        public var duties: [String: SZRouteEnvelope]?

        public init(all: SZRouteEnvelope? = nil, duties: [String: SZRouteEnvelope]? = nil) {
            self.all = all
            self.duties = duties
        }
    }

    public init(name: String, queries: SZRouteEnvelope? = nil, light: SZRouteEnvelope? = nil,
                standard: SZRouteEnvelope? = nil, heavy: SZRouteEnvelope? = nil,
                agents: [String: AgentRoutes] = [:]) {
        self.name = name
        self.queries = queries
        self.light = light
        self.standard = standard
        self.heavy = heavy
        self.agents = agents
    }

    /// The grade vocabulary, fixed: the Director's assessment can only say these three words.
    public static let grades = ["light", "standard", "heavy"]

    /// The envelope a grade word selects; nil for an unmapped (or unknown) grade — the
    /// grade rung simply doesn't match.
    public func gradeEnvelope(_ grade: String) -> SZRouteEnvelope? {
        switch grade {
        case "light": light
        case "standard": standard
        case "heavy": heavy
        default: nil
        }
    }
}
