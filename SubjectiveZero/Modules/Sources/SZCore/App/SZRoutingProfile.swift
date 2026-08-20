// SPDX-License-Identifier: AGPL-3.0-only
// Named routing profiles — the data half of model routing (docs/AI_PROVIDERS.md). Agent
// graphs declare model slots; a profile fills them: (agent, slot) → generation envelope.
// Pure data, stored raw in app-state.json, validated at resolution time. An unfilled slot
// falls to the app default.

/// One route's generation envelope. Every field but the provider inherits when nil, so an
/// envelope can say as little as "codex" or as much as a full tune.
public struct SZRouteEnvelope: Codable, Equatable, Sendable {
    /// The provider that serves the route.
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

/// A named assignment of models to the graphs' declared slots. Keys are pack vocabulary
/// (agent id → slot id), so a profile survives node renames and rewires.
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
        // Pre-slot profile shapes carry keys this table can't map; they decode to empty.
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

    /// Merge one agent's slots from a fragment (a pack's recommended routes);
    /// `replacingExisting` false fills only unset slots.
    public func merging(_ fragment: [String: SZRouteEnvelope], agent: String,
                        replacingExisting: Bool) -> SZRoutingProfile {
        var merged = self
        for (slot, route) in fragment
        where replacingExisting || envelope(agent: agent, slot: slot) == nil {
            merged.setEnvelope(route, agent: agent, slot: slot)
        }
        return merged
    }
}
