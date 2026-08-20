// SPDX-License-Identifier: AGPL-3.0-only
// Model routing, host side — the ONE place a delivery's router is built and the active
// profile's envelopes become concrete choices. Resolution happens once per run and once per
// prose delivery (a live run never moves under a profile edit); anything a profile asks for
// that the live world can't honour falls one rung down with a sentence the user reads —
// never a silent substitution. No active profile ⇒ the identity router, byte-identical to
// the pre-routing app. SZ_MODEL_ROUTING pins a profile at launch (=0 kills routing; an
// unknown name REFUSES the delivery rather than guessing — the SZ_AGENT_PACKS rule).
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

    /// The profile new deliveries resolve against, honouring the launch pin. A persisted
    /// active name no saved profile carries degrades to off (the stale-preference rule);
    /// an ENV name that resolves nowhere throws — explicit intent is never guessed away.
    /// `env` is injectable for tests only; production always reads the launch pin.
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

    /// The router a delivery hands its engine and query service, plus the fallback
    /// sentences resolution produced (the caller narrates them — run lane under the "Run
    /// started" line, chat lane as a note on the delivering scope). With no active profile:
    /// the identity router — one choice for every call, `providerID` with its stored row
    /// clamped to real capabilities — and no sentences.
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
        /// One envelope to one concrete choice — or nil (dropped, narrated): the position
        /// falls one rung down by simply not appearing in the table.
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

    /// Chat deliveries resolve per message, so a broken route would otherwise say the same
    /// sentence on every send: a note repeats only after the set changes (profile edits and
    /// activation clear the memory — the world moved, say it again).
    private func dedupedRoutingNotes(_ notes: [String]) -> [String] {
        let fresh = notes.filter { !narratedRoutingNotes.contains($0) }
        narratedRoutingNotes.formUnion(notes)
        return fresh
    }

    // MARK: - Work grades (the Director's per-task read)

    /// Record the Director's grade for a node's implementation task. Write-wins while the
    /// node is still undispatched — a reconcile re-brief may regrade — and FROZEN from the
    /// moment a coding turn ran for it (`dispatchPrompts` carries that fact): a retry must
    /// resolve exactly as the cold start did, and a mid-run flip would move it. Unknown
    /// grade words are refused at the MCP boundary, so this stores only the three.
    func recordNodeGrade(_ node: SZNodeID, _ grade: String) {
        guard dispatchPrompts[node] == nil else { return }
        nodeGrades[node] = grade
    }

    // MARK: - Profile mutation (AI Settings / the debug bus)

    /// Switch the active profile (nil = Off). Refused while a run is traversing — a live
    /// experiment keeps its arm. No session resets: switches govern NEW conversations; a
    /// live thread keeps the envelope that opened it (session affinity), by design.
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

    /// Delete by name; deleting the active profile turns routing off (narrated via status).
    @discardableResult
    func deleteRoutingProfile(named name: String) -> Bool {
        guard routingProfiles.contains(where: { $0.name == name }) else { return false }
        routingProfiles.removeAll { $0.name == name }
        if activeRoutingProfileName == name {
            activeRoutingProfileName = nil
            status = "routing off: its profile \"\(name)\" was deleted"
        }
        narratedRoutingNotes.removeAll()
        persistAppState()
        return true
    }
}
