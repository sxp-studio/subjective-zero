// SPDX-License-Identifier: AGPL-3.0-only
// The Routing pane's host mapping: profiles distilled to plain cards for SZUI (which can't
// import SZAI), and pane intents translated back into profile edits through
// `upsertRoutingProfile`, the one write path. One card per plan agent, one row per declared
// slot, keyed by SZRoutingPosition. Envelope options follow the provider-card health rules.
import Foundation
import SZAI
import SZCore
import SZUI

extension SZHost {
    // MARK: - What the pane reads

    var routingProfileRows: [SZRoutingProfileRow] {
        routingProfiles.map {
            SZRoutingProfileRow(name: $0.name, isActive: $0.name == activeRoutingProfileName,
                                isProtected: Self.routingStarterNames.contains($0.name))
        }
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

    /// The pane's cards: one per plan agent (director first), rows in slot declaration
    /// order. `editedName` nil = Off: rows show their live resolution only, no options.
    func routingAgentCards(editedName: String?) -> [SZRoutingAgentCard] {
        let profile = editedName.flatMap { name in routingProfiles.first { $0.name == name } }
        return agentGraphPlanAgents().map { agent in
            // Recommendations count only declared slots; conflicts = slots already filled.
            let declared = Set(agent.graph.slots.map(\.id))
            let recommended = agent.recommendedRouting.keys.filter(declared.contains)
            let conflicts = profile.map { p in
                recommended.filter { p.envelope(agent: agent.id, slot: $0) != nil }.count
            } ?? 0
            return SZRoutingAgentCard(id: agent.id, title: agent.title, symbol: agent.symbol,
                                      tint: agent.graph.tint,
                                      rows: agent.graph.slots.map {
                                          routingRow(agent: agent.id, slot: $0, graph: agent.graph,
                                                     profile: profile)
                                      },
                                      recommendedCount: profile == nil ? 0 : recommended.count,
                                      recommendedConflicts: conflicts)
        }
    }

    /// Apply a pack's recommended routes to the edited profile. Undeclared slots never
    /// apply; `replacingExisting` false fills only unset slots.
    func applyRecommendedRouting(agent agentID: String, profileNamed requested: String?,
                                 replacingExisting: Bool) {
        guard let profile = routingEditedProfile(named: requested),
              !Self.routingStarterNames.contains(profile.name),
              let agent = agentGraphPlanAgents().first(where: { $0.id == agentID }) else { return }
        let declared = Set(agent.graph.slots.map(\.id))
        let fragment = agent.recommendedRouting.filter { declared.contains($0.key) }
        guard !fragment.isEmpty else { return }
        upsertRoutingProfile(profile.merging(fragment, agent: agentID,
                                             replacingExisting: replacingExisting))
    }

    /// One slot's row: labels, options, and — only when an envelope is set — the routed
    /// model's effort/fast surface, so the pane never offers a control the model lacks.
    private func routingRow(agent agentID: String, slot: SZAgentGraph.Slot,
                            graph: SZAgentGraph, profile: SZRoutingProfile?)
        -> SZRoutingPositionRow {
        let position = SZRoutingPosition(agent: agentID, slot: slot.id)
        let envelope = profile?.envelope(agent: agentID, slot: slot.id)
        // Unfilled rows read "Default"; the clear row states the live resolution the slot
        // inherits (a grade variant follows its standard slot, else the app default).
        let standardID = SZRoutingInheritance.standardSlot(for: slot.id, grades: graph.grades)
        let resolution = standardID
            .flatMap { id in profile?.envelope(agent: agentID, slot: id) }
            .map(routingEnvelopeDisplay) ?? routingAppDefaultDisplay
        let clearLabel = "Default (\(resolution))"
        // Off (no profile): the row just states its resolution; nothing pickable.
        guard let profile else {
            return SZRoutingPositionRow(position: position, label: slot.label ?? slot.id,
                                        caption: slot.description,
                                        selectionLabel: clearLabel, clearLabel: clearLabel,
                                        isSet: false)
        }
        let options = routingEnvelopeOptions(selected: envelope)
        guard let envelope else {
            return SZRoutingPositionRow(position: position, label: slot.label ?? slot.id,
                                        caption: slot.description,
                                        selectionLabel: "Default", clearLabel: clearLabel,
                                        isSet: false, options: options)
        }
        let provider = SZProviderRegistry.shared.provider(id: envelope.providerID)
        // The model the route runs: the envelope's pin, else the provider's own selection.
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

    /// Live resolution of the app default — what an unrouted slot actually runs on.
    var routingAppDefaultDisplay: String {
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
            // A catalog-less provider still offers one row that pins no model.
            guard !provider.models.isEmpty else { return [option(nil, nil)] }
            return provider.models.map { option($0.id, $0.displayName) }
        }
    }

    /// The chat feed's speaker identities — symbol + tint per agent graph, resolved through
    /// the seats. Packs declaring none fall back to the panel's built-in palette (nil fields).
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

    /// Assign a position's envelope; providerID nil clears it. Re-picking starts a fresh
    /// envelope — an effort tuned for the old model is not carried onto the new one.
    func assignRoutingEnvelope(profileNamed requested: String?, position: SZRoutingPosition,
                               providerID: String?, modelID: String?) {
        guard var profile = routingEditedProfile(named: requested),
              !Self.routingStarterNames.contains(profile.name) else { return }
        let envelope = providerID.map { SZRouteEnvelope(providerID: $0, model: modelID) }
        profile.setEnvelope(envelope, agent: position.agent, slot: position.slot)
        upsertRoutingProfile(profile)
    }

    /// Retune a SET position's reasoning effort (nil = the provider's own selection decides).
    func setRoutingPositionEffort(profileNamed requested: String?, position: SZRoutingPosition, effort: String?) {
        guard var profile = routingEditedProfile(named: requested),
              !Self.routingStarterNames.contains(profile.name),
              var envelope = profile.envelope(agent: position.agent, slot: position.slot) else { return }
        envelope.reasoningEffort = effort
        profile.setEnvelope(envelope, agent: position.agent, slot: position.slot)
        upsertRoutingProfile(profile)
    }

    /// Toggle a SET position's fast mode — the pane only offers this where the routed model
    /// honours it.
    func setRoutingPositionFastMode(profileNamed requested: String?, position: SZRoutingPosition, enabled: Bool) {
        guard var profile = routingEditedProfile(named: requested),
              !Self.routingStarterNames.contains(profile.name),
              var envelope = profile.envelope(agent: position.agent, slot: position.slot) else { return }
        envelope.fastMode = enabled
        profile.setEnvelope(envelope, agent: position.agent, slot: position.slot)
        upsertRoutingProfile(profile)
    }

    // MARK: - Profile lifecycle (the bar's New / Rename / Duplicate)

    /// Create an empty profile under a fresh name and select it (an empty table changes
    /// nothing until slots are filled). Mid-run the switch is refused; the profile stays.
    @discardableResult
    func createRoutingProfile() -> String {
        let name = routingUniqueName("New Profile")
        upsertRoutingProfile(SZRoutingProfile(name: name))
        _ = setActiveRoutingProfile(name)
        return name
    }

    /// The pane's toggle. ON restores the remembered profile (else the first, else a fresh
    /// one); OFF remembers it. Both flips go through `setActiveRoutingProfile`'s mid-run refusal.
    func setRoutingEnabled(_ enabled: Bool) {
        if enabled {
            let remembered = routingLastProfileName
                .flatMap { name in routingProfiles.first { $0.name == name }?.name }
            if let candidate = remembered ?? routingProfiles.first?.name {
                _ = setActiveRoutingProfile(candidate)
            } else {
                _ = createRoutingProfile()   // creates and selects
            }
        } else {
            routingLastProfileName = activeRoutingProfileName
            _ = setActiveRoutingProfile(nil)
        }
    }

    /// SZ_MODEL_ROUTING=0: routing is off for this launch regardless of app-state; the
    /// pane's toggle renders locked off.
    var routingEnvKilled: Bool { Self.modelRoutingEnv == "0" }

    /// The shipped starters — data, not Swift (SZAI's RoutingStarters.json), so model and
    /// slot facts stay out of host code. Their rows are read-only; duplicates are the user's.
    nonisolated static let routingStarters = SZRoutingStarters.load()
    nonisolated static let routingStarterNames = routingStarters.map(\.profile.name)

    /// Seed each shipped starter once its provider is ready. Seeding never activates a profile.
    func seedRoutingStarterIfNeeded() {
        for starter in Self.routingStarters { seedRoutingStarter(starter) }
    }

    private func seedRoutingStarter(_ starter: SZRoutingStarter) {
        guard !routingSeededStarterNames.contains(starter.profile.name),
              SZProviderRegistry.shared.provider(id: starter.requiresProvider) != nil,
              routingProviderUsable(starter.requiresProvider) else { return }
        routingSeededStarterNames.append(starter.profile.name)
        if routingProfiles.contains(where: { $0.name == starter.profile.name }) {
            persistAppState()
        } else {
            upsertRoutingProfile(starter.profile)
        }
    }

    /// Copy a profile's whole table under a fresh name; nil when the source vanished.
    /// The shipped starter's copy drops the provenance suffix — the copy is the user's.
    @discardableResult
    func duplicateRoutingProfile(named source: String) -> String? {
        guard var copy = routingProfiles.first(where: { $0.name == source }) else { return nil }
        let suffix = " (sxp.studio)"
        let base = Self.routingStarterNames.contains(source) && source.hasSuffix(suffix)
            ? String(source.dropLast(suffix.count)) : "\(source) Copy"
        copy.name = routingUniqueName(base)
        upsertRoutingProfile(copy)
        return copy.name
    }

    /// Rename in place — the active pointer follows, so renaming the active profile never
    /// turns routing off. Refused for empty or taken names and for shipped starters.
    @discardableResult
    func renameRoutingProfile(from old: String, to newRaw: String) -> Bool {
        let new = newRaw.trimmingCharacters(in: .whitespaces)
        guard !Self.routingStarterNames.contains(old) else { return false }
        guard !new.isEmpty, new != old,
              let index = routingProfiles.firstIndex(where: { $0.name == old }),
              !routingProfiles.contains(where: { $0.name == new }) else { return false }
        routingProfiles[index].name = new
        if activeRoutingProfileName == old { activeRoutingProfileName = new }
        if routingLastProfileName == old { routingLastProfileName = new }
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

    /// Close the sheet as a navigation, not a Skip: no funnel event, same polling stop.
    /// Deliberately bypasses the binding's set-false path (skipProviderSetup).
    func dismissProviderSetupForNavigation() {
        providerSetupPresented = false
        stopProviderHealthPolling()
    }
}
