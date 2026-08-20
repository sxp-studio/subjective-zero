// SPDX-License-Identifier: AGPL-3.0-only
// The Routing pane's host mapping — profiles distilled to the plain rows SZUI may see (it
// can't import SZAI), and the pane's intents translated back into profile edits through
// `upsertRoutingProfile` (one write path, one persistence story). Rows are keyed by the
// typed SZRoutingPosition; both sides switch on its cases. Envelope options mirror the
// provider-card rules: only healthy providers selectable, dimmed rows say why in the label.
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

    /// The mapping form's rows for the edited profile: one row per agent, then the
    /// top-level queries row and the three grades.
    func routingPositionRows(profileNamed requested: String?) -> [SZRoutingPositionRow] {
        guard let profile = routingEditedProfile(named: requested) else { return [] }
        var rows: [SZRoutingPositionRow] = []
        for agent in agentGraphPlanAgents() {
            rows.append(routingRow(position: .agent(id: agent.id), label: agent.title,
                                   symbol: agent.symbol, envelope: profile.agents[agent.id]))
        }
        rows.append(routingRow(position: .queries, label: "Quick Questions",
                               caption: "Small behind-the-scenes questions that sort each message — a fast model fits",
                               envelope: profile.queries))
        for grade in SZRoutingProfile.grades {
            rows.append(routingRow(position: .grade(grade),
                                   label: grade.prefix(1).uppercased() + grade.dropFirst(),
                                   envelope: profile.gradeEnvelope(grade)))
        }
        return rows
    }

    /// One position row: selection label, options, and — only when an envelope is set — the
    /// effort/fast surface of the ROUTED model, so the pane never renders a control the
    /// model can't honour.
    private func routingRow(position: SZRoutingPosition, label: String, symbol: String? = nil,
                            caption: String? = nil, envelope: SZRouteEnvelope?)
        -> SZRoutingPositionRow {
        let options = routingEnvelopeOptions(selected: envelope)
        guard let envelope else {
            return SZRoutingPositionRow(position: position, label: label, symbol: symbol, caption: caption,
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
            position: position, label: label, symbol: symbol, caption: caption,
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

    // MARK: - What the pane writes (position → profile edit)

    /// Assign a position's envelope; providerID nil clears it back to Default. Re-picking a
    /// provider·model starts a fresh envelope — an effort tuned for the old model is not
    /// carried onto one it may not fit.
    func assignRoutingEnvelope(profileNamed requested: String?, position: SZRoutingPosition,
                               providerID: String?, modelID: String?) {
        guard var profile = routingEditedProfile(named: requested) else { return }
        let envelope = providerID.map { SZRouteEnvelope(providerID: $0, model: modelID) }
        Self.writeRouteEnvelope(envelope, at: position, in: &profile)
        upsertRoutingProfile(profile)
    }

    /// Retune a SET position's reasoning effort (nil = the provider's own selection decides).
    func setRoutingPositionEffort(profileNamed requested: String?, position: SZRoutingPosition, effort: String?) {
        guard var profile = routingEditedProfile(named: requested),
              var envelope = Self.readRouteEnvelope(at: position, of: profile) else { return }
        envelope.reasoningEffort = effort
        Self.writeRouteEnvelope(envelope, at: position, in: &profile)
        upsertRoutingProfile(profile)
    }

    /// Toggle a SET position's fast mode — the pane only offers this where the routed model
    /// honours it.
    func setRoutingPositionFastMode(profileNamed requested: String?, position: SZRoutingPosition, enabled: Bool) {
        guard var profile = routingEditedProfile(named: requested),
              var envelope = Self.readRouteEnvelope(at: position, of: profile) else { return }
        envelope.fastMode = enabled
        Self.writeRouteEnvelope(envelope, at: position, in: &profile)
        upsertRoutingProfile(profile)
    }

    nonisolated private static func readRouteEnvelope(at position: SZRoutingPosition,
                                                      of profile: SZRoutingProfile)
        -> SZRouteEnvelope? {
        switch position {
        case .queries: profile.queries
        case .grade(let word): profile.gradeEnvelope(word)
        case .agent(let id): profile.agents[id]
        }
    }

    nonisolated private static func writeRouteEnvelope(_ envelope: SZRouteEnvelope?,
                                                       at position: SZRoutingPosition,
                                                       in profile: inout SZRoutingProfile) {
        switch position {
        case .queries: profile.queries = envelope
        case .grade("light"): profile.light = envelope
        case .grade("standard"): profile.standard = envelope
        case .grade("heavy"): profile.heavy = envelope
        case .grade: break   // an unknown grade word maps to nothing, deliberately
        case .agent(let id): profile.agents[id] = envelope
        }
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
