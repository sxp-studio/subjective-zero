// SPDX-License-Identifier: AGPL-3.0-only
// The host↔orchestrator seam. `SZOrchestrationContext` is everything the host hands a run —
// graph store, provider choice, MCP wiring, and the host capabilities the orchestrator
// sequences — and `SZOrchestrating` is the one-method contract the graph orchestrator
// (`SZGraphDirectorStrategy`) fulfills. The former procedural/agentic strategy selection is
// retired: the agent-graph engine is THE orchestrator, and this seam stays concrete in SZAI
// (no SZCore protocol). See docs/AGENT_ORCHESTRATION.md.
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

/// Everything the orchestrator needs for one run, bundled so the `SZOrchestrating` method stays
/// small. Built on the MainActor by the host at `startRun`; the orchestrator reads the graph
/// on-main, then spawns agents off-main.
@MainActor
public struct SZOrchestrationContext {
    public let providerID: String
    /// The user's resolved generation choices for `providerID` (model / effort / fast mode) — the
    /// host resolves once at `startRun`; every coding-agent request this run carries them. The
    /// empty default means "provider defaults" (tests with no host attached keep today's behavior).
    public let generationSettings: SZProviderGenerationSettings
    public let store: SZStore
    public let mcpPort: UInt16
    /// The bare MCP tool names this run's coding agents may call — the app's
    /// `SZHostBridge.agentCallableToolNames` (the single source of truth), forwarded onto each
    /// coding-agent request so a per-tool-allowlist provider (claude) mirrors the bus. Empty default:
    /// a strategy run with no host attached (tests) needs no allowlist.
    public let allowedMCPTools: [String]
    public let projectURL: URL
    public let cacheDirectory: URL
    public let runner: any SZProcessRunning
    /// Stream each coding agent's turn into its node's Coding Agent tab; nil = run directly (tests).
    public let turnRunner: SZCodingTurnRunner?
    /// A free-text instruction for the Director (a chat message that triggered the run); "" for a plain
    /// `ui_run` ("implement the current graph"). The orchestrator folds it into the decompose brief.
    public let instruction: String
    /// True when the run was requested by the Director Agent's OWN chat turn (`ui_run` mid-turn,
    /// started at turn end): that turn had the full `ui_*` toolbelt and the same contract-shaping
    /// framing, so it WAS the decompose turn — the orchestrator skips its own and goes straight
    /// to dispatch (the reconcile rounds still catch an under-shaped graph).
    public let directorAlreadyBriefed: Bool

    // Host capabilities the orchestrator SEQUENCES (the host owns each; the orchestrator decides
    // when to call it). Default no-ops/nil so unit tests can run with no host attached.

    /// Grant every entitlement declared by the live graph's node contracts (host
    /// `requestDeclaredPermissions(for:)`), prompting once per still-undetermined one. Called at
    /// dispatch: a node's permission is only known once the Director declares its contract — AFTER
    /// the initial project load — so this grants a newly-introduced entitlement (e.g. `microphone`) before
    /// the node's `setup()` runs on the promote-reload. Default no-op (tests / no host attached).
    public let grantPermissions: @MainActor @Sendable () async -> Void
    /// Run ONE Director Agent turn with the given prompt, streamed into the `.director` tab, returning its
    /// result (host `runDirectorTurn`). nil = no Director available (tests / headless), so a
    /// director-bound turn honestly fails instead of running silent.
    public let directorTurn: (@MainActor @Sendable (String) async throws -> SZAgentRunResult)?
    /// The coding agents' last-reported observable status line per node (host `nodeStatusLines`, fed
    /// by `agent_report_status`). Read AFTER a dispatch to assess which nodes are unresolved
    /// (`error`/`needsInput`) and drive the reconcile rounds.
    /// Default empty so a run with no host attached (tests) simply sees nothing to reconcile.
    public let nodeStatus: @MainActor @Sendable () -> [SZNodeID: String]
    /// Drain (take + clear) the messages the Director Agent authored for coding agents during this run
    /// (its `ui_send_chat`-to-a-node calls, recorded by the host). Drained after each reconcile turn
    /// and folded into the matching node's retry prompt. Default empty.
    public let takeDirectorMessages: @MainActor @Sendable () -> [SZNodeID: String]
    /// Drain (take + clear) the messages CODING agents sent the Director during this run (their
    /// `ui_send_chat scope=director` calls). Drained BEFORE each reconcile turn and rendered into
    /// its brief — the reverse feedback lane of `takeDirectorMessages`. Default empty.
    public let takeDirectorInbox: @MainActor @Sendable () -> [String]
    /// The run's captured WORK SET (host `runWorkSet`), read LIVE so nodes the Director/split/merge add
    /// mid-run join it. Dispatch scopes to it. `nil` = no host (tests) → all prompt nodes;
    /// non-nil (even `[]`) = authoritative → only these ids are the fleet's work.
    public let workSet: @MainActor @Sendable () -> Set<SZNodeID>?
    /// The pieces STAGED by an in-flight split/merge (host `hiddenPieces`), read LIVE like `workSet` — the
    /// Director can stage an op mid-run. Their coding agents get the preserve-behavior framing instead of
    /// the library tiers: their reference is the original's source, quoted in their seed prompt.
    public let stagedPieces: @MainActor @Sendable () -> Set<SZNodeID>
    /// The assembled node-library index (the `agent_library_index` payload) to inline into each
    /// COLD-START coding brief, so a first dispatch reads it in-prompt instead of spending its first
    /// tool round fetching it (each round replays the agent's whole context). Also flips the brief's
    /// contract-schema section to its inlined variant — this nil-check is the single switch for
    /// both payloads. nil (the default; tests, or the host's env override) keeps the
    /// call-the-tool framing.
    public let libraryIndexText: String?
    /// Serve one step-query completion (the assembled request + the routed provider → the
    /// raw reply text). nil — the default, and production's — lets the query service run
    /// the provider directly through `runner`; tests script this seam to answer asks
    /// without a CLI.
    public let queryExecutor: SZQueryExecutor?
    /// Perform one step-requested EFFECT (`"requestBuild"`, …). The host owns each lane;
    /// the engine decides when — after the step returns, before edge routing, names
    /// already validated against the kind's effect set. Default no-op (tests observe
    /// through their stub hosts instead).
    public let performEffect: @MainActor @Sendable (String, SZMessageKind) async -> Void

