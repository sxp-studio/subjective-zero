// SPDX-License-Identifier: AGPL-3.0-only
// Anonymous usage telemetry wiring — roadmap Task 3, following the SZHost+Chat.swift sibling
// pattern. SZTelemetry (SZApp/Telemetry/) owns the events and the active-only heartbeat; this
// file owns WHEN they fire: the app-path start (never the --verify-agent-providers path, which
// exits before SZApp.main()) and the provider-default hook. Context is read live per call —
// projects and providers switch at runtime, so nothing is captured at launch.
import Foundation
import SZAI
import SZCore

extension SZHost {
    /// Start telemetry as an app-level service (`start()` tail): fires `app_launch`, starts the
    /// 15-minute active-only heartbeat, notes a still-unconfigured relaunch, and records the
    /// launch-time provider default. The enabled check is a live closure against host state —
    /// never cached — so toggling the welcome-screen pref takes effect on the very next send,
    /// heartbeat included.
    func startTelemetry() {
        SZTelemetry.shared.start(
            contextProvider: { [weak self] in self?.telemetryContext() },
            isEnabled: { [weak self] in self?.telemetryEnabled ?? false })
        SZTelemetry.shared.trackSetupStuckRelaunchIfNeeded(setupPending: defaultProviderID == nil)
        SZTelemetry.shared.trackDefaultProvider(context: telemetryContext())
    }

    /// The welcome screen's "Share anonymous usage data" checkbox — same persistence story as
    /// setShowWelcomeAtStartup. Opt-out is prospective: events from before the uncheck stand.
    func setTelemetryEnabled(_ on: Bool) {
        guard telemetryEnabled != on else { return }
        telemetryEnabled = on
        persistAppState()
    }

    // MARK: - Setup funnel (call sites in SZHost+ProviderHealth)

    func trackSetupShownTelemetry(auto: Bool) {
        SZTelemetry.shared.trackSetupShown(providers: providerReadinessSnapshot(), auto: auto)
    }

    func trackSetupSkippedTelemetry() {
        SZTelemetry.shared.trackSetupSkipped(providers: providerReadinessSnapshot())
    }

    func trackSetupCompletedTelemetry(providerID: String) {
        SZTelemetry.shared.trackSetupCompleted(providerID: providerID,
                                               providers: providerReadinessSnapshot())
    }

    /// Flat per-provider readiness ("claude:ready,codex:missingCLI"), registry order — the
    /// funnel events' "why they stalled" payload. Built from the same merged truth the sheet's
    /// cards display; Jellystat report values are scalars only, hence the encoded string.
    private func providerReadinessSnapshot() -> String {
        SZProviderRegistry.shared.providers.map { provider in
            let label: String
            if let report = displayedProviderHealth(provider.id) {
                label = report.status == .ready && report.probeVerified
                    ? "verified" : report.status.rawValue
            } else {
                label = "checking"
            }
            return "\(provider.id):\(label)"
        }.joined(separator: ",")
    }

    /// One `agent_provider_default` per distinct selection signature — hooked into
    /// `setActiveProvider(_:)` and the SZHost+GenerationSettings mutators, which the composer
    /// cluster, the setup sheet's Confirm, and `ui_set_provider` all route through; SZTelemetry's
    /// signature dedupe absorbs the repeats.
    func trackProviderDefaultTelemetry() {
        SZTelemetry.shared.trackDefaultProvider(context: telemetryContext())
    }

    private func telemetryContext() -> SZTelemetry.Context {
        let generation = resolvedGenerationSettings(for: activeProviderID)
        return SZTelemetry.Context(
            providerID: activeProviderID,
            providerDisplayName: SZProviderRegistry.shared.provider(id: activeProviderID)?.displayName ?? activeProviderID,
            modelID: generation.model ?? "",
            reasoningEffort: generation.reasoningEffort ?? "",
            fastMode: generation.fastMode ?? false,
            nodeCount: store.project?.graph.nodes.count ?? 0
        )
    }
}
