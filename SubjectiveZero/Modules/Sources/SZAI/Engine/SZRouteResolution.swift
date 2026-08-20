// SPDX-License-Identifier: AGPL-3.0-only
// An envelope resolved onto a concrete provider: merge over the provider's stored baseline,
// then clamp via `resolvedGenerationSettings(from:)`. A routed model the live catalog
// doesn't list is surfaced as `substitutedModel`, never substituted silently.
import SZCore

/// What an envelope resolved to on its provider: concrete settings, plus the asked-for
/// model the clamp had to replace (nil = the envelope's model landed as asked).
public struct SZRoutedGeneration: Sendable, Equatable {
    public var settings: SZProviderGenerationSettings
    public var substitutedModel: String?

    public init(settings: SZProviderGenerationSettings, substitutedModel: String? = nil) {
        self.settings = settings
        self.substitutedModel = substitutedModel
    }
}

extension SZProvider {
    /// Merge `envelope` over `baseline` (nil fields inherit — an effort-only envelope keeps
    /// the baseline model) and clamp against this provider's real capability surface.
    public func routedGenerationSettings(envelope: SZRouteEnvelope,
                                         baseline: SZProviderGenerationSettings)
        -> SZRoutedGeneration {
        let merged = SZProviderGenerationSettings(
            model: envelope.model ?? baseline.model,
            reasoningEffort: envelope.reasoningEffort ?? baseline.reasoningEffort,
            fastMode: envelope.fastMode ?? baseline.fastMode)
        let clamped = resolvedGenerationSettings(from: merged)
        // Substitution = the live catalog doesn't list the asked model (an empty pre-fetch
        // dynamic catalog included); the caller narrates it.
        let asked = envelope.model
        let substituted = asked != nil && clamped.model != asked ? asked : nil
        return SZRoutedGeneration(settings: clamped, substitutedModel: substituted)
    }
}