    public init(
        providerID: String,
        generationSettings: SZProviderGenerationSettings = SZProviderGenerationSettings(),
        store: SZStore,
        mcpPort: UInt16,
        allowedMCPTools: [String] = [],
        projectURL: URL,
        cacheDirectory: URL,
        runner: any SZProcessRunning = SZSystemProcessRunner(),
        turnRunner: SZCodingTurnRunner? = nil,
        instruction: String = "",
        directorAlreadyBriefed: Bool = false,
        grantPermissions: @escaping @MainActor @Sendable () async -> Void = {},
        directorTurn: (@MainActor @Sendable (String) async throws -> SZAgentRunResult)? = nil,
        nodeStatus: @escaping @MainActor @Sendable () -> [SZNodeID: String] = { [:] },
        takeDirectorMessages: @escaping @MainActor @Sendable () -> [SZNodeID: String] = { [:] },
        takeDirectorInbox: @escaping @MainActor @Sendable () -> [String] = { [] },
        workSet: @escaping @MainActor @Sendable () -> Set<SZNodeID>? = { nil },
        stagedPieces: @escaping @MainActor @Sendable () -> Set<SZNodeID> = { [] },
        libraryIndexText: String? = nil,
        queryExecutor: SZQueryExecutor? = nil,
        performEffect: @escaping @MainActor @Sendable (String, SZMessageKind) async -> Void = { _, _ in }
    ) {
        self.providerID = providerID
        self.generationSettings = generationSettings
        self.store = store
        self.mcpPort = mcpPort
        self.allowedMCPTools = allowedMCPTools
        self.projectURL = projectURL
        self.cacheDirectory = cacheDirectory
        self.runner = runner
        self.turnRunner = turnRunner
        self.instruction = instruction
        self.directorAlreadyBriefed = directorAlreadyBriefed
        self.grantPermissions = grantPermissions
        self.directorTurn = directorTurn
        self.nodeStatus = nodeStatus
        self.takeDirectorMessages = takeDirectorMessages
        self.takeDirectorInbox = takeDirectorInbox
        self.workSet = workSet
        self.stagedPieces = stagedPieces
        self.libraryIndexText = libraryIndexText
        self.queryExecutor = queryExecutor
        self.performEffect = performEffect
    }
}

/// One orchestrator. Invoked by the host's `startRun`. Returns `node id → session id` for every
/// agent that reported one, so the host can later resume a node's coding agent for a chat turn
/// (SZHost holds the map; sessions aren't persisted).
public protocol SZOrchestrating: Sendable {
    @discardableResult
    @MainActor
    func run(_ context: SZOrchestrationContext) async throws -> [SZNodeID: String]
}

/// Per-coding-turn budgets, in seconds. The working bound is SILENCE, not wall clock: a turn dies
/// after `codingInactivityTimeout` with no output (every streamed chunk resets the clock), so a large
/// node whose agent is still visibly working is never cut off mid-stream — the blind 300s wall that
/// used to kill streaming agents was the worst observed run friction. `codingTimeout` remains as the
/// wall-clock hard cap for a CLI that wedges (or loops) while still emitting. Overridable via
/// `SZ_AGENT_TIMEOUT` / `SZ_AGENT_INACTIVITY_TIMEOUT` (TODO: expose as Settings sliders);
/// decomposing the work is the structural fix — these are the power-user escape hatches.
public enum SZAgentTurnBudgets {
    public static var codingTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["SZ_AGENT_TIMEOUT"].flatMap(TimeInterval.init) ?? 900
    }

    public static var codingInactivityTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["SZ_AGENT_INACTIVITY_TIMEOUT"].flatMap(TimeInterval.init) ?? 120
    }
}
