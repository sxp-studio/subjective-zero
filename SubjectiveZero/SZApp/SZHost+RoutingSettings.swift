// SPDX-License-Identifier: AGPL-3.0-only
// The Routing pane's host mapping — profiles and graph positions distilled to the plain rows
// SZUI may see (it can't import SZAI), and the pane's intents translated back into profile
// edits through `upsertRoutingProfile` (one write path, one persistence story). Position
// tokens are owned HERE: "agent:<id>", "duty:<agent>/<word>", "queries", "grade:<word>" —
// the view treats them as opaque. Envelope options mirror the provider-card rules: only
// healthy providers selectable, dimmed rows carry their reason in the label.
import Foundation
import SZAI
import SZCore
import SZUI

extension SZHost {
    // MARK: - What the pane reads

    var routingProfileRows: [SZRoutingProfileRow] {
        routingProfiles.map { SZRoutingProfileRow(name: $0.name, isActive: $0.name == activeRoutingProfileName) }
    }

    /// The env pin, pre-mapped for the sheet: nil unless SZ_MODEL_ROUTING names a profile
    /// ("0"/"1" steer routing on/off without pinning a name).
    var routingEnvPinnedProfileName: String? {
        Self.modelRoutingEnv.flatMap { $0 == "0" || $0 == "1" ? nil : $0 }
    }

    /// The profile the form edits: the requested name when it still exists, else the active
    /// one, else the first saved profile. nil = nothing to edit (no profiles at all).
    func routingEditedProfile(named requested: String?) -> SZRoutingProfile? {
        let byName: (String) -> SZRoutingProfile? = { name in
            self.routingProfiles.first { $0.name == name }
        }
        return requested.flatMap(byName) ?? activeRoutingProfileName.flatMap(byName)
            ?? routingProfiles.first
    }

    /// The mapping form's rows for the edited profile: per agent a header row + one row per
    /// duty word its graph declares, then the top-level queries row and the three grades.
    func routingPositionRows(profileNamed requested: String?) -> [SZRoutingPositionRow] {
        guard let profile = routingEditedProfile(named: requested) else { return [] }
        var rows: [SZRoutingPositionRow] = []
        for agent in agentGraphPlanAgents() {
            let routes = profile.agents[agent.id]
            rows.append(routingRow(id: "agent:\(agent.id)", label: agent.title,
                                   symbol: agent.symbol, envelope: routes?.all))
            for (word, usedBy) in Self.routingDutyWords(of: agent.graph) {
                rows.append(routingRow(id: "duty:\(agent.id)/\(word)",
                                       label: word.prefix(1).uppercased() + word.dropFirst(),
                                       caption: "used by: \(usedBy.joined(separator: ", "))",
                                       envelope: routes?.duties?[word]))
            }
        }
        rows.append(routingRow(id: "queries", label: "Queries",
                               caption: "Every agent's quick triage questions",
                               envelope: profile.queries))
        for grade in SZRoutingProfile.grades {
            rows.append(routingRow(id: "grade:\(grade)",
                                   label: grade.prefix(1).uppercased() + grade.dropFirst(),
                                   envelope: profile.gradeEnvelope(grade)))
        }
        return rows
    }

    /// A graph's duty vocabulary with the turn titles that declare each word — the caption's
    /// "used by: Decompose, Amend". Sorted so the form is stable across loads.
    nonisolated private static func routingDutyWords(of graph: SZAgentGraph)
        -> [(word: String, usedBy: [String])] {
        var map: [String: [String]] = [:]
        for node in graph.nodes {
            guard case .turn(let turn) = node.form, let duty = turn.duty else { continue }
            map[duty, default: []].append(node.title ?? node.id)
        }
        return map.keys.sorted().map { ($0, map[$0] ?? []) }
    }

