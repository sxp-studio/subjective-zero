// SPDX-License-Identifier: AGPL-3.0-only
// The orchestration seam. A run's dispatch strategy is pluggable: the host holds an
// `any SZOrchestrating` and selects one (procedural / director) via a debug setting. Two real,
// editable implementations behind one toggle is what finally EARNS this seam — but it stays concrete
// in SZAI (no SZCore protocol; TODO: a declarative behavior-tree engine is what would earn THAT,
// if it ever lands). See docs/AGENT_ORCHESTRATION.md and seams-earned-not-scheduled.
//
// "Director" is the orchestration ROLE both strategies fill (today's host narration is already called
// "the Director" though it's not an agent); "Director Agent" stays reserved for the LLM the agentic
// variant spawns. The two strategies are siblings in this folder:
//  - SZProceduralDirectorStrategy — directs WITHOUT an LLM: deterministic / offline / token-free; the
//    baseline + CI path. Contract-first via a texture-pipeline ASSUMPTION (see SZGraph+ContractDraft).
//  - SZAgenticDirectorStrategy — directs via an autonomous LLM Director Agent that reads the live graph,
//    establishes + pins REAL typed contracts, dispatches, adds nodes only when intent is under-specified.
//
// NOTE (transitional): the procedural strategy is expected to be RETIRED once the agentic Director is
// solid (it exists mainly as the token-free CI/offline baseline + a fallback). When it goes, this seam
// drops to a single implementation and arguably un-earns its protocol — revisit then whether
// `SZOrchestrating` should collapse back into a concrete type (seams earned, not scheduled).
import Foundation
import SZCore

public enum SZOrchestratorError: Error, CustomStringConvertible {
    case unknownProvider(String)
    case noProject

    public var description: String {
        switch self {
        case .unknownProvider(let id): "unknown provider: \(id)"
        case .noProject: "no project loaded"
        }
    }
}

/// How the host runs one coding agent's turn — injected so the host can stream that agent's output into
/// the node's Coding Agent transcript. `nil` → the orchestrator runs the provider directly (tests
/// / no streaming). The host's implementation opens the node's tab + an assistant message, then streams
/// the classified output in via `SZHost.streamAgentTurn`.
public typealias SZCodingTurnRunner =
    @MainActor @Sendable (SZNodeID, SZAgentRunRequest, any SZProvider) async throws -> SZAgentRunResult

/// Everything a strategy needs for one run, bundled so the `SZOrchestrating` method stays small and
/// strategies can read what they need (the Director reads more than the procedural path). Built on the
/// MainActor by the host at `startRun`; the strategy reads the graph on-main, then spawns agents off-main.
@MainActor
public struct SZOrchestrationContext {
    public let providerID: String
    /// The user's resolved generation choices for `providerID` (model / effort / fast mode) — the
    /// host resolves once at `startRun`; every coding-agent request this run carries them. The
    /// empty default means "provider defaults" (tests with no host attached keep today's behavior).
    public let generationSettings: SZProviderGenerationSettings
    public let store: SZStore
    public let mcpPort: UInt16
    public let projectURL: URL
    public let cacheDirectory: URL
    public let runner: any SZProcessRunning
    /// Stream each coding agent's turn into its node's Coding Agent tab; nil = run directly (tests).
    public let turnRunner: SZCodingTurnRunner?
    /// A free-text instruction for the Director (a chat message that triggered the run); "" for a plain
    /// `ui_run` ("implement the current graph"). The agentic strategy folds it into the Director prompt.
    public let instruction: String
    /// True when the run was requested by the Director Agent's OWN chat turn (`ui_run` mid-turn,
    /// started at turn end): that turn had the full `ui_*` toolbelt and the same contract-shaping
    /// framing, so it WAS the decompose turn — the agentic strategy skips its own and goes straight
    /// to pin + dispatch (the reconcile loop still catches an under-shaped graph).
    public let directorAlreadyBriefed: Bool

    // Host capabilities the strategies SEQUENCE (the host owns each; the strategy decides when to call it).
    // Default no-ops/nil so unit tests can run a strategy with no host attached.

