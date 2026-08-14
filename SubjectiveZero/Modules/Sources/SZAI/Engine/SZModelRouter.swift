// SPDX-License-Identifier: AGPL-3.0-only
// The routing seam every model request passes through: a caller describes WHAT it is asking
// for (`SZModelCall` — the call's class and where in the agent graph it originates) and the
// router answers WITH WHAT (`SZModelChoice` — provider, model, effort). Step and engine code
// never name a model; naming lives entirely behind this protocol, which is what keeps the
// seam vendor-neutral. v1 ships the identity router (one choice for every call — the
// session's provider); per-step user picks and an automatic strategy are future conformers,
// wired in at host construction like any other policy.

/// One model request, described by intent and origin — everything a routing policy may key
/// on. `class` separates the small stateless completion (`query` — a step's ask) from a full
/// agent turn (`turn`); the origin fields name the graph position the call came from.
public struct SZModelCall: Sendable {
    /// The two shapes a model request takes: a stateless completion serving one decision
    /// (`query`), or a full agent turn with tools and a session (`turn`).
    public enum Class: Sendable {
        case query
        case turn
    }

    public var `class`: Class
    /// The agent (type) on whose behalf the call runs.
    public var agent: String
    /// The graph node whose evaluation (or turn) is asking.
    public var step: String?

    public init(class: Class, agent: String, step: String? = nil) {
        self.class = `class`
        self.agent = agent
        self.step = step
    }
}

/// A routing verdict: which provider serves the call, and optionally which model and effort.
/// `model`/`reasoningEffort` are the same opaque pass-through tokens the provider seam
/// already speaks (`SZAgentRunRequest`) — nil defers to the provider's own default.
public struct SZModelChoice: Sendable {
    public var providerID: String
    public var model: String?
    public var reasoningEffort: String?

    public init(providerID: String, model: String? = nil, reasoningEffort: String? = nil) {
        self.providerID = providerID
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

/// The seam itself. Conformers are POLICY, chosen at host construction; callers hold this
/// protocol and never a concrete router.
public protocol SZModelRouting: Sendable {
    func resolve(_ call: SZModelCall) -> SZModelChoice
}

/// v1: every call resolves to the one choice the router was built with — the session's
/// provider, exactly the pre-routing behavior, now passing through the seam.
public struct SZIdentityRouter: SZModelRouting {
    public var choice: SZModelChoice

    public init(choice: SZModelChoice) {
        self.choice = choice
    }

    public func resolve(_ call: SZModelCall) -> SZModelChoice {
        choice
    }
}
