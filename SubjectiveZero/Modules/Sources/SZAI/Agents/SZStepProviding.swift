// SPDX-License-Identifier: AGPL-3.0-only
// The seam step-attached validation goes through. A code step has NO sidecar spec — its
// outcomes come from the compiled step's exported declaration, and compiling/loading a step
// is the runtime's business, which SZAI may not import (siblings don't depend on each other).
// So the pack loader asks THROUGH this protocol: the host wires the runtime behind it, tests
// wire stubs, and a nil provider makes the loader report step-attached checks as skipped —
// never as silently passed.
import Foundation

/// What one compiled step declared about itself, as validation needs it.
public struct SZStepDeclarationInfo: Codable, Sendable {
    /// The closed outcome set the step answers with — every outcome-labeled edge leaving the
    /// step's node must name one of these.
    public var outcomes: [String]

    public init(outcomes: [String]) {
        self.outcomes = outcomes
    }
}

public protocol SZStepProviding: Sendable {
    /// The declaration of `agent`'s step folder `step`. Returns nil when the compiled step
    /// declares nothing (legal only for a step no outcome-labeled edge leaves). Throws when
    /// the step could not be compiled or loaded — the loader reports that as a defect with
    /// the thrown description as detail.
    func declaration(agent: String, step: String) async throws -> SZStepDeclarationInfo?
}