    /// Draft + pin texture contracts for contract-less drawn nodes from their flow edges (procedural,
    /// contract-first; host `draftFlowContracts`). The agentic strategy skips this — its Director declares
    /// real contracts instead.
    public let draftContracts: @MainActor @Sendable () -> Void
    /// Snapshot every dirty node's declared contract into the host's pin set (host `pinDirtyContracts`),
    /// so `promoteStagedNode` holds each node's typed boundary. Both strategies call this before dispatch.
    public let pinContracts: @MainActor @Sendable () -> Void
    /// Grant every entitlement declared by the live graph's node contracts (host
    /// `requestDeclaredPermissions(for:)`), prompting once per still-undetermined one. Both strategies call
    /// this at dispatch: a node's permission is only known once the Director declares its contract — AFTER
    /// the initial project load — so this grants a newly-introduced entitlement (e.g. `microphone`) before
    /// the node's `setup()` runs on the promote-reload. Default no-op (tests / no host attached).
    public let grantPermissions: @MainActor @Sendable () async -> Void
    /// Run ONE Director Agent turn with the given prompt, streamed into the `.director` tab, returning its
    /// result (host `runDirectorTurn`). nil = no Director available (tests / procedural), so the agentic
    /// strategy falls back to dispatching the graph as-is.
    public let directorTurn: (@MainActor @Sendable (String) async throws -> SZAgentRunResult)?
    /// The coding agents' last-reported observable status line per node (host `nodeStatusLines`, fed
    /// by `agent_report_status`). The agentic strategy reads this AFTER a dispatch to assess which
    /// nodes are unresolved (`error`/`needsInput`) and drive the reconcile loop.
    /// Default empty so a strategy run with no host attached (tests) simply sees nothing to reconcile.
    public let nodeStatus: @MainActor @Sendable () -> [SZNodeID: String]
    /// Drain (take + clear) the messages the Director Agent authored for coding agents during this run
    /// (its `ui_send_chat`-to-a-node calls, recorded by the host). The reconcile loop calls this after each
    /// reconcile turn and folds each message into the matching node's retry prompt. Default empty.
    public let takeDirectorMessages: @MainActor @Sendable () -> [SZNodeID: String]
    /// Drain (take + clear) the messages CODING agents sent the Director during this run (their
    /// `ui_send_chat scope=director` calls). The reconcile loop drains these BEFORE each reconcile
    /// turn and renders them into its prompt — the reverse feedback lane of `takeDirectorMessages`.
    /// Default empty.
    public let takeDirectorInbox: @MainActor @Sendable () -> [String]
    /// The run's captured WORK SET (host `runWorkSet`), read LIVE so nodes the Director/split/merge add
    /// mid-run join it. `plans` scopes dispatch to it. `nil` = no host (tests) → all prompt nodes;
    /// non-nil (even `[]`) = authoritative → only these ids are the fleet's work.
    public let workSet: @MainActor @Sendable () -> Set<SZNodeID>?
    /// The pieces STAGED by an in-flight split/merge (host `hiddenPieces`), read LIVE like `workSet` — the
    /// Director can stage an op mid-run. Their coding agents get the preserve-behavior framing instead of
    /// the library tiers: their reference is the original's source, quoted in their seed prompt.
    public let stagedPieces: @MainActor @Sendable () -> Set<SZNodeID>

    public init(
        providerID: String,
        generationSettings: SZProviderGenerationSettings = SZProviderGenerationSettings(),
        store: SZStore,
        mcpPort: UInt16,
        projectURL: URL,
        cacheDirectory: URL,
        runner: any SZProcessRunning = SZSystemProcessRunner(),
        turnRunner: SZCodingTurnRunner? = nil,
        instruction: String = "",
        directorAlreadyBriefed: Bool = false,
        draftContracts: @escaping @MainActor @Sendable () -> Void = {},
        pinContracts: @escaping @MainActor @Sendable () -> Void = {},
        grantPermissions: @escaping @MainActor @Sendable () async -> Void = {},
        directorTurn: (@MainActor @Sendable (String) async throws -> SZAgentRunResult)? = nil,
        nodeStatus: @escaping @MainActor @Sendable () -> [SZNodeID: String] = { [:] },
        takeDirectorMessages: @escaping @MainActor @Sendable () -> [SZNodeID: String] = { [:] },
        takeDirectorInbox: @escaping @MainActor @Sendable () -> [String] = { [] },
        workSet: @escaping @MainActor @Sendable () -> Set<SZNodeID>? = { nil },
        stagedPieces: @escaping @MainActor @Sendable () -> Set<SZNodeID> = { [] }
    ) {
        self.providerID = providerID
        self.generationSettings = generationSettings
        self.store = store
        self.mcpPort = mcpPort
        self.projectURL = projectURL
        self.cacheDirectory = cacheDirectory
        self.runner = runner
        self.turnRunner = turnRunner
        self.instruction = instruction
        self.directorAlreadyBriefed = directorAlreadyBriefed
        self.draftContracts = draftContracts
        self.pinContracts = pinContracts
        self.grantPermissions = grantPermissions
        self.directorTurn = directorTurn
        self.nodeStatus = nodeStatus
        self.takeDirectorMessages = takeDirectorMessages
        self.takeDirectorInbox = takeDirectorInbox
        self.workSet = workSet
        self.stagedPieces = stagedPieces
    }
}

/// One orchestration strategy. Selected by the host (debug setting), invoked by `startRun`. Returns
/// `node id → session id` for every agent that reported one, so the host can later resume a node's
/// coding agent for a chat turn (SZHost holds the map; sessions aren't persisted).
public protocol SZOrchestrating: Sendable {
    @discardableResult
    @MainActor
    func run(_ context: SZOrchestrationContext) async throws -> [SZNodeID: String]
}

/// The strategies the host can select (the `SZ_ORCHESTRATOR` env value / `debug_set_orchestrator` arg).
/// Both are "Director" strategies; the axis is HOW they direct — `procedural` (deterministic code) vs
/// `agentic` (an LLM Director Agent).
public enum SZOrchestrationStrategy: String, CaseIterable, Sendable {
    case procedural
    case agentic

    /// Build the concrete strategy. Both are cheap value types over the shared provider registry.
    public func make(registry: SZProviderRegistry = .shared) -> any SZOrchestrating {
        switch self {
        case .procedural: SZProceduralDirectorStrategy(registry: registry)
        case .agentic:    SZAgenticDirectorStrategy(registry: registry)
        }
    }
}
