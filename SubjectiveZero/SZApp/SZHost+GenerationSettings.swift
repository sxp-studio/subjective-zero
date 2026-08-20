// SPDX-License-Identifier: AGPL-3.0-only
// The DEFAULT provider's generation choices (model / reasoning effort / fast mode) — the
// preference half of provider selection, following the SZHost+Chat.swift sibling pattern; the
// setup sheet's per-card picker and `ui_set_provider` are the ways in. Mutators validate against
// the ACTIVE provider's real capability surface, write that provider's row, persist immediately
// (the snapToGrid story — a preference, not the setup sheet's Confirm gate), and re-fire the
// provider-default telemetry (its joined signature dedupes no-op repeats). Rows are stored raw and
// clamped at read (`resolvedGenerationSettings(for:)`), so a stale app-state.json entry degrades
// to the provider's defaults instead of breaking.
import Foundation
import SZAI
import SZCore

extension SZHost {
    /// The stored row for `providerID`, clamped to the provider's real capabilities — always
    /// concrete values, ready for an `SZAgentRunRequest`. Identity-empty for an unknown id.
    func resolvedGenerationSettings(for providerID: String) -> SZProviderGenerationSettings {
        guard let provider = SZProviderRegistry.shared.provider(id: providerID) else {
            return SZProviderGenerationSettings()
        }
        return provider.resolvedGenerationSettings(from: providerGenerationSettings[providerID])
    }

    /// Pick the ACTIVE provider's model (the composer picker / `ui_set_provider`). Thin wrapper over
    /// `setModel(_:for:)` — the setup sheet's per-card picker sets ANY provider's model, including one
    /// that isn't active (and can't be made active while it's failing).
    @discardableResult
    func setActiveModel(_ model: String) -> Bool {
        setModel(model, for: activeProviderID)
    }

    /// Pick a model for `providerID` (need not be the active provider). Returns false for a model the
    /// provider doesn't list (left unchanged). A real change resets that provider's agent sessions —
    /// a thread belongs to the model that opened it (see `resetAgentSessions`) — and drops any held
    /// probe verdict, since a `Verified` badge earned by the previous model doesn't carry to this one
    /// (the same rule a cheap-status transition applies in `refreshProviderHealthOnce`). Effort and
    /// fast mode deliberately do NOT reset: they're per-turn argv the CLI re-sends on every resume, so
    /// they retune the SAME thread.
    @discardableResult
    func setModel(_ model: String, for providerID: String) -> Bool {
        guard let provider = SZProviderRegistry.shared.provider(id: providerID),
              provider.models.contains(where: { $0.id == model }) else { return false }
        // Compare against the RESOLVED model, so re-picking the current one is a no-op reset — but
        // still persist it, pinning a choice that today only matches the default by coincidence.
        let changed = model != resolvedGenerationSettings(for: providerID).model
        providerGenerationSettings[providerID, default: SZProviderGenerationSettings()].model = model
        persistAppState()
        if changed {
            resetAgentSessions(ownedBy: providerID)
            providerProbes[providerID] = nil   // the old model's verdict no longer describes this one
        }
        // Telemetry reads the ACTIVE provider's context, so only fire when this IS that provider.
        if providerID == activeProviderID { trackProviderDefaultTelemetry() }
        return true
    }

    /// Pick the active provider's reasoning effort. Returns false for a token outside the
    /// provider's supported list — which is also every token when the CLI has no effort concept.
    @discardableResult
    func setActiveReasoningEffort(_ effort: String) -> Bool {
        guard let provider = SZProviderRegistry.shared.provider(id: activeProviderID) else { return false }
        let selected = provider.resolvedGenerationSettings(from: providerGenerationSettings[activeProviderID])
        let model = selected.model ?? provider.defaultModel
        guard provider.supportedReasoningEfforts(for: model).contains(effort) else { return false }
        providerGenerationSettings[activeProviderID, default: SZProviderGenerationSettings()].reasoningEffort = effort
        persistAppState()
        trackProviderDefaultTelemetry()
        return true
    }

    /// Toggle the active provider's fast mode. Returns false when the selected model doesn't honour
    /// it — a CLI can carry the flag for every model it serves and act on only some, so the answer
    /// depends on the model, exactly as it does for effort above.
    @discardableResult
    func setActiveFastMode(_ enabled: Bool) -> Bool {
        guard let provider = SZProviderRegistry.shared.provider(id: activeProviderID) else { return false }
        let selected = provider.resolvedGenerationSettings(from: providerGenerationSettings[activeProviderID])
        let model = selected.model ?? provider.defaultModel
        guard provider.supportsFastMode(for: model) else { return false }
        providerGenerationSettings[activeProviderID, default: SZProviderGenerationSettings()].fastMode = enabled
        persistAppState()
        trackProviderDefaultTelemetry()
        return true
    }

    /// Drop the agent sessions (live + disk-restored probation) a switch invalidates, landing the map
    /// on disk immediately so a relaunch can't resurrect a dead id.
    ///
    /// `ownedBy: nil` — a **provider** switch: every session goes, since a codex thread can't be
    /// resumed by claude. `ownedBy: id` — a **model** switch within one CLI: only that CLI's threads
    /// go, leaving another provider's scopes alone. A thread is bound to the model that opened it
    /// two ways: codex re-sends `-m` on every `resume`, so a kept thread would answer as the new
    /// model over the old one's reasoning; and a first turn that died still emitted a real
    /// `thread.started` id, so resuming it replays that failure into the new model's tab.
    ///
    /// Transcripts are untouched: the next message per scope cold-starts with the transcript recap
    /// (`sendChat`), which is the context-rebuild story.
    func resetAgentSessions(ownedBy providerID: String? = nil) {
        func owned(_ session: SZAgentSession) -> Bool { providerID == nil || session.providerID == providerID }
        guard agentSessions.contains(where: { owned($0.value) })
                || restoredSessions.contains(where: { owned($0.value) }) else { return }
        agentSessions = agentSessions.filter { !owned($0.value) }
        restoredSessions = restoredSessions.filter { !owned($0.value) }
        persistAgentSessions()
        status = "agent sessions reset — context rebuilds from transcripts"
    }
}
