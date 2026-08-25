// SPDX-License-Identifier: AGPL-3.0-only
// Model routing, host side: the one place a delivery's router is built and the active
// profile's envelopes become concrete choices. Resolution happens once per run and once per
// prose delivery, so a live run never moves under a profile edit. A route the live world
// can't honour falls one rung down with a narrated note, never silently. No active profile
// = the identity router. SZ_MODEL_ROUTING pins a profile at launch (=0 disables routing;
// an unknown name refuses the delivery).
import Foundation
import SZAI
import SZCore

/// A delivery that cannot route as the launch environment demands — refusal, not fallback.
struct SZRoutingRefusal: Error, CustomStringConvertible {
    let detail: String
    var description: String { detail }
}

extension SZHost {
    /// The launch pin, read once: nil/"1" = app-state governs, "0" = routing off, any other
    /// value names the profile that must exist.
    nonisolated static let modelRoutingEnv: String? = {
        let value = ProcessInfo.processInfo.environment["SZ_MODEL_ROUTING"]
        return value?.isEmpty == true ? nil : value
    }()

    /// Whether a profile governs new work right now (the settings sheet's Off is nil).
    var routingActive: Bool { (try? activeRoutingProfile()) != nil }

    /// The profile new deliveries resolve against, honouring the launch pin: a stale
    /// persisted name degrades to off, an unknown ENV name throws. `env` is for tests only.
    func activeRoutingProfile(env: String? = SZHost.modelRoutingEnv) throws -> SZRoutingProfile? {
        switch env {
        case "0": return nil
        case nil, "1": return routingProfiles.first { $0.name == activeRoutingProfileName }
        case .some(let name):
            guard let pinned = routingProfiles.first(where: { $0.name == name }) else {
                throw SZRoutingRefusal(detail: "SZ_MODEL_ROUTING names '\(name)', which is "
                    + "not a saved profile. Save it in AI Settings or unset the variable.")
            }
            return pinned
        }
    }

    /// The router a delivery hands its engine and query service, plus fallback notes for
    /// the caller to narrate. No active profile: the identity router and no notes.
    func makeRouter(providerID: String) throws -> (router: any SZModelRouting, notes: [String]) {
        let generation = resolvedGenerationSettings(for: providerID)
        let fallback = SZModelChoice(
            providerID: providerID, model: generation.model,
            reasoningEffort: generation.reasoningEffort,
            fastMode: generation.fastMode ?? false)
        guard let profile = try activeRoutingProfile() else {
            return (SZIdentityRouter(choice: fallback), [])
        }

        var notes: [String] = []
        /// One envelope to one choice; nil = dropped and narrated, the position falls back.
        func resolved(_ envelope: SZRouteEnvelope, position: String) -> SZModelChoice? {
            guard let provider = SZProviderRegistry.shared.provider(id: envelope.providerID) else {
                notes.append("\(position) is routed to \(envelope.providerID), which isn't a "
                    + "known provider. Falling back; fix the profile in AI Settings.")
                return nil
            }
            guard !disabledProviderIDs.contains(provider.id),
                  isProviderReadyForNewWork(provider.id) else {
                notes.append("\(provider.displayName) isn't ready, so \(position) falls back. "
                    + "Fix it in Agent Providers.")
                return nil
            }
            let routed = provider.routedGenerationSettings(
                envelope: envelope,
                baseline: resolvedGenerationSettings(for: provider.id))
            if let asked = routed.substitutedModel {
                notes.append("\(position) asked for \(asked), which \(provider.displayName) "
                    + "doesn't list. Running \(routed.settings.model ?? "its default") instead. "
                    + "Re-pick it in AI Settings.")
            }
            return SZModelChoice(providerID: provider.id, model: routed.settings.model,
                                 reasoningEffort: routed.settings.reasoningEffort,
                                 fastMode: routed.settings.fastMode ?? false,
                                 via: "\(profile.name) · \(position)")
        }

        var agents: [String: [String: SZModelChoice]] = [:]
        for (agentID, slots) in profile.agents {
            for (slotID, envelope) in slots {
                if let choice = resolved(envelope, position: "\(agentID) · \(slotID)") {
                    agents[agentID, default: [:]][slotID] = choice
                }
            }
        }
        return (SZProfileRouter(fallback: fallback, agents: agents),
                dedupedRoutingNotes(notes))
    }

    /// Chat resolves per message, so a note repeats only after the note set changes
    /// (profile edits and activation clear the memory).
    private func dedupedRoutingNotes(_ notes: [String]) -> [String] {
        let fresh = notes.filter { !narratedRoutingNotes.contains($0) }
        narratedRoutingNotes.formUnion(notes)
        return fresh
    }

    // MARK: - Work grades (the Director's per-task read)

    /// Record the Director's grade for a node. Last write wins while undispatched; frozen
    /// once a coding turn ran for it, so a retry resolves exactly as the cold start did.
    func recordNodeGrade(_ node: SZNodeID, _ grade: String) {
        guard dispatchPrompts[node] == nil else { return }
        nodeGrades[node] = grade
    }

    // MARK: - Profile mutation (AI Settings / the debug bus)

    /// Switch the active profile (nil = Off). Refused while a run is traversing; switches
    /// govern new conversations only — live threads keep their session affinity.
    @discardableResult
    func setActiveRoutingProfile(_ name: String?) -> Bool {
        guard !isRunning else {
            status = "routing profile unchanged: a run is in flight"
            return false
        }
        guard name == nil || routingProfiles.contains(where: { $0.name == name }) else { return false }
        guard name != activeRoutingProfileName else { return true }
        activeRoutingProfileName = name
        narratedRoutingNotes.removeAll()
        persistAppState()
        status = name.map { "routing on: profile \"\($0)\"; live conversations keep their models" }
            ?? "routing off: everything runs on the default provider"
        return true
    }

    /// Create-or-replace by name. Editing the ACTIVE profile is allowed (new deliveries
    /// resolve the edit; live runs keep their captured table).
    func upsertRoutingProfile(_ profile: SZRoutingProfile) {
        if let index = routingProfiles.firstIndex(where: { $0.name == profile.name }) {
            routingProfiles[index] = profile
        } else {
            routingProfiles.append(profile)
        }
        narratedRoutingNotes.removeAll()
        persistAppState()
    }

    /// Delete by name. Deleting the active profile is a switch: refused mid-run, otherwise
    /// the seat passes to the first remaining profile, or routing turns off.
    @discardableResult
    func deleteRoutingProfile(named name: String) -> Bool {
        guard routingProfiles.contains(where: { $0.name == name }) else { return false }
        guard !Self.routingStarterNames.contains(name) else {
            status = "\"\(name)\" ships with the app and can't be deleted"
            return false
        }
        if activeRoutingProfileName == name, isRunning {
            status = "profile not deleted: a run is in flight"
            return false
        }
        routingProfiles.removeAll { $0.name == name }
        if activeRoutingProfileName == name {
            activeRoutingProfileName = routingProfiles.first?.name
            status = activeRoutingProfileName.map { "routing now follows \"\($0)\"" }
                ?? "routing off: its profile \"\(name)\" was deleted"
        }
        if routingLastProfileName == name { routingLastProfileName = nil }
        narratedRoutingNotes.removeAll()
        persistAppState()
        return true
    }
}
