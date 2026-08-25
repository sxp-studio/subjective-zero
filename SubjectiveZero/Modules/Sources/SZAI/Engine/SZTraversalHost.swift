// SPDX-License-Identifier: AGPL-3.0-only
// The engine's seams — small typed protocols, no closure bag. One serving object (the
// delivery) fulfils every lane; tests drive the engine with stubs of exactly these.
import Foundation
import SZCore

/// One full agent turn as the engine orders it: the brief is ALREADY COMPOSED (rendered,
/// with the conversation above it when the node declares `context`) — the host transports
/// it to a provider session and reports process truth back. Content routing never rides a
/// turn; that is what steps are for.
public struct SZTurnOrder: Sendable {
    public var agent: String
    public var brief: String
    public var session: SZAgentGraph.Turn.Session
    /// Tool narrowing for this turn; nil = the agent's default surface.
    public var tools: [String]?
    /// Provider + generation settings, resolved by the router. The engine constructs every
    /// order, so nothing else can name a model.
    public var choice: SZModelChoice
    /// The session a `.resume` turn continues; set by `resolved(against:)`, nil = cold start.
    public var resumeSessionID: String?

    public init(agent: String, brief: String, session: SZAgentGraph.Turn.Session,
                tools: [String]?, choice: SZModelChoice) {
        self.agent = agent
        self.brief = brief
        self.session = session
        self.tools = tools
        self.choice = choice
    }
}

extension SZAgentRunRequest {
    /// A resolved order as one request. `tools: []` attaches no MCP; nil takes `defaultTools`.
    /// `packageDirectory` is optional so callers can hand it the host's LIVE project url without
    /// unwrapping: nil falls back to the working directory, which is the right answer for a turn
    /// spawned with no project loaded.
    public init(_ order: SZTurnOrder, prompt: String? = nil, workingDirectory: URL,
                packageDirectory: URL? = nil, cacheDirectory: URL, mcpPort: UInt16, defaultTools: [String]) {
        self.init(
            prompt: prompt ?? order.brief,
            workingDirectory: workingDirectory,
            packageDirectory: packageDirectory,
            cacheDirectory: cacheDirectory,
            mcpServerPort: order.tools?.isEmpty == true ? nil : mcpPort,
            allowedMCPTools: order.tools ?? defaultTools,
            resumeSessionID: order.resumeSessionID,
            model: order.choice.model,
            reasoningEffort: order.choice.reasoningEffort,
            fastMode: order.choice.fastMode,
            timeout: SZAgentTurnBudgets.codingTimeout,
            inactivityTimeout: SZAgentTurnBudgets.codingInactivityTimeout)
    }
}

/// What came back from a turn: process truth only (`ok`/`error` is derived from `failed`),
/// plus the detail a failed turn carries into the trace and the envelope it actually ran
/// (session affinity resolves host-side, so only the host can say it truthfully).
public struct SZTurnReport: Sendable {
    public var failed: Bool
    public var detail: String?
    /// "codex · gpt-5.6-terra · fast" — the run trace's receipt text. nil = unreported.
    public var generation: String?
    public init(failed: Bool, detail: String? = nil, generation: String? = nil) {
        self.failed = failed
        self.detail = detail
        self.generation = generation
    }
}

/// One unit of dispatched work the engine hands the delivery to send.
public struct SZWorkOrder: Sendable, Equatable {
    public var node: String
    public init(node: String) { self.node = node }
}

/// How one step evaluation settled, mirrored across the SZAI/SZRuntime module boundary
/// (SZAI may not import SZRuntime; the host's adapter translates). `effects` are the raw
/// requested effect names off the wire; the engine validates them against `SZEffect`.
public struct SZStepReport: Sendable {
    public var outcome: String?
    public var effects: [String]
    public var cancelled: Bool
    public var failure: String?
    public init(outcome: String? = nil, effects: [String] = [], cancelled: Bool = false,
                failure: String? = nil) {
        self.outcome = outcome
        self.effects = effects
        self.cancelled = cancelled
        self.failure = failure
    }
}

