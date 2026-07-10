// SPDX-License-Identifier: AGPL-3.0-only
// Per-provider generation choices (model / reasoning effort / fast mode) — the preference half of
// provider selection, following the SZHost+Chat.swift sibling pattern. Mutators validate against
// the ACTIVE provider's real capability surface, write that provider's row, persist immediately
// (the snapToGrid story — a preference, not the setup sheet's Confirm gate), and re-fire the
// provider-default telemetry (its joined signature dedupes no-op repeats). Rows are stored raw and
// clamped at read (`resolvedGenerationSettings(for:)`), so a stale app-state.json entry degrades
// to the provider's defaults instead of breaking.
import Foundation
import SZAI
import SZCore
import SZUI

extension SZHost {
    /// The composer picker's items: every provider with its full generation surface + resolved
    /// selection, only healthy ones selectable — an absent option is a mystery, a dimmed one is a
    /// diagnosis. (The old HUD `providerPickerItems` mapping's successor; SZUI can't import SZAI,
    /// so capabilities arrive pre-mapped.)
    var providerGenerationPickerItems: [SZProviderGenerationPickerItem] {
        SZProviderRegistry.shared.providers.map { provider in
            let status = displayedProviderHealth(provider.id)?.status
            let resolved = provider.resolvedGenerationSettings(from: providerGenerationSettings[provider.id])
            let selectedModel = resolved.model ?? provider.defaultModel
            return SZProviderGenerationPickerItem(
                id: provider.id,
                label: provider.displayName,
                isEnabled: status == nil || status == .ready,   // unknown stays permissive, like the pre-flights
                isActive: provider.id == activeProviderID,
                models: provider.models.map {
                    SZProviderGenerationPickerModelItem(id: $0.id, label: $0.displayName)
                },
                supportedReasoningEfforts: provider.supportedReasoningEfforts(for: selectedModel),
                supportsFastMode: provider.supportsFastMode(for: selectedModel),
                selectedModel: selectedModel,
                selectedReasoningEffort: resolved.reasoningEffort,
                fastModeEnabled: resolved.fastMode ?? false)
        }
    }

    /// The stored row for `providerID`, clamped to the provider's real capabilities — always
    /// concrete values, ready for an `SZAgentRunRequest`. Identity-empty for an unknown id.
    func resolvedGenerationSettings(for providerID: String) -> SZProviderGenerationSettings {
        guard let provider = SZProviderRegistry.shared.provider(id: providerID) else {
            return SZProviderGenerationSettings()
        }
        return provider.resolvedGenerationSettings(from: providerGenerationSettings[providerID])
    }

    /// Pick the active provider's model (the composer picker / `ui_set_provider`). Returns false
    /// for a model the provider doesn't list (left unchanged). A real change also resets that
    /// provider's agent sessions — a thread belongs to the model that opened it (see
    /// `resetAgentSessions`). Effort and fast mode deliberately do NOT reset: they're per-turn argv
    /// the CLI re-sends on every resume, so they retune the SAME thread.
    @discardableResult
    func setActiveModel(_ model: String) -> Bool {
        guard let provider = SZProviderRegistry.shared.provider(id: activeProviderID),
              provider.models.contains(where: { $0.id == model }) else { return false }
        // Compare against the RESOLVED model, so re-picking the current one is a no-op reset — but
        // still persist it, pinning a choice that today only matches the default by coincidence.
        let changed = model != resolvedGenerationSettings(for: activeProviderID).model
        providerGenerationSettings[activeProviderID, default: SZProviderGenerationSettings()].model = model
        persistAppState()
        if changed { resetAgentSessions(ownedBy: activeProviderID) }
        trackProviderDefaultTelemetry()
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