    /// One position row: selection label, options, and — only when an envelope is set — the
    /// effort/fast surface of the ROUTED model, so the pane never renders a control the
    /// model can't honour.
    private func routingRow(id: String, label: String, symbol: String? = nil,
                            caption: String? = nil, envelope: SZRouteEnvelope?)
        -> SZRoutingPositionRow {
        let options = routingEnvelopeOptions(selected: envelope)
        guard let envelope else {
            return SZRoutingPositionRow(id: id, label: label, symbol: symbol, caption: caption,
                                        selectionLabel: "Default", isSet: false, options: options)
        }
        let provider = SZProviderRegistry.shared.provider(id: envelope.providerID)
        // The model the route actually runs: the envelope's pin, else the provider's own
        // resolved selection. Raw-id fallbacks keep a stale route visible, never blank.
        let routedModel = envelope.model
            ?? provider.map { resolvedGenerationSettings(for: $0.id).model ?? $0.defaultModel }
            ?? ""
        let modelLabel = provider?.models.first { $0.id == routedModel }?.displayName ?? routedModel
        let selectionLabel = [provider?.displayName ?? envelope.providerID, modelLabel]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return SZRoutingPositionRow(
            id: id, label: label, symbol: symbol, caption: caption,
            selectionLabel: selectionLabel, isSet: true, options: options,
            effortOptions: provider?.supportedReasoningEfforts(for: routedModel) ?? [],
            selectedEffort: envelope.reasoningEffort,
            supportsFastMode: provider?.supportsFastMode(for: routedModel) ?? false,
            fastModeEnabled: envelope.fastMode ?? false)
    }

    /// Every provider·model pair, in registry order — the same health/disable rules as the
    /// provider cards: a dimmed row says why in its label (menu rows carry no tooltip).
    private func routingEnvelopeOptions(selected: SZRouteEnvelope?) -> [SZRoutingEnvelopeOption] {
        SZProviderRegistry.shared.providers.flatMap { provider -> [SZRoutingEnvelopeOption] in
            let disabled = disabledProviderIDs.contains(provider.id)
            let status = displayedProviderHealth(provider.id)?.status
            let enabled = !disabled
                && (status == nil || status == .ready)   // unknown stays permissive, like the pre-flights
            let reason = disabled ? " (disabled)" : (enabled ? "" : Self.routingHealthSuffix(status))
            func option(_ modelID: String?, _ modelLabel: String?) -> SZRoutingEnvelopeOption {
                let label = ([provider.displayName] + (modelLabel.map { [$0] } ?? []))
                    .joined(separator: " · ") + reason
                return SZRoutingEnvelopeOption(
                    providerID: provider.id, modelID: modelID, label: label,
                    isSelected: selected?.providerID == provider.id && selected?.model == modelID,
                    isEnabled: enabled)
            }
            // A catalog-less provider (dynamic, pre-fetch) still offers itself: one row whose
            // envelope pins no model, so the provider's own selection decides.
            guard !provider.models.isEmpty else { return [option(nil, nil)] }
            return provider.models.map { option($0.id, $0.displayName) }
        }
    }

    nonisolated private static func routingHealthSuffix(_ status: SZProviderHealthStatus?) -> String {
        switch status {
        case .missingCLI: " (not installed)"
        case .authNeeded: " (needs login)"
        case .healthFailed: " (failing)"
        case .invalidConfig, .unsupported: " (unavailable)"
        case .ready, nil: ""
        }
    }

    // MARK: - What the pane writes (position token → profile edit)

    /// Assign a position's envelope; providerID nil clears it back to Default. Re-picking a
    /// provider·model starts a fresh envelope — an effort tuned for the old model is not
    /// carried onto one it may not fit.
    func assignRoutingEnvelope(profileNamed requested: String?, position: String,
                               providerID: String?, modelID: String?) {
        guard var profile = routingEditedProfile(named: requested) else { return }
        let envelope = providerID.map { SZRouteEnvelope(providerID: $0, model: modelID) }
        Self.writeRouteEnvelope(envelope, at: position, in: &profile)
        upsertRoutingProfile(profile)
    }

    /// Retune a SET position's reasoning effort (nil = the provider's own selection decides).
    func setRoutingPositionEffort(profileNamed requested: String?, position: String, effort: String?) {
        guard var profile = routingEditedProfile(named: requested),
              var envelope = Self.readRouteEnvelope(at: position, of: profile) else { return }
        envelope.reasoningEffort = effort
        Self.writeRouteEnvelope(envelope, at: position, in: &profile)
        upsertRoutingProfile(profile)
    }