/// The step-execution seam the runtime fulfils (via an SZApp adapter over SZStepRuntime).
public protocol SZStepRunning: Sendable {
    /// Evaluate the compiled step `agent`/`step` against `factsJSON`, serving its model
    /// asks through `ask`. Never throws — every failure mode is a field of the report.
    func evaluate(agent: String, step: String, factsJSON: String,
                  ask: @escaping @Sendable (String) async throws -> String) async -> SZStepReport
}

/// One traversal's identity, announced to observers the moment it starts. The id keys
/// every later observation (notes, the conclusion) back to this traversal's record.
public struct SZTraversalSighting: Sendable, Equatable {
    public var id: UUID
    public var agent: String
    /// The dispatched node id for a work child; nil otherwise.
    public var work: String?
    /// The Director's grade for a work child's task ("light"/"standard"/"heavy"), frozen at
    /// dispatch; nil = ungraded (or not a work child).
    public var grade: String?
    public init(id: UUID, agent: String, work: String? = nil, grade: String? = nil) {
        self.id = id
        self.agent = agent
        self.work = work
        self.grade = grade
    }
}

/// One step of a traversal as the panel/RUNS record sees it advance. Reported repeatedly
/// per node — running, then settled — consumers replace by (ordinal, node). A dispatch
/// visit's re-emits carry the fleet's live tally, so the card counts up while it waits.
public struct SZTraversalNote: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case running, done, failed }
    public var ordinal: Int
    public var node: String
    public var phase: Phase
    public var outcome: String?
    public var detail: String?
    public var tally: SZAgentGraphRun.Tally?
    /// A settled turn visit's envelope receipt ("codex · gpt-5.6-terra · fast"); nil on
    /// every other visit and on turns that predate receipts.
    public var generation: String?
    public init(ordinal: Int, node: String, phase: Phase, outcome: String? = nil,
                detail: String? = nil, tally: SZAgentGraphRun.Tally? = nil,
                generation: String? = nil) {
        self.ordinal = ordinal
        self.node = node
        self.phase = phase
        self.outcome = outcome
        self.detail = detail
        self.tally = tally
        self.generation = generation
    }
}

/// What one traversal needs from its delivery. `@MainActor`: the delivery is app state;
/// test stubs annotate the same way.
@MainActor
public protocol SZTraversalServing: AnyObject, Sendable {
    /// The delivery's facts, rebuilt fresh from the live world at every read — the engine
    /// pins one per node visit (a step and its asks see one snapshot).
    func facts() -> SZFacts
    /// Render a turn or ask brief (a template stem) against the current world.
    func render(template: String) throws -> String
    /// The scope's prior conversation, formatted for a cold turn; nil = nothing to catch up
    /// on. Read fresh like `render`. Only a turn declaring `context: conversation` receives it.
    func conversation() -> String?
    /// Run one full agent turn (session, tools, streaming — all host business).
    func runTurn(_ order: SZTurnOrder) async -> SZTurnReport
    /// Deliver one dispatch set and WAIT for it: send `orders` to the seat, report the
    /// live tally as items land, and return the set's one summary. nil ⇔ cancelled (or no
    /// fleet behind this delivery — the engine records that as a defect).
    func deliver(orders: [SZWorkOrder], to seat: String,
                 progress: @escaping @MainActor @Sendable (SZAgentGraphRun.Tally) -> Void)
        async -> SZSettledSummary?
    /// Serve one step ask (render its template against the SAME snapshot the evaluation is
    /// pinned to — the delivery guarantees it — then route, complete, journal). `slot` is
    /// the asking node's declared ask slot (nil = the app default serves). Throwing
    /// `CancellationError` answers the ask as cancelled; other errors as failed.
    func serveAsk(step: String, slot: String?, requestJSON: String) async throws -> String
    /// Perform one validated effect, after the step returned and before its edge routes.
    func perform(effect: SZEffect) async
    /// Trace push for the panel/RUNS record.
    func note(_ note: SZTraversalNote)
}
