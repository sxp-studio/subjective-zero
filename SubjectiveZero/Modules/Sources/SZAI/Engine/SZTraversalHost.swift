// SPDX-License-Identifier: AGPL-3.0-only
// The engine's seams — small typed protocols, no closure bag, no silent no-op defaults: a
// host that cannot fulfil a requirement does not compile, and tests drive the engine with
// stubs of exactly these. (The previous architecture's 28-parameter capability struct with
// twelve defaulted closures is the cautionary tale.)
import Foundation
import SZCore

/// One full agent turn as the engine orders it: the brief is ALREADY RENDERED — the host
/// transports it to a provider session and reports process truth back. Content routing
/// never rides a turn; that is what steps are for.
public struct SZTurnOrder: Sendable {
    public var agent: String
    public var brief: String
    public var session: SZAgentGraph.Turn.Session
    /// Tool narrowing for this turn; nil = the agent's default surface.
    public var tools: [String]?
    /// Provider + generation settings, resolved by the router. The engine constructs every
    /// order, so nothing else can name a model.
    public var choice: SZModelChoice

    public init(agent: String, brief: String, session: SZAgentGraph.Turn.Session,
                tools: [String]?, choice: SZModelChoice) {
        self.agent = agent
        self.brief = brief
        self.session = session
        self.tools = tools
        self.choice = choice
    }
}

/// What came back from a turn: process truth only (`ok`/`error` is derived from `failed`),
/// plus the detail a failed turn carries into the trace.
public struct SZTurnReport: Sendable {
    public var failed: Bool
    public var detail: String?
    public init(failed: Bool, detail: String? = nil) {
        self.failed = failed
        self.detail = detail
    }
}

/// One work item the engine hands the host to send as an `.item` message.
public struct SZItemOrder: Sendable, Equatable {
    public var node: String
    public init(node: String) { self.node = node }
}

/// How one step evaluation settled, mirrored across the SZAI/SZRuntime module boundary
/// (SZAI may not import SZRuntime; the host's adapter translates).
public struct SZStepReport: Sendable {
    public var outcome: String?
    public var cancelled: Bool
    public var failure: String?
    public init(outcome: String? = nil, cancelled: Bool = false, failure: String? = nil) {
        self.outcome = outcome
        self.cancelled = cancelled
        self.failure = failure
    }
}

/// The step-execution seam the runtime fulfils (via an SZApp adapter over SZStepRuntime).
public protocol SZStepRunning: Sendable {
    /// Evaluate the compiled step `agent`/`step` against `factsJSON`, serving its model
    /// asks through `ask` (the QueryService's executor). Never throws — every failure mode
    /// is a field of the report.
    func evaluate(agent: String, step: String, factsJSON: String,
                  ask: @escaping @Sendable (String) async throws -> String) async -> SZStepReport
}

/// One step of a traversal as the panel/RUNS record sees it advance. Reported repeatedly
/// per node — running, then settled — consumers replace by (ordinal, node).
public struct SZTraversalNote: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case running, done, failed }
    public var ordinal: Int
    public var node: String
    public var phase: Phase
    public var outcome: String?
    public var detail: String?
    public init(ordinal: Int, node: String, phase: Phase, outcome: String? = nil, detail: String? = nil) {
        self.ordinal = ordinal
        self.node = node
        self.phase = phase
        self.outcome = outcome
        self.detail = detail
    }
}

/// What every traversal needs from its host. `@MainActor`: the host is the app's observable
/// object; test stubs annotate the same way. (`Sendable` is free for a MainActor class —
/// it is what lets a step's ask closure carry the host reference across executors.)
@MainActor
public protocol SZTraversalHost: AnyObject, Sendable {
    /// The kind-gated facts document for this traversal, rebuilt fresh at every read — the
    /// engine hands it to steps (pinned per evaluation) and the brief renderer.
    func factsJSON(kind: SZMessageKind) -> String
    /// The values of a `[String]`-typed fact (a dispatch's `items:`), resolved from the
    /// same snapshot `factsJSON` renders.
    func itemsFact(named name: String, kind: SZMessageKind) -> [String]
    /// Render a turn's brief template against the current facts + delivery payload. The
    /// GATE lives behind this seam: rendered bytes must match the pinned fixtures.
    func renderBrief(agent: String, template: String, kind: SZMessageKind) throws -> String
    /// Run one full agent turn (session, tools, streaming — all host business).
    func runTurn(_ order: SZTurnOrder) async -> SZTurnReport
    /// Serve one step's `askModel` request (render its template, route, complete, journal).
    /// Throwing `CancellationError` answers the ask as cancelled; other errors as failed.
    func serveAsk(agent: String, step: String, requestJSON: String) async throws -> String
    /// Trace push for the panel/RUNS record.
    func note(_ note: SZTraversalNote)
}