    /// Toggle a SET position's fast mode — the pane only offers this where the routed model
    /// honours it.
    func setRoutingPositionFastMode(profileNamed requested: String?, position: String, enabled: Bool) {
        guard var profile = routingEditedProfile(named: requested),
              var envelope = Self.readRouteEnvelope(at: position, of: profile) else { return }
        envelope.fastMode = enabled
        Self.writeRouteEnvelope(envelope, at: position, in: &profile)
        upsertRoutingProfile(profile)
    }

    nonisolated private static func readRouteEnvelope(at position: String, of profile: SZRoutingProfile)
        -> SZRouteEnvelope? {
        switch position {
        case "queries": return profile.queries
        case let p where p.hasPrefix("grade:"): return profile.gradeEnvelope(String(p.dropFirst(6)))
        case let p where p.hasPrefix("agent:"): return profile.agents[String(p.dropFirst(6))]?.all
        case let p where p.hasPrefix("duty:"):
            guard let (agent, word) = dutyToken(p) else { return nil }
            return profile.agents[agent]?.duties?[word]
        default: return nil
        }
    }

    nonisolated private static func writeRouteEnvelope(_ envelope: SZRouteEnvelope?, at position: String,
                                                       in profile: inout SZRoutingProfile) {
        switch position {
        case "queries": profile.queries = envelope
        case "grade:light": profile.light = envelope
        case "grade:standard": profile.standard = envelope
        case "grade:heavy": profile.heavy = envelope
        case let p where p.hasPrefix("agent:"):
            let agent = String(p.dropFirst(6))
            var routes = profile.agents[agent] ?? .init()
            routes.all = envelope
            profile.agents[agent] = routes.all == nil && (routes.duties?.isEmpty ?? true) ? nil : routes
        case let p where p.hasPrefix("duty:"):
            guard let (agent, word) = dutyToken(p) else { return }
            var routes = profile.agents[agent] ?? .init()
            var duties = routes.duties ?? [:]
            duties[word] = envelope
            routes.duties = duties.isEmpty ? nil : duties
            profile.agents[agent] = routes.all == nil && duties.isEmpty ? nil : routes
        default: break
        }
    }

    /// "duty:director/plan" → ("director", "plan"). Split on the FIRST slash — duty words
    /// carry none (the wire grammar), agent ids could someday.
    nonisolated private static func dutyToken(_ position: String) -> (agent: String, word: String)? {
        let body = position.dropFirst("duty:".count)
        guard let slash = body.firstIndex(of: "/") else { return nil }
        return (String(body[..<slash]), String(body[body.index(after: slash)...]))
    }

    // MARK: - Profile lifecycle (the bar's New / Rename / Duplicate)

    /// Create an empty profile under a fresh name; returns the name so the caller can select
    /// it for edit.
    @discardableResult
    func createRoutingProfile() -> String {
        let name = routingUniqueName("Profile")
        upsertRoutingProfile(SZRoutingProfile(name: name))
        return name
    }

    /// Copy a profile's whole table under a fresh name; nil when the source vanished.
    @discardableResult
    func duplicateRoutingProfile(named source: String) -> String? {
        guard var copy = routingProfiles.first(where: { $0.name == source }) else { return nil }
        copy.name = routingUniqueName("\(source) Copy")
        upsertRoutingProfile(copy)
        return copy.name
    }

    /// Rename in place — the active pointer follows, so renaming the active profile never
    /// turns routing off. Refused for an empty or already-taken name.
    @discardableResult
    func renameRoutingProfile(from old: String, to newRaw: String) -> Bool {
        let new = newRaw.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old,
              let index = routingProfiles.firstIndex(where: { $0.name == old }),
              !routingProfiles.contains(where: { $0.name == new }) else { return false }
        routingProfiles[index].name = new
        if activeRoutingProfileName == old { activeRoutingProfileName = new }
        narratedRoutingNotes.removeAll()
        persistAppState()
        return true
    }

    private func routingUniqueName(_ base: String) -> String {
        var name = base
        var n = 2
        while routingProfiles.contains(where: { $0.name == name }) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }
}
