// SPDX-License-Identifier: AGPL-3.0-only
// Model routing, host side — the ONE place a delivery's router is built. Today that router
// is the identity router (every call answers with the delivery's provider and its clamped
// settings); the profile router lands here as a policy swap, not a plumbing change. Every
// turn lane consumes the router's verdict (`SZTurnOrder.choice`) verbatim — nothing below
// this file re-derives generation settings for a turn.
import Foundation
import SZAI
import SZCore

extension SZHost {
    /// The router a delivery hands its engine and query service. One choice for every call:
    /// `providerID` with its stored row clamped to real capabilities — byte-identical to the
    /// pre-routing behavior.
    func makeRouter(providerID: String) -> any SZModelRouting {
        let generation = resolvedGenerationSettings(for: providerID)
        return SZIdentityRouter(choice: SZModelChoice(
            providerID: providerID, model: generation.model,
            reasoningEffort: generation.reasoningEffort,
            fastMode: generation.fastMode ?? false))
    }
}
