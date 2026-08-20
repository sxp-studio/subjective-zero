// SPDX-License-Identifier: AGPL-3.0-only
// Named routing profiles — the data half of model routing (docs/AI_PROVIDERS.md). The agent
// graphs declare MODEL SLOTS (the kinds of model work they need); a profile fills them:
// (agent, slot) → generation envelope. Pure data, stored raw in app-state.json and validated
// at resolution time like every preference. An unfilled slot falls to the app default —
// coarser, never wrong — so a profile need only say what it means.

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

/// A named assignment of models to the graphs' declared slots. Keys are the packs' own
/// vocabulary — agent id → slot id — so a profile survives every node rename and rewire,
/// and can only go stale as loudly as an unfilled row in the settings pane.
public struct SZRoutingProfile: Codable, Equatable, Sendable, Identifiable {
    /// The profile's identity — what AI Settings lists and SZ_MODEL_ROUTING names.
    public var name: String
    /// agent id → slot id → envelope. Slots a profile doesn't fill run the app default.
    public var agents: [String: [String: SZRouteEnvelope]]

    public init(name: String, agents: [String: [String: SZRouteEnvelope]] = [:]) {
        self.name = name
        self.agents = agents
    }

    public var id: String { name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        // Pre-slot profile shapes (per-agent envelopes, grade/queries fields) carry keys
        // the slot world can't honestly map — they decode to an empty table, never a guess.
        agents = (try? c.decodeIfPresent([String: [String: SZRouteEnvelope]].self,
                                         forKey: .agents)) ?? [:]
    }

    private enum CodingKeys: String, CodingKey { case name, agents }

    /// The Director's grade vocabulary, fixed — packs map these words to their own slots.
    public static let grades = ["light", "standard", "heavy"]

    public func envelope(agent: String, slot: String) -> SZRouteEnvelope? {
        agents[agent]?[slot]
    }

    public mutating func setEnvelope(_ envelope: SZRouteEnvelope?, agent: String, slot: String) {
        var slots = agents[agent] ?? [:]
        slots[slot] = envelope
        agents[agent] = slots.isEmpty ? nil : slots
    }
}
