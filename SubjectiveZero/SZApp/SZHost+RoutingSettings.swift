// SPDX-License-Identifier: AGPL-3.0-only
// The Routing pane's host mapping — profiles distilled to the plain cards SZUI may see (it
// can't import SZAI), and the pane's intents translated back into profile edits through
// `upsertRoutingProfile` (one write path, one persistence story). One card per plan agent,
// one row per declared slot, keyed by the typed SZRoutingPosition. Envelope options mirror
// the provider-card rules: only healthy providers selectable, dimmed rows say why in the label.
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

    /// The pane's cards for the edited profile: one per plan agent (director first), rows in
    /// each graph's slot DECLARATION order.
    func routingAgentCards(profileNamed requested: String?) -> [SZRoutingAgentCard] {
        guard let profile = routingEditedProfile(named: requested) else { return [] }
        return agentGraphPlanAgents().map { agent in
            SZRoutingAgentCard(id: agent.id, title: agent.title, symbol: agent.symbol,
                               tint: agent.graph.tint,
                               rows: agent.graph.slots.map {
                                   routingRow(agent: agent.id, slot: $0, graph: agent.graph,
                                              profile: profile)
                               })
        }
    }

    /// One slot's row: labels, options, and — only when an envelope is set — the effort/fast
    /// surface of the ROUTED model, so the pane never renders a control the model can't
    /// honour. The clear/unset labels are DERIVED, never hand-written: a grade-variant slot
    /// inherits its standard slot's route, everything else the app default.
    private func routingRow(agent agentID: String, slot: SZAgentGraph.Slot,
                            graph: SZAgentGraph, profile: SZRoutingProfile)
        -> SZRoutingPositionRow {
        let position = SZRoutingPosition(agent: agentID, slot: slot.id)
        let envelope = profile.envelope(agent: agentID, slot: slot.id)
        let options = routingEnvelopeOptions(selected: envelope)
        // Every unfilled row reads "Default" — one word, everywhere. The menu's clear row
        // carries the LIVE resolution, which is where the rows honestly differ: a grade
        // variant resolves through its standard slot's route (when filled), everything
        // else through the app default.
        let standardID = SZRoutingInheritance.standardSlot(for: slot.id, grades: graph.grades)
        let resolution = standardID
            .flatMap { profile.envelope(agent: agentID, slot: $0) }
            .map(routingEnvelopeDisplay) ?? routingAppDefaultDisplay
        let unsetLabel = "Default"
        let clearLabel = "Default — \(resolution)"
        guard let envelope else {
            return SZRoutingPositionRow(position: position, label: slot.label ?? slot.id,
                                        caption: slot.description,
                                        selectionLabel: unsetLabel, clearLabel: clearLabel,
                                        isSet: false, options: options)
        }
        let provider = SZProviderRegistry.shared.provider(id: envelope.providerID)
        // The model the route actually runs: the envelope's pin, else the provider's own
        // resolved selection. Raw-id fallbacks keep a stale route visible, never blank.
        let routedModel = envelope.model
            ?? provider.map { resolvedGenerationSettings(for: $0.id).model ?? $0.defaultModel }
            ?? ""
        return SZRoutingPositionRow(
            position: position, label: slot.label ?? slot.id, caption: slot.description,
            selectionLabel: routingEnvelopeDisplay(envelope), clearLabel: clearLabel,
            isSet: true, options: options,
            effortOptions: provider?.supportedReasoningEfforts(for: routedModel) ?? [],
            selectedEffort: envelope.reasoningEffort,
            supportsFastMode: provider?.supportsFastMode(for: routedModel) ?? false,
            fastModeEnabled: envelope.fastMode ?? false)
    }

    /// An envelope as "Provider · Model" display names; raw ids keep a stale route visible.
    private func routingEnvelopeDisplay(_ envelope: SZRouteEnvelope) -> String {
        let provider = SZProviderRegistry.shared.provider(id: envelope.providerID)
        let routedModel = envelope.model
            ?? provider.map { resolvedGenerationSettings(for: $0.id).model ?? $0.defaultModel }
            ?? ""
        let modelLabel = provider?.models.first { $0.id == routedModel }?.displayName ?? routedModel
        return [provider?.displayName ?? envelope.providerID, modelLabel]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The live resolution of the app default — what an unrouted slot actually runs on.
    private var routingAppDefaultDisplay: String {
        routingEnvelopeDisplay(SZRouteEnvelope(providerID: activeProviderID))
    }

    /// Every provider·model pair, in registry order — the same health/disable rules as the
    /// provider cards: a dimmed row says why in its label (menu rows carry no tooltip).
    private func routingEnvelopeOptions(selected: SZRouteEnvelope?) -> [SZRoutingEnvelopeOption] {
        SZProviderRegistry.shared.providers.flatMap { provider -> [SZRoutingEnvelopeOption] in
            let enabled = routingProviderUsable(provider.id)
            let reason: String = if disabledProviderIDs.contains(provider.id) { " (disabled)" }
                else if enabled { "" }
                else { Self.routingHealthSuffix(displayedProviderHealth(provider.id)?.status) }
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

    /// The chat feed's speaker identities, as the packs declare them — symbol + tint per
    /// agent graph, resolved through the seats. Packs declaring none fall to the panel's
    /// built-in palette (nil fields).
    var chatAgentAccents: SZChatPanel.SZChatAgentAccents {
        let agents = agentGraphPlanAgents()
        let director = agents.first { $0.seat == SZAgentSeat.director.rawValue }
        let debug = agents.first { $0.id == SZChatScope.debugKey }
        let coding = agents.first { $0.seat == SZAgentSeat.coding.rawValue }
        return SZChatPanel.SZChatAgentAccents(
            directorColor: SZAgentTint.color(director?.graph.tint),
            directorSymbol: director?.graph.symbol,
            codingColor: SZAgentTint.color(coding?.graph.tint),
            debugColor: SZAgentTint.color(debug?.graph.tint),
            debugSymbol: debug?.graph.symbol)
    }

    /// The pane's health rule, shared by the option menus and the preset gate: enabled and
    /// not known-unhealthy (unknown stays permissive, like the pre-flights).
    private func routingProviderUsable(_ id: String) -> Bool {
        let status = displayedProviderHealth(id)?.status
        return !disabledProviderIDs.contains(id) && (status == nil || status == .ready)
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

    /// Assign a position's envelope; providerID nil clears it back to its inherit. Re-picking
    /// a provider·model starts a fresh envelope — an effort tuned for the old model is not
    /// carried onto one it may not fit.
    func assignRoutingEnvelope(profileNamed requested: String?, position: SZRoutingPosition,
                               providerID: String?, modelID: String?) {
        guard var profile = routingEditedProfile(named: requested) else { return }
        let envelope = providerID.map { SZRouteEnvelope(providerID: $0, model: modelID) }
        profile.setEnvelope(envelope, agent: position.agent, slot: position.slot)
        upsertRoutingProfile(profile)
    }

    /// Retune a SET position's reasoning effort (nil = the provider's own selection decides).
    func setRoutingPositionEffort(profileNamed requested: String?, position: SZRoutingPosition, effort: String?) {
        guard var profile = routingEditedProfile(named: requested),
              var envelope = profile.envelope(agent: position.agent, slot: position.slot) else { return }
        envelope.reasoningEffort = effort
        profile.setEnvelope(envelope, agent: position.agent, slot: position.slot)
        upsertRoutingProfile(profile)
    }

    /// Toggle a SET position's fast mode — the pane only offers this where the routed model
    /// honours it.
    func setRoutingPositionFastMode(profileNamed requested: String?, position: SZRoutingPosition, enabled: Bool) {
        guard var profile = routingEditedProfile(named: requested),
              var envelope = profile.envelope(agent: position.agent, slot: position.slot) else { return }
        envelope.fastMode = enabled
        profile.setEnvelope(envelope, agent: position.agent, slot: position.slot)
        upsertRoutingProfile(profile)
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

    /// Whether the New Profile menu offers the Claude Ladder preset — the claude provider
    /// under the same usability rule its envelope options apply.
    var routingClaudeLadderAvailable: Bool {
        SZProviderRegistry.shared.provider(id: "claude") != nil && routingProviderUsable("claude")
    }

    /// The Claude Ladder starter: Haiku sorts, Sonnet builds and answers, Opus takes the
    /// planning and the heavy work. Fills only the built-in agents; builder-light stays
    /// unfilled on purpose (its Default follows the Builder row). Saved, not activated — the caller
    /// selects it for edit.
    @discardableResult
    func createClaudeLadderRoutingProfile() -> String {
        let opus = SZRouteEnvelope(providerID: "claude", model: "claude-opus-5")
        let sonnet = SZRouteEnvelope(providerID: "claude", model: "claude-sonnet-5")
        let haiku = SZRouteEnvelope(providerID: "claude", model: "claude-haiku-4-5")
        let name = routingUniqueName("Claude Ladder")
        upsertRoutingProfile(SZRoutingProfile(name: name, agents: [
            "director": ["planner": opus, "assistant": sonnet, "sorter": haiku],
            "coding": ["builder-default": sonnet, "builder-heavy": opus,
                       "assistant": sonnet, "sorter": haiku],
            "debug": ["assistant": sonnet],
        ]))
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

    // MARK: - The View Graph deep link's dismissal

    /// Close the sheet as a NAVIGATION, not a Skip: no funnel event, same polling stop as
    /// every other dismissal. The sheet binding's set-false path (skipProviderSetup) is
    /// deliberately bypassed.
    func dismissProviderSetupForNavigation() {
        providerSetupPresented = false
        stopProviderHealthPolling()
    }
}
