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
    /// 15-minute active-only heartbeat, and records the launch-time provider default.
    func startTelemetry() {
        SZTelemetry.shared.start { [weak self] in self?.telemetryContext() }
        SZTelemetry.shared.trackDefaultProvider(context: telemetryContext())
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
