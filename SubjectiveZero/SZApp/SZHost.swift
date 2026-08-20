// SPDX-License-Identifier: AGPL-3.0-only
// The host coordinator — composition root + router + run-lifecycle owner (ARCHITECTURE.md). It owns
// the SZRuntime, the SZStore, and the MCP server; loads the project from disk; watches node sources
// for hot reload; and vends the device + per-frame viewport render closure to the UI. It also owns the procedures
// that span the packages: staging→promote (merging the authored contract into the live typed boundary),
// run + per-node agent
// state (SZNodeAgentState), and — in the sibling SZHost+*.swift extensions — the Director-run
// orchestration surface, chat/session bookkeeping, and the split/merge deferred-commit.
// Model semantics stay in SZCore; GPU/compile in SZRuntime; agent reasoning/prompts in SZAI.
import AppKit
import Foundation
import QuartzCore
import SZAI
import SZCore
import SZRuntime
import SZUI

/// A split/merge whose pieces are STAGED (hidden, wired, seeded) and awaiting the run that implements them.
/// The run's tail commits it — swapping the finished pieces in for the original(s) — or rolls it back if any
/// piece didn't reach `.generated`. Held as data rather than a completion closure so that a split staged
/// DURING a run (the Director restructuring mid-turn) is drained by that run, having started none of its own.
enum SZPendingGraphOp {
    case split(original: SZNodeID, pieces: [SZNodeID], title: String)
    case merge(constituents: [SZNodeID], merged: SZNodeID)
}

@MainActor
@Observable
final class SZHost {
    private(set) var runtime: SZRuntime?
    /// Which viewport drives (the rest mirror); pushed to the runtime by `applyRenderDrive()`
    /// (SZHost+Viewports.swift).
    let viewportDriver = SZViewportDriverRegistry()
    /// Viewport surfaces currently in a window, keyed by layer identity (briefly two per id during
    /// a pop-out/dock transition).
    @ObservationIgnored var viewportSurfaces: [SZViewportSurface] = []
    /// What `applyRenderDrive()` last pushed — its idempotence key.
    @ObservationIgnored var appliedRenderDrive: SZRenderDrive?
    internal(set) var status = "starting…"
    private var started = false
    /// One source watcher per watched node, id-keyed — so `watchNodeSources` can re-run idempotently
    /// (after a promote / graph edit) without duplicating watchers, and a node DELETE can stop its
    /// watcher (`stopWatchingNodeSource`) instead of leaving it polling the orphaned folder.
    private var watchers: [SZNodeID: SZSourceWatcher] = [:]

    /// Shared state (the loaded project graph). The MCP `debug_snapshot_state` / `agent_read_graph`
    /// tools and the staging→promote loop read and mutate through this.
    let store = SZStore()
    /// The host's MCP command bus (started once the project loads). See SZMCPServer.
    private(set) var mcpServer: SZMCPServer?
    /// The bus spawned AGENTS dial — same bridge, `debug_*` withheld. Kept separate because a raw TCP
    /// connection carries no identity, so the port is the only way to tell a fleet agent from a test driver.
    private(set) var agentMCPServer: SZMCPServer?
    /// The one bridge behind every listener — kept so `deliver` can spawn per-turn agent
    /// listeners (exact trace attribution; see SZMCPServer.traceContext).
    private(set) var hostBridge: SZHostBridge?
    /// Most recent node build errors, surfaced by `debug_get_build_errors`.
    private(set) var lastBuildErrors: String?
    /// The loaded project's `.subz` URL — the root for `.staging/` + live `nodes/`.
    private(set) var loadedProjectURL: URL?
    /// The advisory lock held on the loaded project so a second running instance can't edit it too
    /// (SZProjectDirectoryLock). Retaken on every `switchProject` and released on switch-away / quit /
    /// discard; nil while nothing is loaded.
    private var projectLock: SZProjectDirectoryLock?
    /// True while the untitled close/quit rescue prompt is on screen — the window-close and quit
    /// paths both call `confirmSaveOrDiscardIfUnsaved`, so this stops a ⌘Q during a red-button-close
    /// alert (or vice versa) from stacking a second modal over the same decision.
    var isClosePromptInFlight = false
    /// The typed per-node agent state (phase + message + error detail + chatting flag) — fed by
    /// `agent_report_status` (via the MCP boundary's wire→phase parse), the hot-reload path, and chat
    /// turns; consumed by the editor's status pill/lock and the reconcile loop. One map, SZNodeID-keyed.
    /// `internal(set)` like its siblings so the SZHost+Transcripts purge can drop a deleted node's entry.
    internal(set) var nodeAgentState: [SZNodeID: SZNodeAgentState] = [:]
    /// THE LIVE RUNS, keyed by the task each is executing. Runs whose work sets are disjoint are
    /// live together; overlapping ones wait in `pendingTasks` because the ledger refuses the claim.
    internal(set) var activeRuns: [UUID: SZRunState] = [:]
    /// Every node any live run is implementing — dispatch, the editor lock/pill and the
    /// `ui_connect` guard all consult this. Empty when nothing is running.
    var runWorkSet: Set<SZNodeID> { activeRuns.values.reduce(into: []) { $0.formUnion($1.workSet) } }
    // Mid-run Director↔fleet messages live as `.steer` envelopes in `mailbox` (recorded — never a
    // nested turn inside a synchronous MCP handler; the reconcile loop drains them). See
    // `recordDirectorMessage` / `recordDirectorInboxMessage` / `takeDirectorMessages`.
    /// Debug test affordance: node uuids to force-fail (report `needsInput`, no agent run) on their
    /// NEXT coding dispatch — set via `debug_fail_node_once`, consumed once. Lets the reconcile loop be
    /// driven live & repeatably without waiting for a real agent to flakily fail (the agents rarely do).
    var forcedFailNodes: [SZNodeID: String] = [:]   // node id → the blocker message it reports
    /// Resumable agent sessions captured from the last run, addressed by chat scope (`ui_send_chat`):
    /// the key is a node's uuid string (chat a node's Coding Agent), or `"director"` (Director Agent
    /// chat, created lazily). Persisted MACHINE-LOCALLY (agent-sessions.json via
    /// SZAgentSessionIO — session ids are bound to this machine's CLI state, so they don't travel in
    /// the .subz; see SZHost+Transcripts.swift) and restored on project open.
    internal(set) var agentSessions: [String: SZAgentSession] = [:]
    /// The ORIGINAL node(s) of an in-flight split/merge → a transient label ("Splitting"/"Merging"). They
    /// stay on-canvas, fully wired and rendering, with this pill while the Director implements the new
    /// pieces; cleared at commit when the finished pieces swap in (deferred-commit UX).
    internal(set) var graphOpStatus: [SZNodeID: String] = [:]
    /// New pieces being implemented by an in-flight split/merge — the editor HIDES these until the
    /// operation commits, so the user never sees placeholder/draft cards (only the flagged originals,
    /// then the finished result). Cleared (revealed) at commit.
    internal(set) var hiddenPieces: Set<SZNodeID> = []
    /// The staged split/merge's claim on the single `.graphOp` ledger slot — taken at staging,
    /// released when the op settles (commit or rollback). Makes the staged op ledger-visible
    /// (project ops block via `anyHeld`; diagnostics name it). See SZHost+Fence.swift.
    internal(set) var graphOpClaim: SZClaimToken?
    /// The staged split/merge waiting on the run that implements its pieces — drained by that run's tail
    /// (`drainPendingGraphOp`), which commits it or rolls it back. AT MOST ONE: `startRun` serializes runs,
    /// and `rollbackGraphOp` clears the shared `hiddenPieces` bag wholesale, so a second concurrent op
    /// would take the first one's pieces down with it. `splitNode`/`mergeNodes` refuse while one is staged.
    internal(set) var pendingGraphOp: SZPendingGraphOp?
    /// The prompt each node's coding agent was briefed WITH — what `promoteStagedNode` stamps the build with.
    ///
    /// A promote proves the source matches the CONTRACT; it proves nothing about the prompt. So the stamp
    /// records the brief the agent actually built, and if the intent moved after dispatch (the Director's
    /// mid-run `ui_update_node` re-brief, or a user edit) the node derives `.intentChanged` — otherwise it
    /// would read clean and current while implementing what the prompt used to say.
    ///
    /// Written in `streamCodingAgent`, NOT snapshotted at `startRun`: the Director decomposes first and each
    /// brief is composed from the live graph after that, so a `startRun` snapshot would flag a
    /// node whose re-brief the agent actually built. The value is `String?` because a contract-first drawn node
    /// is legitimately briefed with no prompt; a MISSING key means "no coding turn ran for this node", which is
    /// a different thing and preserves the pre-existing clear-on-promote behaviour for off-run paths (a
    /// node-scoped chat turn that compiles, a library instantiate).
    internal(set) var dispatchPrompts: [SZNodeID: String?] = [:]
    /// The Director's per-node work grades ("light"/"standard"/"heavy"), written while
    /// briefing (`ui_update_node`'s `complexity`), read at dispatch to prime each fleet
    /// child's router. Write-wins until the node dispatches, frozen after (a retry must
    /// re-resolve exactly as its cold start did) — see `recordNodeGrade`. Never persisted:
    /// a grade describes one briefing's read of the task, not the node.
    internal(set) var nodeGrades: [SZNodeID: String] = [:]
    /// The nodes `promoteStagedNode` landed for their LATEST dispatch of the current run — the run's success
    /// evidence (`surfaceUnresolvedNodes`). Cleared at run start and in the run task's claim-guarded settle
    /// (a cancelled run's zombie must not clear a newer run's set), and per node at each coding dispatch: a
    /// redispatch means the previous build didn't settle it, so its promote stops vouching. A promote outside
    /// a run is dropped at the next start, so it can never vouch for work it did not do.
    var promotedThisRun: Set<SZNodeID> { activeRuns.values.reduce(into: []) { $0.formUnion($1.promoted) } }
    /// The id of the assistant message currently STREAMING per scope (set/cleared by `deliver`).
    /// Transcript flushes exclude it, so a sidecar only ever contains completed turns — a crash
    /// mid-stream restores up to the last finished message, never a half-reply.
    internal(set) var inFlightAssistantIDs: [String: UUID] = [:]
    /// Chat scopes (node uuid / "director") with a turn in flight — drives the "working" dots for the
    /// WHOLE turn, regardless of whether partial reply text has arrived (codex emits a preamble message
    /// before its tool work, so "text empty" alone would hide the dots too early). Derived from the
    /// in-flight map so the two can't drift.
    var chatInFlight: Set<String> { Set(inFlightAssistantIDs.keys) }
    /// The sessions restored from DISK this launch (agent-sessions.json), on probation until proven:
    /// if a resumed turn fails while the scope STILL holds its disk-restored session (compared by
    /// value — a session re-minted this process never matches, so it can never be dropped by
    /// mistake), `sendChat` drops it and the next message cold-starts with the transcript recap.
    var restoredSessions: [String: SZAgentSession] = [:]
    /// The resource ledger — the single home for "who may touch what right now" (SZResourceLedger).
    /// Every agent turn claims its scope's resources for the stream's duration (`deliver`); a run
    /// claims its work set; the busy flags and lock affordances derive from the claims table.
    let ledger = SZResourceLedger()
    /// The message queue — the single home for "what is waiting to be said to whom"
    /// (SZMessageQueue). Sends that can't run immediately enqueue here instead of being rejected;
    /// the host's pump delivers them as their resources free (SZHost+Mailbox.swift).
    let mailbox = SZMessageQueue()
    /// The graph-edit journal — who changed what, appended at the origin-carrying mutation funnels
    /// (SZHost+MutationJournal.swift); the reconcile brief lists the entries since the Director's
    /// last turn. In-memory, bounded, cleared with the project.
    var mutationJournal = SZMutationJournal(capacity: 200)
    /// In-flight pump deliveries (bounded by `deliveryCap` so a run-end release can't spawn one CLI
    /// process per queued scope at once). Pump-owned; mutated only on the MainActor.
    var activeDeliveries = 0
    // Turn-breakdown glue (SZHost+TurnBreakdown.swift) — collection itself is SZTrace fences.
    /// Runs recorded this session the user hasn't opened in the Profiler yet — its unread dots.
    /// Session-scoped on purpose (an old transcript's runs aren't news).
    var unreadRunIDs: Set<UUID> = []
    /// The agent-graph RUNS records — live first, then newest (`SZAgentGraphRun.ordered`),
    /// which is exactly the order the Agent Graph panel draws. Mirrored — live records too —
    /// to `<project>.subz/runs.json` (SZHost+GraphRuns.swift).
    var agentGraphRuns: [SZAgentGraphRun] = []
    /// The coalesced runs.json write behind per-visit notes (SZHost+GraphRuns).
    @ObservationIgnored var agentGraphRunsPersistDebounce: Task<Void, Never>?
    /// The Plan view's pack library, cached (view bodies read it hot). The packs root is the
    /// user-editable materialized dir now, so the cache is invalidated wherever the tree can
    /// move — pack materialization and each run start — rather than held for the session.
    /// nil = not built yet.
    /// Not observed: the panel fills this DURING body evaluation, and an observed write
    /// there invalidates the view that just read it (a wasted render per invalidation).
    @ObservationIgnored var agentGraphPlanCache: [SZAgentGraphPlanAgent]?
    /// Bumped when the plan cache is ENRICHED off the main path (step declarations landing
    /// asynchronously) — the observable poke that re-renders panels reading the cache.
    private(set) var agentGraphPlanEpoch = 0
    @ObservationIgnored var agentGraphPlanFill: Task<Void, Never>?

    func bumpAgentGraphPlanEpoch() { agentGraphPlanEpoch += 1 }
    /// Hot-reload watchers over the materialized packs' `steps/<name>/Step.swift`, keyed
    /// `agent/step` — armed once at pack materialization (SZHost+AgentPacks.swift).
    var stepWatchers: [String: SZSourceWatcher] = [:]
    /// The session's last `turnPromptCap` rendered prompts, keyed by turn id — the fast path for
    /// what was ACTUALLY sent to the CLI (`debug_turn_prompt`). The durable copy lives in the
    /// on-disk debug capture (`debug-turns/<turnID>/`, newest `debugTurnCaptureCap` turns), which
    /// also holds every tool result's payload — the app-visible input tokens, as actual text.
    nonisolated static let turnPromptCap = 20
    nonisolated static let debugTurnCaptureCap = 40
    var turnPrompts: [UUID: String] = [:]
    var turnPromptOrder: [UUID] = []
    /// Turn ids with an inspectable prompt (ring or disk) — gates the view-prompt/tokens buttons.
    var heldPromptIDs: Set<UUID> = []
    /// A transcript's "open in the Agent Graph" ask: the run to select once the panel shows.
    var agentGraphFocusRequest: UUID?
    /// A transcript's "open in Profiler" ask: the record to select once the panel shows.
    var profilerFocusRequest: UUID?
    /// True for the duration of `switchProject` — the pump must not start a turn mid-swap.
    var pumpSuspended = false
    /// The persistable queue content of the last `flushMessageQueue` write (id:state lines) — the
    /// skip-if-unchanged signature. Reset on project switch so the new project always flushes.
    var lastFlushedQueueSignature: [String]?
    /// The scheduled-task sidecar's last written shape — same skip-an-unchanged-write idiom.
    var lastFlushedTaskSignature: [String]?

    // Panel layout — the window's split tree (SZPanelLayoutState, SZCore), host-owned like the chat
    // tab state below; mutated via SZHost+PanelLayout.swift (header drags, dividers, close/reopen),
    // which persists every change back to app-state.json. Restored here (synchronously — the file is
    // ~1 KB) so the FIRST render already shows the saved arrangement; normalize() sanitizes whatever
    // a stale or hand-edited file contains.
    internal(set) var panelLayout: SZPanelLayoutState = {
        var layout = SZAppStateIO.load()?.panelLayout ?? .default
        layout.normalize()
        return layout
    }()

    // A panel blown up to fill the window (the others hidden) — mutated via toggleMaximizePanel
    // (SZHost+PanelLayout.swift). Transient like cameraCommand below: it's a render override, NOT
    // part of the split tree and never persisted, so clearing it restores the exact prior layout
    // (divider fractions untouched). Any structural edit (move/close/reopen) also clears it.
    internal(set) var maximizedPanel: SZPanelID?

    // Panels living in their own windows (pop-outs) — the layout tree's sibling truth, keyed by
    // SZPanelID with the window's screen frame. Same app-state.json + restore story as the layout
    // (the workspace arrangement includes its windows); mutated via SZHost+Popout.swift only. The
    // AppKit windows themselves live on `popoutManager`.
    internal(set) var poppedOutPanels: [SZPanelID: SZPoppedOutPanel] = {
        var map: [SZPanelID: SZPoppedOutPanel] = [:]
        for record in SZAppStateIO.load()?.poppedOutPanels ?? [] { map[record.panel] = record }
        return map
    }()

    /// The pop-out windows' manager (windows, delegates, drag-to-dock tracking). Not observable
    /// state — the observable truths are `panelLayout` + `poppedOutPanels` + the candidate below.
    @ObservationIgnored let popoutManager = SZPopoutWindowManager()

    /// A popped-out window's drag hovering a dock spot — published for the container's
    /// drop-preview overlay (the same affordance as internal header drags).
    internal(set) var popoutDockCandidate: SZPanelDockPreview?

    /// Debounce for pop-out frame persistence (windowDidMove fires per mouse move; the disk write
    /// waits for the drag to settle — SZHost+Popout.notePopoutFrameChanged).
    @ObservationIgnored var popoutFramePersistDebounce: Task<Void, Never>?

    // Node-editor snap-to-grid — same app-state.json home and restore-on-launch story as the layout.
    // Toggled from the Graph menu (SZApp), mutated via setSnapToGrid (SZHost+PanelLayout.swift); also
    // honored by the MCP ui_add_prompt_node / ui_move_node placements, not just human drags.
    internal(set) var snapToGrid: Bool = SZAppStateIO.load()?.snapToGrid ?? true

    // Auto-hiding panel headers (hover the tile's top edge to summon) — same app-state.json + restore
    // story as snap-to-grid, mutated via setAutoHidePanelHeaders. Toggled from the View menu (SZApp),
    // beside the panel-visibility toggles. Defaults OFF: permanent headers are how a newcomer learns
    // what each panel IS.
    internal(set) var autoHidePanelHeaders: Bool = SZAppStateIO.load()?.autoHidePanelHeaders ?? false

    // Node-editor cursor trail (grid dots morph into glyphs near the pointer) — same app-state.json +
    // restore story, mutated via setGridCursorTrail. Toggled from the Graph menu (SZApp), beside Snap to
    // Grid. Defaults ON: it's a subtle bit of polish, and off-canvas/idle it self-dormants (see
    // SZGridCursorTrailView).
    internal(set) var gridCursorTrail: Bool = SZAppStateIO.load()?.gridCursorTrail ?? true

    // Node-editor mini map (the corner overview thumbnail) — same app-state.json + restore story,
    // mutated via setShowMiniMap. Toggled from the Graph menu (SZApp). Defaults ON.
    internal(set) var showMiniMap: Bool = SZAppStateIO.load()?.showMiniMap ?? true

    // Node-editor live previews (per-card thumbnails of texture outputs) — same app-state.json +
    // restore story, mutated via setLivePreviews (SZHost+NodePreviews.swift). Toggled from the Graph
    // menu (SZApp), beside Snap to Grid. Defaults ON: texture nodes auto-preview. The geometry gate
    // (SZNodeLayout.previewsEnabled) is seeded FIRST thing in start() — before any project can load,
    // so no card is ever laid out against the unseeded default — and thereafter written only
    // together with this pref (setLivePreviews), so the card views reflow deterministically on a flip.
    internal(set) var livePreviews: Bool = SZAppStateIO.load()?.livePreviews ?? true

    // Per-node live-preview thumbs (stable observable boxes the cards hold uncompared refs to) and
    // the watch-set plumbing feeding them — all event-driven, see SZHost+NodePreviews.swift.
    let previewFrames = SZNodePreviewFrames()
    /// Custom-card mounts — see `cardHost` (SZHost+NodeBody.swift), created on first access. The
    /// controller is @Observable itself; the host only holds it.
    @ObservationIgnored var cardHostStorage: SZCardHostController?
    /// The armed binding-learn session (at most one — learn is a focused human gesture), see
    /// SZBindingLearnController. Ephemeral: reassignment sites cancel the old one explicitly.
    internal(set) var bindingLearn: SZBindingLearnController?
    /// Debounce for store-observation-triggered watch-set recomputes.
    var previewWatchDebounce: Task<Void, Never>?
    /// The editor's latest visible-node report; nil = no editor report yet ⇒ no culling (headless
    /// and MCP sessions keep streaming without a mounted panel).
    var visiblePreviewNodes: Set<SZNodeID>?
    /// The last watch set pushed to the runtime (ordered keys) — pushes happen only on change.
    var lastPushedWatchKeys: [String] = []

    // Rounded corners on the viewport tile — same app-state.json + restore story, mutated via
    // setViewportRoundedCorners. Toggled from the View menu (SZApp), beside Auto-Hide Panel Headers.
    // Defaults ON: rounded tiles are the app's resting look; off squares just the viewport.
    internal(set) var viewportRoundedCorners: Bool = SZAppStateIO.load()?.viewportRoundedCorners ?? true

    // Welcome/home window — same app-state.json + restore story, mutated via SZHost+Welcome.
    // `showWelcomeAtStartup` (default ON) gates the auto-present on cold launch.
    internal(set) var showWelcomeAtStartup: Bool = SZAppStateIO.load()?.showWelcomeAtStartup ?? true

    // Per-turn token counts under chat replies — same app-state.json + restore story, mutated via
    // setShowTokenCounts. Toggled from the View menu (SZApp). Defaults OFF; display-only — usage is
    // always captured into the transcript, so turning it on later reveals past turns too.
    internal(set) var showTokenCounts: Bool = SZAppStateIO.load()?.showTokenCounts ?? false
    /// Debug ▸ Show Turn Breakdown — the expandable per-turn phase breakdown under replies.
    /// Gated like the Profiler surface: a DEBUG session's saved `true` must not resurface debug
    /// chrome in a release build.
    internal(set) var showTurnBreakdown: Bool =
        SZPanelKind.profilerPanelAvailable && (SZAppStateIO.load()?.showTurnBreakdown ?? false)

    // Anonymous-telemetry opt-out — same app-state.json + restore story, mutated via
    // setTelemetryEnabled (SZHost+Telemetry). Defaults ON (nil/absent in app-state.json means ON);
    // SZTelemetry consults this live per send, so a mid-session toggle takes effect immediately,
    // heartbeat included.
    internal(set) var telemetryEnabled: Bool = SZAppStateIO.load()?.telemetryEnabled ?? true

    // Node-editor camera commands (Graph ▸ Center View / Zoom to Fit). The camera (zoom/offset) is
    // panel-local @State, unreachable from here, so the host raises a one-shot command the panel
    // observes and applies. Transient (never persisted): the camera itself resets on panel appear.
    // Each issue carries a fresh token so pressing the same item twice re-fires the panel's .onChange.
    internal(set) var cameraCommand: SZCameraCommand?

    // Project lifecycle (roadmap Task 1) — same app-state.json home + restore story as the prefs
    // above; mutated by `switchProject` (and Open Recent ▸ Clear via SZHost+ProjectLifecycle).
    /// File ▸ Open Recent, newest first (`.subz` paths).
    internal(set) var recentProjectPaths: [String] = SZAppStateIO.load()?.recentProjectPaths ?? []
    /// The project to reopen next launch (the last USER-opened one — an `SZ_PROJECT` env launch
    /// never writes it).
    internal(set) var lastOpenProjectPath: String? = SZAppStateIO.load()?.openProjectPath

    /// Untitled = living in the untitled projects' directory — derived from the URL, never stored
    /// (SZUntitledProjects). Drives the window title's "not saved" suffix and Save As's source cleanup.
    var isUntitledProject: Bool { loadedProjectURL.map(SZUntitledProjects.contains) ?? false }

    /// Set by `debug_quit` before it terminates: the untitled-rescue prompt waits for a
    /// human an automated drive doesn't have (the untitled project is autosaved anyway).
    var quitSkipsUntitledRescue = false

    /// The window title: the project's name, suffixed while the project is still untitled. App
    /// name before anything is loaded (launch, Metal-less fallback).
    var projectWindowTitle: String {
        guard let project = store.project else { return "SubjectiveZero" }
        return isUntitledProject ? "\(project.name) — not saved" : project.name
    }

    // Chat panel UI state — host-owned so BOTH the SwiftUI panel and the `ui_*` MCP surface
    // drive it. There is ONE conversation, so there is no selection to keep.
    /// Panel shown? Now derived from the layout tree — chat visibility IS chat's presence in it.
    var chatVisible: Bool { panelLayout.contains(.chat) }
    /// A host-drafted composer message awaiting the panel (a context-menu suggestion click). The
    /// panel consumes it exactly once (`consumeComposerDraft`) so a re-render can't stomp edits.
    internal(set) var pendingComposerDraft: SZComposerDraftInjection?
    /// A node mention awaiting the composer (a card's chat button). Consumed once, like the draft.
    internal(set) var pendingComposerMention: SZComposerMentionInjection?

    /// THE SCHEDULED TASKS awaiting admission, oldest first. The Build press, `ui_run` and the
    /// door's scheduling effect append here; the pump's head admits every task whose work set is
    /// free — ahead of any queued prose, and a blocked task never blocks a later disjoint one.
    internal(set) var pendingTasks: [SZTask] = []
    /// Set by Stop, cleared by the next thing the user asks for. Without it, stopping a run is
    /// answered by the queue starting the next one — which reads as the app ignoring the Stop.
    internal(set) var admissionSuspended = false

    /// When this project first opened under the one-feed build — everything in a node's transcript
    /// older than this is that node's build history, not part of the conversation. See
    /// `SZHost.feedEpoch(projectURL:)`.
    internal(set) var feedEpoch: Date = .distantPast


    /// The provider new agent sessions use — Director Agent runs and a first-turn Director Agent chat.
    /// Resuming a node's Coding Agent ignores this (a resume must continue on the CLI that owns it). Set
    /// by the composer cluster / `ui_set_provider` / the setup sheet's Confirm. Initialized from the
    /// confirmed default (app-state.json), registry-validated so a stale id degrades to the registry
    /// default. A post-first-run switch persists as the default (the cluster is front-and-center — a
    /// selection that silently reverted on relaunch would surprise) and resets agent sessions
    /// (`setActiveProvider`); Confirm remains the first-run seed.
    private(set) var activeProviderID =
        SZAppStateIO.load()?.defaultProviderID
            .flatMap { SZProviderRegistry.shared.provider(id: $0)?.id }
        ?? SZProviderRegistry.shared.defaultProvider.id

    /// Per-provider generation choices (model / reasoning effort / fast mode), keyed by provider id —
    /// the preference half of provider selection (WHICH provider is active is `activeProviderID`'s
    /// story above). Same app-state.json home + restore story as the layout prefs; persisted
    /// immediately on change (the snapToGrid story, not the Confirm story) via the
    /// SZHost+GenerationSettings mutators. Rows are stored raw and clamped at use
    /// (`resolvedGenerationSettings(for:)`), so a stale model id degrades instead of breaking.
    internal(set) var providerGenerationSettings: [String: SZProviderGenerationSettings] =
        SZAppStateIO.load()?.providerGenerationSettings ?? [:]

    /// Saved routing profiles + the active one's name — model routing's data (docs/
    /// AI_PROVIDERS.md). Same app-state.json home + restore story as the generation rows:
    /// stored raw, resolved against the live registry/catalogs per delivery
    /// (SZHost+Routing.swift). nil active name = routing off, byte-identical to before
    /// profiles existed. SZ_MODEL_ROUTING overrides at launch without rewriting either.
    internal(set) var routingProfiles: [SZRoutingProfile] =
        SZAppStateIO.load()?.routingProfiles ?? []
    internal(set) var activeRoutingProfileName: String? =
        SZAppStateIO.load()?.activeRoutingProfileName
    /// Fallback sentences already narrated for the current profile state — chat deliveries
    /// resolve per message, and a broken route should say its sentence once, not per send.
    /// Cleared by every profile mutation (SZHost+Routing.swift).
    var narratedRoutingNotes: Set<String> = []

    // Provider health + the Agent Providers setup sheet (docs/AI_PROVIDERS.md) — host-owned so the
    // sheet, the HUD health dot, and the run/chat pre-flights read ONE truth; mutated via
    // SZHost+ProviderHealth.swift.
    /// The setup sheet's confirmed default. nil = first-run setup not confirmed yet, which is the
    /// sheet's auto-present gate. Same app-state.json home + restore story as the layout prefs.
    internal(set) var defaultProviderID: String? = SZAppStateIO.load()?.defaultProviderID
    /// Providers the user disabled from the setup sheet — skipped by health checks and probes,
    /// dimmed in the composer picker, refused by the pre-flights and `setActiveProvider`. Same
    /// app-state.json home + restore story as the layout prefs; the card's Enable is the way back
    /// (SZHost+ProviderHealth owns the mutator and its never-strand/never-empty guards).
    internal(set) var disabledProviderIDs: Set<String> = Set(SZAppStateIO.load()?.disabledProviderIDs ?? [])
    /// Latest cheap-tier report (install + auth — token-free) per provider id.
    internal(set) var providerHealth: [String: SZProviderHealthReport] = [:]
    /// Sticky probe verdicts (tier 3, token-costing). Displayed over a bare cheap `ready`
    /// (deeper truth); dropped when a provider's cheap status transitions — the world changed.
    internal(set) var providerProbes: [String: SZProviderHealthReport] = [:]
    /// Providers with a probe in flight — the per-card Test spinner.
    internal(set) var probingProviders: Set<String> = []
    /// Last-known dynamic model catalogs, keyed by provider id — for providers whose served models
    /// are enumerated from the CLI at runtime (pi; static-manifest providers never appear here).
    /// Seeded into the providers at launch so the picker serves last-known truth offline, refreshed
    /// on cheap-status ready transitions (SZHost+ProviderHealth), persisted to provider-catalogs.json.
    internal(set) var providerModelCatalogs: [String: SZProviderModelCatalog] = SZProviderCatalogIO.load()
    /// Providers with a catalog fetch in flight — collapses the sheet poll's 3s ticks.
    internal(set) var catalogRefreshesInFlight: Set<String> = []
    /// The Agent Providers sheet. Auto-presents on a first-run launch; reopened any time via the
    /// app menu (⌘,) or the HUD health dot.
    var providerSetupPresented = false
    /// The first-run sheet auto-presents at most once per launch. Transient: without it, every
    /// Help ▸ Welcome round-trip would re-nag a user who chose Skip for Now.
    var providerSetupAutoPresented = false
    /// The welcome/home overlay. Auto-presents on every cold launch when enabled; reopened via
    /// Help ▸ Welcome or the HUD gear. Transient — never persisted (SZHost+Welcome drives it).
    var welcomePresented = false
    /// The card selected in the sheet (the radio) — Confirm's target.
    var selectedSetupProviderID: String?
    /// The sheet's cheap-tier re-check loop (~3s) — alive only while the sheet is open, so a just
    /// installed / just-logged-in CLI flips its card green without a manual Refresh.
    var providerHealthPollTask: Task<Void, Never>?
    /// The compiled-step execution table for the graph orchestrator's condition steps — one
    /// instance for the host's lifetime, so a re-scheduled step coalesces into the runtime's
    /// latest-source-wins compile instead of rebuilding a cold table every run.
    let stepRuntime = SZStepRuntime()
    /// In-flight interactive chat turns by scope key (`sendChat`'s tasks) — retained so the
    /// transcript's per-turn stop control can cancel ONE scope's turn (`cancelChatTurn`) without
    /// touching the others; a run's coding turns ride `runTask` instead.
    internal(set) var chatTurnTasks: [String: Task<Void, Never>] = [:]
    /// Whether ANY run is live (drives the HUD Run↔Stop state). Node locking stays per-node: a
    /// node no live run claims is editable while another run builds elsewhere.
    var isRunning: Bool { !activeRuns.isEmpty }

    /// Is this claim a live run's? The fence asks before it lets an agent mutate its own work.
    func isRunClaim(_ token: SZClaimToken?) -> Bool {
        guard let token else { return false }
        return activeRuns.values.contains { $0.claim == token }
    }

    /// The run this claim belongs to, or nil if it was released (the caller is a zombie).
    func activeRun(for claim: SZClaimToken?) -> SZRunState? {
        guard let claim else { return nil }
        return activeRuns.values.first { $0.claim == claim }
    }

    /// The run implementing this node, if any — how a per-node write finds its run's evidence.
    func activeRun(holding node: SZNodeID) -> SZRunState? {
        activeRuns.values.first { $0.workSet.contains(node) }
    }

    /// The longest-running live run — the anchor for surfaces that still speak of "the" run.
    var oldestRun: SZRunState? { activeRuns.values.min { $0.startedAt < $1.startedAt } }

    /// Every live build, oldest first — what the chat strip lists. One row per run, because with
    /// concurrent runs "the" run is not a thing a surface can show.
    var liveThreadIDs: [UUID] {
        activeRuns.values.sorted { $0.startedAt < $1.startedAt }.map(\.thread)
    }

    /// Is this object still THE registered run? A cancelled run's task unwinds later as a zombie;
    /// every write it makes past that point must be dropped.
    func isLive(_ run: SZRunState) -> Bool { activeRuns[run.taskID] === run }

    /// HUD playback state — whether the render timeline is paused (drives the Pause/Play toggle). The
    /// runtime owns the actual clock; this mirrors it for the observable UI. Reset to `false` on every
    /// project switch (`clearPerProjectState`).
    internal(set) var isPaused = false

    /// The `SZ_PROJECT` env override — the dev recipe (`launchctl setenv SZ_PROJECT … && open -n`,
    /// GRAPH_AND_NODES.md). nil when unset; the launch chain then falls to the last open project,
    /// else a first-launch copy of the bundled sample (`openInitialProject`, SZHost+
    /// ProjectLifecycle.swift). An env-opened project is deliberately NEVER recorded in
    /// `openProjectPath`/recents — a debug launch must not clobber the user's history.
    static var envProjectURL: URL? {
        guard let path = ProcessInfo.processInfo.environment["SZ_PROJECT"], !path.isEmpty else { return nil }
        return URL(filePath: path)
    }

    /// The built-in node library (umbrella root `NodeLibrary/`), browsed by the coding agents through
    /// the `agent_library_*` tools and copied into a project by `instantiateLibraryNode` (drag-and-drop).
    /// Prefer the copy bundled in the app (`NodeLibrary` is a folder reference in Resources), so a packaged
    /// build works; fall back to the source tree via `#filePath` for `swift test` / running from the
    /// checkout, where the bundle has no resources.
    nonisolated static var libraryURL: URL {
        if let bundled = Bundle.main.resourceURL?.appending(path: "NodeLibrary"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "NodeLibrary")
    }

    /// Instantiate the runtime, vend the viewport render closure, open the launch project (env
    /// override → last open → first-launch sample copy; SZHost+ProjectLifecycle.swift), and start
    /// the app-level services. Loading is delegated to `switchProject` — launch is just the first
    /// switch.
    func start(openingIfLaunchedWithFile launchFileURL: URL? = nil) async {
        guard !started else { return }
        started = true
        // The bundled agent packs become the writable, watched packs root — before anything
        // (a run, the Plan panel, a debug tool) can ask for them.
        materializeAgentPacks()
        installStoreFenceBackstop()   // the fence's debug tripwire (SZHost+Fence.swift)
        if SZTrace.isEnabled { loadHeldPromptIDs() }   // past sessions' captured prompts light up
        // The pump's wake signal: every ledger release (turn end, run end, cancel) retries queued
        // deliveries. Event-driven — the only other pump entries are enqueue and restore.
        ledger.onAvailabilityChanged = { [weak self] in self?.pumpMailboxes() }
        // Queue durability: every enqueue/state change flushes the sidecar (queue-before-transcript
        // at enqueue is what makes the crash direction tolerable — see sendChat).
        mailbox.onChange = { [weak self] in self?.flushMessageQueue() }
        // Geometry gate follows the restored pref BEFORE anything can render a card (project loads
        // below) — and before the Metal-unavailable early return, which must not strand the gate at
        // its compile-time default while the pref says otherwise.
        SZNodeLayout.previewsEnabled = livePreviews

        guard let runtime = SZRuntime() else {
            status = "Metal device unavailable"
            return
        }
        self.runtime = runtime
        popoutManager.host = self   // the windows' back-channel (dock intents, frame persistence)
        syncViewportDriver()        // the driver follows surface attach events from here on
        installPreviewFrameSink(runtime)
        armPreviewGraphObservation()

        // Route the launch: on a cold launch we show the welcome/home surface as the FIRST view and
        // open NOTHING yet — so launch never touches the camera/mic until the user picks a project
        // (continue/New/Open/Recent all load through switchProject, which dismisses welcome). A first
        // run routes here too; its provider sheet follows on the way out (switchProject's tail).
        // A Finder .subz open bypasses welcome and opens directly. CLI (`--skip-welcome` /
        // `--open <path>`, SZLaunchOptions) also bypasses it — the deterministic entry point for
        // automated tests, which need a live rendered viewport to capture.
        let options = SZLaunchOptions.parse()
        let fileToOpen = launchFileURL ?? options.projectURL
        if !options.skipWelcome && shouldRouteToWelcomeOnLaunch(launchedWithFile: fileToOpen != nil) {
            welcomePresented = true
        } else {
            await openInitialProject(preferred: fileToOpen)
        }
        // App-level services — deliberately outside the project chain: a project that failed to
        // load must not take the MCP bus down with it.
        startMCPServer()
        // Only now can a task start (startRun needs the bus): the restore above pumped into a
        // host with no MCP server, so every restored ask answered `.waiting` and nothing was
        // left to wake it.
        pumpMailboxes()
        #if DEBUG
        verifyGrayscale()
        #endif
        // Independent of project load (a dead project must not hide a dead provider):
        // one cheap health pass, then first-run auto-present (SZHost+ProviderHealth.swift).
        checkProviderSetupOnLaunch()
        // Anonymous usage telemetry (SZHost+Telemetry.swift) — a no-op without a bundled key.
        startTelemetry()
    }

    /// Switch the live document to another `.subz` — THE project-open path for launch, File ▸
    /// New / Open… / Open Recent, and Save As. Ordered so every fallible step happens BEFORE the
    /// old project is disturbed: validate the new bundle, await its declared permissions (the ONLY
    /// await — everything after runs as one uninterruptible MainActor stretch, so no MCP command or
    /// watcher event interleaves with the swap), flush the old project's durable state, swap the
    /// runtime (self-tearing-down: a throw releases the new load's partial state — including
    /// exclusive devices like the camera — and the old graph keeps rendering), then tear down
    /// per-project host state and rebuild it against the new URL. The MCP bridge needs no rebind:
    /// it reads `store`/`loadedProjectURL` live, same port. A throw leaves the old project fully
    /// live; the two refusals (busy, already open) return false without throwing.
    /// `recordInHistory: false` is the `SZ_PROJECT` dev override's path — no MRU/reopen writes.
    @discardableResult
    func switchProject(to newURL: URL, recordInHistory: Bool = true) async throws -> Bool {
        guard let runtime else {
            status = "no runtime — cannot open a project"
            return false
        }
        // Refusals, not errors: a run/chat in flight owns the graph (menu items are disabled, but
        // the MCP surface can race a click), and re-opening the open project is a no-op.
        guard !isBusyForProjectOps else {
            status = "busy — stop the run / wait for chat before switching projects"
            return false
        }
        // Resolve symlinks too (e.g. /tmp vs /private/tmp): reopening the SAME bundle through a
        // different-but-equivalent path is a no-op, not a self-conflict — without this the lock
        // acquire below would EWOULDBLOCK on our own fd and misreport "open in another instance".
        if let current = loadedProjectURL,
           current.resolvingSymlinksInPath().standardizedFileURL
             == newURL.resolvingSymlinksInPath().standardizedFileURL {
            status = "already open: \(newURL.lastPathComponent)"
            return false
        }

        // 1. Validate first — a corrupt bundle must fail before the old project is touched. A
        //    persisted data cycle (a hand edit, an external writer) is repaired here — newest
        //    cycle-closing edges dropped — rather than left to throw out of the scheduler below,
        //    which used to forget the project and boot the sample. Saved back to disk in step 4.
        var project = try SZProjectIO.load(from: newURL)
        let repairedEdges = project.graph.repairDataCycles()
        // 2. The only await: permissions (camera…) before the camera node's setup runs.
        try await runtime.requestDeclaredPermissions(at: newURL)
        // Re-check after the await: the busy guard above passed, but an event-driven delivery (the
        // mailbox pump fires on ledger releases) can start a turn inside that one suspension —
        // and everything below tears the project down under it. The pump is also suspended for the
        // rest of the swap (resumed by the defer installed here, on every exit path).
        pumpSuspended = true
        defer {
            pumpSuspended = false
            pumpMailboxes()
        }
        guard !isBusyForProjectOps else {
            status = "busy — a turn started while opening; try again"
            return false
        }
        // 2b. Take the per-instance lock before disturbing the old project — a second running
        // instance holding this project surfaces as `alreadyOpenElsewhere`, and the old project
        // (and its lock) stay fully live. Held locally until the point of no return.
        let newLock: SZProjectDirectoryLock
        do {
            newLock = try SZProjectDirectoryLock.acquire(forProjectAt: newURL)
        } catch SZProjectLockError.alreadyLocked {
            throw SZProjectLifecycleError.alreadyOpenElsewhere
        }
        // 3. Flush the old project's durable state (transcripts, sessions, graph).
        if loadedProjectURL != nil {
            flushAllTranscripts()
            persistAgentSessions()
            persistProject()
        }
        // 4. Last fallible step: the runtime swap. On failure, drop the lock we just took (the old
        // project keeps rendering, its lock untouched). The runtime reads from disk, so a repaired
        // graph must land there first.
        do {
            if !repairedEdges.isEmpty { try SZProjectIO.save(project, to: newURL) }
            try runtime.loadProject(at: newURL)
        } catch {
            newLock.release()
            throw error
        }
        // 5. Point of no return — synchronous to the end. Hand ownership to the new lock.
        projectLock?.release()
        projectLock = newLock
        stopAllNodeSourceWatchers()
        clearPerProjectState()
        loadedProjectURL = newURL
        store.setProject(project)
        restoreTranscripts()            // chat history + resumable sessions (replaces the old map)
        restoreAgentGraphRuns()         // the RUNS panel's history sidecar (SZHost+GraphRuns.swift)
        if !repairedEdges.isEmpty {
            let title: (SZNodeID) -> String = { [store] in store.project?.graph.node(id: $0)?.title ?? $0.uuidString }
            let edges = repairedEdges.map { "\(title($0.from.node)) → \(title($0.to.node))" }.joined(separator: ", ")
            narrateDirector("This project's graph had a data cycle on disk — removed "
                + (repairedEdges.count == 1 ? "the connection" : "\(repairedEdges.count) connections")
                + " \(edges) so it can render. Rewire differently if that edge mattered.")
        }
        // `load` already flagged nodes whose source contradicts their contract; attach the diagnostics so those
        // cards show WHY, not just that. After clearPerProjectState, so the details survive.
        classifyRebuildsAfterLoad()
        watchNodeSources(in: newURL)
        // Fresh graph, fresh thumbs: blank every box (old-project frames must not flash on the new
        // canvas) and re-point the runtime's watch set — the refresh also prunes dead boxes.
        previewFrames.clear()
        refreshPreviewStream()
        // 6. History — skipped for the env override so a debug launch can't clobber the user's.
        if recordInHistory {
            let path = newURL.standardizedFileURL.path
            lastOpenProjectPath = path
            noteRecentProject(path)
            persistAppState()
        }
        status = "loaded \(newURL.lastPathComponent)"
        print("[SZHost] loaded project — edit any node's Node.swift to hot-reload:\n  \(newURL.path)")
        // A project is now live — leave the welcome/home surface (the one common exit for New / Open /
        // Open Recent / continue). SZHost+Welcome. Leaving welcome is also where a first run finally
        // meets provider setup: the sheet cannot open over welcome, so it waits for this moment.
        let leftWelcome = welcomePresented
        welcomePresented = false
        if leftWelcome { autoPresentProviderSetupIfNeeded() }   // SZHost+ProviderHealth
        return true
    }

    /// Release the current instance lock (quit path). Best-effort — `flock` also frees on process
    /// exit — but releasing eagerly lets a relaunch reopen the same project without waiting on the
    /// OS to reap the descriptor.
    func releaseProjectLock() {
        projectLock?.release()
        projectLock = nil
    }

    /// Discard the current UNTITLED project — the Discard choice on the close/quit rescue prompt.
    /// Releases its lock, stops the node-source watchers (their `nodes/` files are about to vanish,
    /// so they mustn't fire on the delete), nils the loaded URL so the terminate-time flush can't
    /// resurrect the folder, then deletes its `Projects/<uuid>/` home and prunes its recents/session
    /// entries. Both callers close/terminate immediately after, so the now-stale in-memory
    /// `store.project` is torn down before it's rendered again.
    func discardUntitledProject() {
        guard isUntitledProject, let url = loadedProjectURL else { return }
        releaseProjectLock()
        stopAllNodeSourceWatchers()
        loadedProjectURL = nil
        let fm = FileManager.default
        try? fm.removeItem(at: url.deletingLastPathComponent())   // the Projects/<uuid>/ layer
        pruneRecentProject(url.standardizedFileURL.path)
        try? SZAgentSessionIO.save([:], projectURL: url)
    }

    /// Drop every per-project host cache and per-node state — the teardown half of
    /// `switchProject`'s point of no return. Lives here (not the lifecycle extension) because it
    /// touches the private `optionsCache`. `inFlightAssistantIDs` is empty behind the busy guard;
    /// clearing it anyway keeps the invariant local. The store's chat map is NOT cleared here —
    /// `restoreTranscripts` replaces it wholesale right after.
    /// HUD Pause/Play toggle: flip the observable state and tell the runtime to freeze/resume the clock.
    func togglePlayback() {
        isPaused.toggle()
        runtime?.setPaused(isPaused)
    }

    /// HUD Reset Time (rewind): restart the render clock at t=0 / frame 0. Leaves the paused/playing
    /// state as-is (a reset while paused holds the fresh first frame).
    func resetPlayback() {
        runtime?.resetTimeline()
    }

    /// Note nodes CREATED by a run's own tooling (Director split/merge, `ui_add_prompt_node` mid-run)
    /// into ITS work set — the single place the "created via the run" rule lives. The run is the
    /// CALLER's: the per-turn MCP listener binds `SZToolCaller.claim`, so work created by one run's
    /// tooling can never join another's. No-op off-run (a cancelled run's zombie presents a released
    /// claim), so callers invoke it unconditionally. The claim grows with the work set: fresh uuids
    /// are free by construction, so the acquire cannot contend.
    func noteRunCreatedWork(_ ids: Set<SZNodeID>) {
        // The CALLER's run and nothing else. A "the only live run" fallback attributed work
        // created by a Director chat turn, the standing agent bus or a drive to a run that never
        // asked for it — which then implemented, accounted for and painted pills on those nodes.
        guard let run = activeRun(for: SZToolCaller.claim) else { return }
        // A node ANOTHER run already holds is not ours to adopt. The fence refuses such an edit
        // upstream, so this is the belt: skip it rather than assert, because with runs concurrent
        // "contended" is a legitimate state rather than the impossibility it used to be.
        let mine = ids.filter { id in
            let holder = ledger.holder(of: .node(id))
            return holder == nil || holder == run.claim
        }
        guard !mine.isEmpty else { return }
        run.workSet.formUnion(mine)
        var resources: Set<SZResourceID> = []
        for id in mine {
            resources.insert(.node(id))
            resources.insert(.transcript(.node(id)))
        }
        let claimed = ledger.tryAcquire(resources, as: run.claim)
        assert(claimed, "noteRunCreatedWork: uncontended nodes failed to claim — "
            + ledger.blockers(of: resources).map(\.label).joined(separator: ", "))
    }

    /// A split/merge is staged and awaiting its run's commit. Only one at a time (see `pendingGraphOp`).
    var hasStagedGraphOp: Bool { pendingGraphOp != nil }

    private func clearPerProjectState() {
        resetPreviewStreamForProjectSwitch()   // SZHost+NodePreviews — the one unwatch/teardown home
        cardHostStorage?.unmountAll()          // card mounts + their Card.swift watchers die with the project
        bindingLearn?.cancel()                 // an armed learn must not outlive its source's project
        bindingLearn = nil
        nodeAgentState = [:]
        // IN-MEMORY reset only — never a disk write: this runs while `loadedProjectURL` still points
        // at the OLD project, and a flush-empty here would delete that project's queue file (the
        // envelopes that were supposed to survive the switch). Parked waiters resume `.removed`.
        mailbox.reset()
        lastFlushedQueueSignature = nil   // the new project's first flush must not be skipped
        lastFlushedTaskSignature = nil
        assert(!ledger.anyWaiting && !mailbox.anyAwaiting,
               "project teardown with a parked wait — a continuation would leak")
        forcedFailNodes = [:]
        mutationJournal.removeAll()
        // IN-MEMORY reset only, like the mailbox: the OLD project's runs.json is written at
        // each begin/note/seal (a pending coalesced write is dropped, never redirected at the
        // new project); the new project's history is restored right after the swap.
        agentGraphRunsPersistDebounce?.cancel()
        agentGraphRunsPersistDebounce = nil
        agentGraphRuns = []
        graphOpStatus = [:]
        hiddenPieces = []
        pendingGraphOp = nil
        dispatchPrompts = [:]
        nodeGrades = [:]
        activeRuns = [:]           // nothing runs across a switch (the busy gate holds), but the
        pendingTasks = []          // invariant stays local: a task scheduled for A never sees B
        admissionSuspended = false // a Stop in A must not freeze B's queue, where nothing stopped
        agentSessions = [:]
        restoredSessions = [:]
        inFlightAssistantIDs = [:]
        optionsCache = [:]
        lastBuildErrors = nil
        // A freshly opened project starts playing from t=0 — reset the render clock and clear any pause
        // carried over from the previous project. (Deliberately here, not in `runtime.loadProject`, so
        // incremental live reloads — promote / graph edits — never yank the animation back to 0.)
        // `resetTimeline` deliberately preserves the paused/playing state, so clearing the mirror alone
        // left the runtime clock paused behind a HUD reading Play — frozen viewport, and (since ABI v7)
        // suspended node resources with it. Tell the runtime, which owns the clock.
        runtime?.setPaused(false)
        runtime?.resetTimeline()
        isPaused = false
    }

    /// Stop every node-source watcher (project switch). The per-node stop
    /// (`stopWatchingNodeSource`) stays the delete path's tool.
    private func stopAllNodeSourceWatchers() {
        for (_, watcher) in watchers { watcher.stop() }
        watchers = [:]
    }

    /// Watch each node's `Node.swift`; on save, hot-reload just that node (`reloadEditedNode`). Idempotent
    /// and re-runnable: it tracks already-watched node ids and only adds watchers for new folders, so it can
    /// be called again after a promote / graph edit to pick up nodes created this session. A folder with no
    /// `Node.swift` yet (an un-implemented prompt node) is skipped and watched on a later pass once promoted.
    private func watchNodeSources(in url: URL) {
        let nodesDir = url.appending(path: "nodes")
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: nodesDir, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            // The folder name IS the node uuid; skip non-uuid folders and ones we already watch. Also
            // skip folders whose node is NOT in the graph — a deleted node's folder is deliberately
            // left on disk as a source safety net (TODO: remove once undo/checkpoints ship) and must
            // not be (re-)watched.
            guard let nodeID = UUID(uuidString: folder.lastPathComponent),
                  watchers[nodeID] == nil,
                  store.project?.graph.node(id: nodeID) != nil else { continue }
            let source = folder.appending(path: "Node.swift")
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let watcher = SZSourceWatcher(watching: source)
            watcher.start { [weak self] in self?.reloadEditedNode(id: nodeID) }
            watchers[nodeID] = watcher
        }
    }

    /// Stop watching a node's source (node delete) — an edit to the orphaned `nodes/<id>/` folder must
    /// not resurrect ghost agent state for a node no longer in the graph.
    func stopWatchingNodeSource(_ id: SZNodeID) {
        watchers.removeValue(forKey: id)?.stop()
    }

    /// Start the host's MCP command buses on free local ports and log how to reach them.
    ///
    /// Two listeners over one bridge. The `.full` bus is the closed-loop test surface; the `.agent` bus is
    /// what spawned agents dial, and it withholds `debug_*` — an agent that can freeze the clock or force a
    /// node to fail is not running the graph a user would. A raw TCP connection carries no identity, so the
    /// port IS the identity.
    private func startMCPServer() {
        // Both buses, or retry: a session whose agent bus failed once must not run agentless forever.
        guard mcpServer == nil || agentMCPServer == nil else { return }
        let bridge = hostBridge ?? SZHostBridge(host: self)
        hostBridge = bridge
        do {
            let server = try mcpServer ?? SZMCPServer.start(bridge: bridge, surface: .full)
            mcpServer = server
            print("[SZHost] MCP server on 127.0.0.1:\(server.port) — try: nc localhost \(server.port)")
        } catch {
            print("[SZHost] MCP start failed: \(error)")
            return
        }
        do {
            let server = try SZMCPServer.start(bridge: bridge, surface: .agent,
                                               from: (mcpServer?.port ?? 42100) + 1)
            agentMCPServer = server
            let note = SZHostBridge.Surface.agentDebugToolsAllowed ? " (debug_* ALLOWED — SZ_AGENT_DEBUG_TOOLS=1)" : ""
            print("[SZHost] agent MCP server on 127.0.0.1:\(server.port)\(note)")
        } catch {
            print("[SZHost] agent MCP start failed: \(error)")
        }
    }

    // MARK: - Staging → promote

    /// Promote a successfully compile-checked staged node into the live project (STATE.md):
    /// copy `.staging/nodes/<id>/Node.swift` → live, apply `contract` (kind → generated), persist
    /// `project.json` + contracts, then reload the runtime so the new module renders. Called by
    /// `agent_compile_node` ONLY after `compileNodeSource` returns `.ok`, so a broken source can never
    /// reach here — live state stays intact on failure.
    ///
    /// `contract` is what the promote gate already merged and audited (`SZPortBindingAudit.auditForPromote`)
    /// — nil when the agent staged none, and the node's live contract then stands.
    func promoteStagedNode(id: SZNodeID, contract: SZNodeContract?) throws {
        // Host sequencing measured as a SPAN (closure, not begin/defer) so the reload sub-span
        // nests UNDER promote in the event tree — rendered flat, promote and reload read as
        // siblings whose numbers double-count. A thrown promote still records (span guarantees).
        try SZTrace.span(SZTurnStage.promote) {
            try promoteStagedNodeInner(id: id, contract: contract)
        }
        trackNodeBuiltTelemetry()   // reached only on success — a throw above skips it
    }

    private func promoteStagedNodeInner(id: SZNodeID, contract: SZNodeContract?) throws {
        guard let projectURL = loadedProjectURL else { throw SZMCPError.message("no project loaded") }
        let fm = FileManager.default
        let staging = projectURL.appending(path: ".staging/nodes/\(id.uuidString)")
        let live = projectURL.appending(path: "nodes/\(id.uuidString)")
        try fm.createDirectory(at: live, withIntermediateDirectories: true)

        // Copy the staged source over the live one. Note whether the source actually CHANGED first: a
        // contract-only re-edit (a slider range, a title) can restage a byte-identical Node.swift, and
        // recompiling it needlessly tears down + re-acquires an exclusive device (a camera-session hiccup)
        // for zero shader change — so the in-place recompile below is gated on a real source change.
        let liveSource = live.appending(path: "Node.swift")
        let stagedSource = staging.appending(path: "Node.swift")
        let sourceChanged = (try? Data(contentsOf: liveSource)) != (try? Data(contentsOf: stagedSource))
        if fm.fileExists(atPath: liveSource.path) { try fm.removeItem(at: liveSource) }
        try fm.copyItem(at: stagedSource, to: liveSource)

        // The node's custom card, if the agent staged one: copy it beside Node.swift. The card
        // host's per-mount watcher sees the mtime move and recompiles/remounts on its own; the
        // FIRST card a node ever gets also turns the card on (below, once the body can validate
        // against the file) — an agent that just authored a control surface expects to see it.
        let stagedCard = staging.appending(path: "Card.swift")
        let liveCard = SZProjectIO.cardSourceURL(projectURL: projectURL, nodeID: id)
        let hadCard = fm.fileExists(atPath: liveCard.path)
        var cardArrived = false
        if fm.fileExists(atPath: stagedCard.path) {
            if hadCard { try fm.removeItem(at: liveCard) }
            try fm.copyItem(at: stagedCard, to: liveCard)
            cardArrived = !hadCard
        }

        // Apply the merged contract (if the agent staged one) and flip the node to generated.
        store.mutate { project in
            guard let i = project.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
            project.graph.nodes[i].kind = .generated
            if let contract {
                // The contract the gate MERGED (`SZNodeContract.mergingAuthored(_:intoNode:)`) rather than
                // either side wholesale: the live contract carries the typed boundary the graph is wired
                // against AND the user's current input values, while the agent just authored the control
                // ports its new source reads. Taking the live one deletes those ports (the source then reads
                // what the contract never declares); taking the authored one resets every slider and can
                // retype a wired port. The merge reads the live state at promote time — the same MainActor
                // turn as this write — so a mid-run `ui_edit_ports`, a slider drag, and an off-run chat
                // rebuild are all honoured, and the audit that gated the promote saw exactly this contract.
                // Identity is the NODE's (placeholders aside), so a promote never renames a card — a rename
                // is an explicit `ui_update_node`.
                project.graph.nodes[i].contract = contract
                project.graph.nodes[i].title = contract.title
                project.graph.nodes[i].sfSymbol = contract.sfSymbol
            }
            // The build stamp — the ONE place it is written from a real compile: what this source was compiled
            // against (the merged surface above) and the brief the agent was actually given. `rebuildReason`
            // derives from it: the surface it built against is honoured; a prompt that moved after dispatch
            // (a Director re-brief mid-run, a user edit) reads `.intentChanged`, because the code implements
            // what the prompt used to say. No dispatch record (a node-scoped chat turn, an off-run compile)
            // → the current prompt is the brief.
            project.graph.nodes[i].buildStamp = SZBuildStamp(
                portSurface: project.graph.nodes[i].contract?.portSurface ?? [],
                prompt: dispatchPrompts[id] ?? project.graph.nodes[i].prompt)
            // First card for this node → show it (an explicit `.none` the user chose earlier stands;
            // nil / auto-preview flips to custom). Part of the promote's own store write — it is the
            // run's work, so it does not go through the user/agent fence like `applyNodeBody` would.
            if cardArrived, project.graph.nodes[i].body?.mode != SZNodeBodyMode.none {   // (`.none` alone would mean nil)
                project.graph.nodes[i].body = SZNodeBody(mode: .custom, custom: SZCustomCardRef())
            }
        }

        // Persist project.json + per-node contracts, then hot-reload.
        if let project = store.project { try SZProjectIO.save(project, to: projectURL) }
        // A re-edit of an ALREADY-LOADED node (e.g. a Coding Agent chat adding an input to a live node):
        // loadProject treats it as `retained` and will NOT recompile its changed source — it only compiles
        // ids new to the live graph — so the promoted Node.swift would silently stay the stale build (the
        // running shader keeps ignoring the new input). Recompile it in place first, via the same hot-reload
        // path the file watcher uses; loadProject then reconciles the contract + seeds any new input value.
        // Only when the source actually changed — a contract-only promote skips the recompile (see above).
        try SZTrace.span(SZTurnStage.promoteReload) {
            if sourceChanged, runtime?.isNodeLoaded(id) == true {
                try runtime?.reloadNode(id: id, source: liveSource)
            }
            try runtime?.loadProject(at: projectURL)
        }
        watchNodeSources(in: projectURL)          // a newly-generated node becomes hot-reloadable
        if cardArrived { refreshPreviewStream() } // the card host mounts the body flipped above
        clearTransientAgentStateAfterPromote(id)  // a green compile outranks any earlier utterance
        classifyRebuild(node: id)                 // re-audit the promoted source: mismatch is derived, never latched
        activeRun(holding: id)?.promoted.insert(id)   // that run's success evidence
        // The staged folder has done its job — drop it so a later compile can't re-promote stale bytes
        // (it must re-stage). Failed promotes above keep it for inspection; the rest of `.staging/`
        // (instance.lock, message-queue.json) is not ours to touch.
        try? fm.removeItem(at: staging)
        status = "promoted \(id.uuidString.prefix(8))"
    }

    // MARK: - Instantiate a library node

    /// Materialize a built-in `NodeLibrary/<libraryID>/` node directly into the live graph — the same
    /// end-state `promoteStagedNode` reaches, but sourced from the library instead of an agent's staging
    /// folder and creating a NEW node rather than promoting a `.prompt` one. Copies the library's
    /// `Node.swift` into the project's per-node folder (`nodes/<uuid>/`, addressed by id like every other
    /// node), folds its contract into the store as a `.generated` node, applies any `inputDefaults`
    /// (e.g. a dropped file's `path`), then persists + reloads so the runtime compiles and renders it.
    /// This is the placement path the drag-and-drop media feature needs (and the seed of any future node
    /// palette). Returns the new node's id.
    @discardableResult
    func instantiateLibraryNode(libraryID: String, position: SZPoint,
                                inputDefaults: [String: SZPortValue] = [:],
                                origin: SZMutationOrigin = .user) throws -> SZNodeID {
        guard let projectURL = loadedProjectURL else { throw SZMCPError.message("no project loaded") }
        let fm = FileManager.default
        let src = Self.libraryURL.appending(path: libraryID)
        let sourceURL = src.appending(path: "Node.swift")
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw SZMCPError.message("library node '\(libraryID)' has no Node.swift")
        }
        var contract = try JSONDecoder().decode(
            SZNodeContract.self, from: Data(contentsOf: src.appending(path: "node-contract.json")))
        // Pre-select inputs (the dropped file's path) by pinning the port defaults; SZProjectIO.save
        // writes these into the copied node-contract.json, so they survive reload and show in the picker.
        for (port, value) in inputDefaults {
            if let pi = contract.inputs.firstIndex(where: { $0.name == port }) { contract.inputs[pi].def = value }
        }
        var node = SZNode(kind: .generated, title: contract.title, sfSymbol: contract.sfSymbol,
                          contract: contract, position: position,
                          buildStamp: .trusting(contract: contract, prompt: nil))   // a shipped build: trusted as-is
        let live = projectURL.appending(path: "nodes/\(node.id.uuidString)")
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        try fm.copyItem(at: sourceURL, to: live.appending(path: "Node.swift"))
        // A library node that ships a custom card copies it along. A contract that DECLARES a `card`
        // block lands with the card ON — it is the node's face (corner-pin's handles over the output,
        // a controller's learn strips); a Card.swift with no `card` block is an optional control
        // surface on an existing effect: the node keeps its familiar auto-preview and the card waits
        // in the context menu ("Show Custom Card").
        let cardURL = src.appending(path: "Card.swift")
        if fm.fileExists(atPath: cardURL.path) {
            try fm.copyItem(at: cardURL, to: SZProjectIO.cardSourceURL(projectURL: projectURL, nodeID: node.id))
            if contract.card != nil { node.body = SZNodeBody(mode: .custom, custom: SZCustomCardRef()) }
        }

        store.mutate { $0.graph.nodes.append(node) }
        noteNodeAdded(node.id, origin: origin)
        if let project = store.project { try SZProjectIO.save(project, to: projectURL) }
        // A node declaring a permission the app doesn't hold yet (microphone, camera) prompts BEFORE its
        // `setup()` runs — like project open and the run path do — otherwise the node boots unauthorized
        // and stays on its fallback (the mic's synthetic tone) until the next reload.
        if let runtime, contract.requiredPermissions.contains(where: { !runtime.permissions.isAuthorized($0) }) {
            Task { @MainActor [weak self] in
                await runtime.requestDeclaredPermissions(for: SZProject(name: "", graph: SZGraph(nodes: [node])))
                guard let self else { return }
                do { try self.finishInstantiate(libraryID, in: projectURL) } catch { self.status = "add failed: \(error)" }
            }
        } else {
            try finishInstantiate(libraryID, in: projectURL)
        }
        return node.id
    }

    private func finishInstantiate(_ libraryID: String, in projectURL: URL) throws {
        try runtime?.loadProject(at: projectURL)   // diffs node ids → compiles + loads the new module
        watchNodeSources(in: projectURL)           // the new node becomes hot-reloadable
        status = "added \(libraryID)"
    }

    /// Create library media nodes for a set of media files — the canvas drop (drag & drop) and the
    /// `ui_add_source_node` tool both land here. Each spawn instantiates its library node with `path`
    /// pre-set to the file; the LAST successfully created node becomes the viewport render endpoint so
    /// the freshly-added media shows immediately (live runtime push + persist, mirroring `toggleDisplay`).
    /// Returns the ids it created, in order — a spawn that failed to instantiate is simply absent, so a
    /// caller that must answer for what happened (the MCP tool) can compare against what it asked for.
    @discardableResult
    func createMediaNodes(_ spawns: [(libraryID: String, path: String, position: SZPoint)],
                          origin: SZMutationOrigin = .user) -> [SZNodeID] {
        var created: [SZNodeID] = []
        for spawn in spawns {
            do {
                created.append(try instantiateLibraryNode(
                    libraryID: spawn.libraryID, position: spawn.position,
                    inputDefaults: ["path": .string(spawn.path)], origin: origin))
            } catch {
                status = "drop failed: \(error)"
                print("[SZHost] media drop failed for \(spawn.libraryID): \(error)")
            }
        }
        if let lastID = created.last {
            let ref = SZPortRef(node: lastID, port: "output")
            if store.setRenderEndpoint(ref) {
                runtime?.setRenderEndpoint(ref)
                persistProject()
            }
        }
        return created
    }

    /// Persist the current graph (`project.json` + each node's `node-contract.json`) and reload the runtime
    /// — the structural-edit counterpart of `promoteStagedNode`'s tail. Removed nodes' folders orphan
    /// harmlessly (ignored on load). On failure the in-memory edit stands but disk/runtime lag (logged).
    func persistGraphEditAndReload(action: String) {
        guard let projectURL = loadedProjectURL, let project = store.project else { return }
        do {
            try SZProjectIO.save(project, to: projectURL)
        } catch {
            status = "\(action) — persist failed: \(error)"
            print("[SZHost] \(action) persist failed: \(error)")
            return
        }
        do {
            // Synchronous by design: callers (split/merge) rely on the graph being persisted AND reloaded
            // before they `startRun` the Director. This no longer beachballs — the runtime reload is now
            // incremental (`SZRuntime.loadGraph` reuses every already-loaded node, compiling only genuinely
            // new ones), and none of these callers add a renderable node here (wiring edits add none; split/
            // merge stage pieces as `.prompt`, which compile later in `promoteStagedNode`), so this does zero
            // compiles and returns in microseconds.
            try runtime?.loadProject(at: projectURL)
            watchNodeSources(in: projectURL)   // split/merge pieces become hot-reloadable
            status = action
        } catch {
            // The save above succeeded — say so, or a reload error reads as data loss.
            status = "\(action) — saved, but reload failed: \(error)"
            print("[SZHost] \(action) saved, but reload failed: \(error)")
        }
    }

    /// Delete a connection through the host — store removal + persist + runtime reload, so the edge is
    /// really gone (survives relaunch, render updates). THE connection-delete path for both the editor
    /// (`onDeleteConnection`) and `ui_disconnect`. The runtime has no incremental topology API
    /// (`reloadNode` is source-only), so this reloads like split/merge and promote do.
    @discardableResult
    func deleteConnection(id: SZConnectionID, origin: SZMutationOrigin = .user) -> Bool {
        if let denial = fenceDenial(nodes: connectionEndpoints(id), origin: origin) {
            status = denial
            return false
        }
        let edge = mutationEdge(id)
        guard store.disconnect(connection: id) else { return false }
        noteMutation("disconnected", [edge ?? "a connection"], origin: origin)
        persistGraphEditAndReload(action: "removed connection")
        return true
    }

    /// Create a connection through the host — store edit + persist + runtime reload, the create-side
    /// counterpart of `deleteConnection`. THE connection-create path for both the editor's wire drag
    /// (`onConnect`) and `ui_connect`. Wiring an occupied data input swaps the old edge out
    /// (`SZStore.connect` enforces single-incoming on data inputs).
    @discardableResult
    func addConnection(from: SZPortRef, to: SZPortRef, kind: SZConnectionKind,
                       origin: SZMutationOrigin = .user) -> SZConnectionID? {
        if let denial = fenceDenial(nodes: [from.node, to.node], origin: origin) {
            status = denial
            return nil
        }
        switch store.tryConnect(from: from, to: to, kind: kind) {
        case .connected(let id):
            noteMutation("connected", ["\(mutationLabel(from)) → \(mutationLabel(to))"], origin: origin)
            persistGraphEditAndReload(action: "connected")
            return id
        case .cycleRefused(let path):
            status = "not connected — would close a data cycle: \(cyclePathDescription(path))"
            return nil
        case .noProject:
            return nil
        }
    }

    /// A cycle path as node titles ("A → B → A") for refusal/status text.
    func cyclePathDescription(_ path: [SZNodeID]) -> String {
        path.map { store.project?.graph.node(id: $0)?.title ?? $0.uuidString }.joined(separator: " → ")
    }

    /// Re-route one end of an existing connection (the editor's picked-up wire dropped elsewhere —
    /// `end` names which side moves) — remove + re-create keeping the other end, then ONE persist +
    /// runtime reload. The store's swap rule applies at the destination, so landing on an occupied
    /// data input replaces its edge.
    @discardableResult
    func reconnectConnection(id: SZConnectionID, end: SZConnectionEnd, to newRef: SZPortRef,
                             origin: SZMutationOrigin = .user) -> Bool {
        if let denial = fenceDenial(nodes: connectionEndpoints(id) + [newRef.node], origin: origin) {
            status = denial
            return false
        }
        guard let old = store.project?.graph.connections.first(where: { $0.id == id }),
              store.disconnect(connection: id) else { return false }
        let newFrom = end == .from ? newRef : old.from, newTo = end == .to ? newRef : old.to
        let result = store.tryConnect(from: newFrom, to: newTo, kind: old.kind)
        guard case .connected = result else {
            // A refused re-add must never silently lose the wire: put the removed edge back.
            store.mutate { $0.graph.connections.append(old) }
            if case .cycleRefused(let path) = result {
                status = "not reconnected — would close a data cycle: \(cyclePathDescription(path))"
            }
            return false
        }
        noteMutation("moved endpoint", ["\(mutationLabel(old.from)) → \(mutationLabel(old.to)) now "
                                       + "\(mutationLabel(newFrom)) → \(mutationLabel(newTo))"], origin: origin)
        persistGraphEditAndReload(action: "reconnected")
        return true
    }

    /// Persist the current project (`project.json` + per-node contracts) to disk WITHOUT a runtime reload —
    /// the live-edit counterpart of `persistGraphEditAndReload`, for edits that already pushed their change
    /// into the runtime separately (toggle display, set input default, endpoint inference). No-op if nothing
    /// is loaded; best-effort (failure swallowed, as the call sites' `try?` already were).
    // NOTE: deliberately does NOT flush transcripts — a param save (slider commit, display toggle)
    // is not a transcript event, and fanning out N sidecar rewrites per tweak was pure waste.
    // Transcripts flush on their own moments: message completion, run end, quit.
    func persistProject() {
        guard let url = loadedProjectURL, let project = store.project else { return }
        try? SZProjectIO.save(project, to: url)
    }

    /// Set the active provider for new sessions (the composer cluster / `ui_set_provider` / the setup
    /// sheet's Confirm). Returns false for an unknown id, or while agents are busy (a switch resets
    /// sessions — cutting a live run/turn over to another CLI would strand it); left unchanged then.
    /// A real switch persists as the default (post-first-run; Confirm remains the first-run seed) and
    /// resets every agent session — a codex thread can't be resumed by claude. Transcripts stay: the
    /// next message per scope cold-starts with the transcript recap (`sendChat`), which is the
    /// context-rebuild story.
    @discardableResult
    func setActiveProvider(_ id: String) -> Bool {
        // A disabled id is refused like an unknown one — covers `ui_set_provider` and stale UI.
        guard SZProviderRegistry.shared.provider(id: id) != nil,
              !disabledProviderIDs.contains(id) else { return false }
        guard id != activeProviderID else { return true }   // no-op switch: nothing to reset or persist
        guard !isRunning, chatInFlight.isEmpty else { return false }
        activeProviderID = id
        if defaultProviderID != nil {   // post-first-run the cluster is the source of truth
            defaultProviderID = id
            persistAppState()
        }
        resetAgentSessions()
        trackProviderDefaultTelemetry()
        return true
    }

    /// Append a host-emitted line to the Director Agent transcript. During a run the Director tab
    /// carries operation-level narration (run begin / split-merge ops / complete) while each node's tab
    /// streams that agent's implementation detail. These are plain host strings, distinct from an LLM
    /// Director's own streamed narration.
    /// Returns the narration's message id so a caller can decorate it (the run-complete rollup).
    @discardableResult
    func narrateDirector(_ text: String) -> UUID {
        let id = store.appendChatMessage(SZChatMessage(role: .assistant, text: text), to: .director)
        // Narration is part of the durable narrative, but mid-run it can arrive per node — the
        // run-end flushAllTranscripts covers those; only standalone narrations flush eagerly.
        if !isRunning { flushTranscript(.director) }
        return id
    }

    /// Set a node input's default value — the editor's controls + `ui_set_input_default`. Persists to the
    /// store + disk (survives reload) AND pushes the value into the runtime live, so the render updates
    /// immediately (no recompile). `live: false` skips the disk write (used during a slider drag; commit
    /// on release).
    ///
    /// Clamp FIRST, then push: the runtime write below and the store write must carry the same value, or
    /// an out-of-range agent write would render live at 100 while the contract persists the clamped 5.
    /// Returns the applied value so a caller (the MCP tool) can echo the truth back.
    @discardableResult
    func setInputDefault(node: SZNodeID, port: String, value rawValue: SZPortValue, persist: Bool = true,
                         origin: SZMutationOrigin = .user) -> SZPortValue {
        if let denial = fenceDenial(nodes: [node], origin: origin) {
            status = denial
            return store.project?.graph.node(id: node)?.contract?.inputs
                .first { $0.name == port }?.def ?? rawValue   // echo the unchanged truth
        }
        let portModel = store.project?.graph.node(id: node)?.contract?.inputs.first { $0.name == port }
        let value = portModel?.clampedDefault(rawValue) ?? rawValue
        if let floats = value.floats { runtime?.setInputValue(node: node, port: port, floats: floats) }     // live (v3)
        if let string = value.string { runtime?.setInputString(node: node, port: port, string: string) }   // live (v4)
        guard store.setInputDefault(node: node, port: port, value: value) else { return value }
        // Journaled on the committed write only — a slider drag's live ticks are not decisions yet.
        if persist {
            noteMutation("set default", ["\(mutationTitle(node)).\(port) = \(Self.mutationValue(value))"],
                         origin: origin)
            persistProject()
        }
        return value
    }

    /// A prompt the user is mid-typing, held live but not yet persisted (the field commits only on blur).
    /// `startRun` flushes it before it claims the node, so a Build hit while the field is still focused
    /// runs against the typed text, not the stale model value (a later blur would drop it behind the fence).
    private var pendingPromptEdit: (id: SZNodeID, text: String)?

    /// Record the live field text (per keystroke). A plain assignment — no persist, no reload.
    func notePendingPromptEdit(id: SZNodeID, text: String) {
        pendingPromptEdit = (id, text)
    }

    /// Commit any pending prompt edit into the model — called at the top of `startRun`, before it claims
    /// the node, so the fence is clear. `updateNodeContent`'s no-op guard makes an unchanged flush free.
    func flushPendingPromptEdit() {
        guard let pending = pendingPromptEdit else { return }
        pendingPromptEdit = nil
        updateNodeContent(id: pending.id, prompt: pending.text, origin: .user)
    }

    /// Update a node's presentation / identity — the ONE funnel for the fenced content-update class,
    /// shared by the editor's inline prompt commit and `ui_update_node`. Before this existed the GUI
    /// path reached `store.updateNode` directly, so a prompt edit could land on a node another activity
    /// held: the lock arriving mid-edit flips `.disabled` on a focused field, which resigns first
    /// responder, and the resulting blur committed the stale text.
    ///
    /// A raised `.intentChanged` joins any run in flight, exactly as `ui_edit_ports` does for a raised
    /// port change — otherwise the Director re-briefs a node no one is scoped to pick up and it keeps
    /// running its old build. Returns the store's result so callers can echo the truth back; a refused
    /// mutation reports `found: false`, which reads as "nothing changed".
    @discardableResult
    func updateNodeContent(
        id: SZNodeID,
        title: String? = nil,
        sfSymbol: String? = nil,
        prompt: String? = nil,
        summary: String? = nil,
        permissions: [SZEntitlement]? = nil,
        origin: SZMutationOrigin = .user
    ) -> SZStore.SZNodeUpdateResult? {
        if let denial = fenceDenial(nodes: [id], origin: origin) {
            status = denial
            return nil          // REFUSED — distinct from "no such node", which is `.some(found: false)`
        }
        // A USER commit (a blur, or the pre-run flush) makes the model authoritative for this node — drop
        // any pending live text we held for it so a later run can't re-flush a stale keystroke. Only for
        // `.user`: an agent's `ui_update_node` (e.g. a reconcile retitle) must NOT discard what the user is
        // mid-typing on that same node.
        if origin == .user, pendingPromptEdit?.id == id { pendingPromptEdit = nil }
        // A blur fires on every click-away, keystrokes or not, and `found` only means the node exists — so
        // without this an empty blur would cost a synchronous whole-project save plus a `runtime.loadProject`
        // (engine lock, scheduler rebuild) and stamp "update node" over the status line. The GUI path did
        // neither before this funnel existed; a no-op must stay a no-op.
        guard let node = store.project?.graph.node(id: id) else {
            return SZStore.SZNodeUpdateResult(found: false, raisedRebuild: false)
        }
        let unchanged = (title == nil || title == node.title)
            && (sfSymbol == nil || sfSymbol == node.sfSymbol)
            && (prompt == nil || prompt == node.prompt)
            && (summary == nil || summary == node.contract?.summary)
            && (permissions == nil || permissions == node.contract?.permissions)
        if unchanged { return SZStore.SZNodeUpdateResult(found: true, raisedRebuild: false) }

        let result = store.updateNode(
            id: id, title: title, sfSymbol: sfSymbol, prompt: prompt,
            summary: summary, permissions: permissions)
        guard result.found else { return result }
        if let title, title != node.title { noteMutation("retitled", ["\(node.title) → \(title)"], origin: origin) }
        if let prompt, prompt != node.prompt { noteMutation("re-prompted", [node.title], origin: origin) }
        if (summary != nil && summary != node.contract?.summary)
            || (permissions != nil && permissions != node.contract?.permissions)
            || (sfSymbol != nil && sfSymbol != node.sfSymbol) {
            noteMutation("edited node", [node.title], origin: origin)
        }
        if result.raisedRebuild { noteRunCreatedWork([id]) }
        persistGraphEditAndReload(action: "update node")
        return result
    }

    /// Toggle a texture output as the viewport render endpoint — the node card's monitor icon +
    /// `ui_toggle_display`. Clicking the current endpoint clears it; clicking another re-points it.
    /// Updates the store + persists to disk + pushes the change into the runtime live (no reload). Returns
    /// the new endpoint (nil if cleared / the target wasn't a valid texture output).
    @discardableResult
    func toggleDisplay(node: SZNodeID, port: String, origin: SZMutationOrigin = .user) -> SZPortRef? {
        if let denial = fenceDenial(nodes: [node], origin: origin) {
            status = denial
            return store.project?.graph.renderEndpoint
        }
        let ref = SZPortRef(node: node, port: port)
        let newEndpoint: SZPortRef? = (store.project?.graph.renderEndpoint == ref) ? nil : ref
        guard store.setRenderEndpoint(newEndpoint) else { return store.project?.graph.renderEndpoint }
        noteMutation("toggled display", [newEndpoint.map { "→ \(mutationLabel($0))" } ?? "off (was \(mutationLabel(ref)))"],
                     origin: origin)
        runtime?.setRenderEndpoint(newEndpoint)
        persistProject()
        return newEndpoint
    }

    /// Throttle window for re-enumerating a node's dynamic options (so opening the camera dropdown picks up
    /// a just-connected device — e.g. a Continuity Camera — without a reload, and without per-frame cost).
    private static let optionsTTL: TimeInterval = 1.0
    private var optionsCache: [String: (options: [SZEnumOption], at: Date)] = [:]

    /// The effective enum choices for a port — one source for the editor dropdown + `debug_snapshot_state`,
    /// so the user and an agent see the same choices. A *static* enum's choices live in the contract; a
    /// *dynamic* enum (no contract `options`) is enumerated live from the node, throttled to ~once/sec.
    func effectiveOptions(node: SZNodeID, port: String) -> [SZEnumOption] {
        if let staticOptions = store.project?.graph.node(id: node)?.contract?.inputs.first(where: { $0.name == port })?.options,
           !staticOptions.isEmpty {
            return staticOptions
        }
        let key = "\(node.uuidString):\(port)"
        if let cached = optionsCache[key], Date().timeIntervalSince(cached.at) < Self.optionsTTL {
            return cached.options
        }
        let live = runtime?.enumerateOptions(node: node, port: port) ?? []
        optionsCache[key] = (live, Date())
        return live
    }

    func recordBuildErrors(_ log: String?) { lastBuildErrors = log }

    /// A node that has left the graph has no observable state. `purgeChatArtifacts` drops its entry on
    /// every removal path, but the writers below can land AFTER that — a coding-agent subprocess reporting
    /// success for a node deleted mid-run, a hot-reload Task resuming past the delete — and would
    /// resurrect it. The revived entry then haunts `debug_agent_state` and the reconcile loop's signal
    /// until the next project switch. Hold the invariant where the writes happen.
    private func isInGraph(_ id: SZNodeID) -> Bool { store.project?.graph.node(id: id) != nil }

    /// The node's OWN agent speaking (`agent_report_status`, and the debug affordance that stands in for
    /// one). Signed as such: run accounting lets an agent's `.error`/`.needsInput` outrank even a clean
    /// build, which is a judgement only the agent that did the work may make.
    func recordNodeStatus(node: SZNodeID, phase: SZNodeAgentPhase, message: String) {
        writeNodeStatus(node: node, phase: phase, message: message, byAgent: true)
    }

    /// The HOST's bad news about a node — a provider that died mid-turn, a work traversal that ended
    /// failed. Same red pill and copyable detail, but unsigned: it says the turn stopped, not that the
    /// build is bad, so a node that already promoted green still counts implemented at run end.
    func recordHostFailure(node: SZNodeID, message: String) {
        writeNodeStatus(node: node, phase: .error, message: message, byAgent: false)
    }

    /// A node the run counts implemented must not keep the red pill the host painted while its turn died
    /// (a spent budget, a dead CLI) — the build outlived the turn, and the transcript already carries the
    /// turn's own line. An agent's own report is left exactly as it stands: that one IS the verdict.
    func retireHostFailure(_ id: SZNodeID) {
        guard var state = nodeAgentState[id], !state.reportedByAgent,
              state.phase == .error || state.phase == .needsInput else { return }
        state.phase = .ok
        state.message = ""
        state.errorDetail = nil
        nodeAgentState[id] = state
    }

    private func writeNodeStatus(node: SZNodeID, phase: SZNodeAgentPhase, message: String, byAgent: Bool) {
        guard isInGraph(node) else { return }
        var state = nodeAgentState[node] ?? SZNodeAgentState()
        state.phase = phase
        state.message = message
        // Maintain the clickable error pill's detail too: an error keeps the message; else clear it.
        state.errorDetail = phase == .error ? (message.isEmpty ? phase.rawValue : message) : nil
        state.reportedByAgent = byAgent
        nodeAgentState[node] = state
        print("[SZHost] node \(node.uuidString) → \(phase.rawValue) \(message)")
    }

    /// A promote is strictly newer evidence than any prior report: drop the failure detail, the message and
    /// its authorship, and demote a stale `.error` / `.needsInput` pill to `.ok` (an in-flight chat flag is
    /// untouched). Without this a red pill outlives the green build that answered it.
    func clearTransientAgentStateAfterPromote(_ id: SZNodeID) {
        guard var state = nodeAgentState[id] else { return }
        state.errorDetail = nil
        state.message = ""
        state.reportedByAgent = false
        if state.phase == .error || state.phase == .needsInput { state.phase = .ok }
        nodeAgentState[id] = state
    }

    /// The run-end writer for a node that failed WITHOUT explaining itself: red pill, but a specific
    /// diagnostic already on the node (a port audit, a provider death) survives in `errorDetail` —
    /// `fallback` fills only what is empty there. The one-line `message`, by contrast, becomes the run's
    /// reason: what sits there is a stale progress note from an agent that then died mid-work ("wiring the
    /// mask polygon"), which reads as the blocker but isn't one. A phase the agent reported itself never
    /// reaches this writer, and keeps its words if it somehow does. Never `recordNodeStatus`, which would
    /// overwrite the detail with the generic line and feed it onward as the node's blocker.
    func recordRunFailure(node: SZNodeID, fallback: String) {
        guard isInGraph(node) else { return }
        var state = nodeAgentState[node] ?? SZNodeAgentState()
        let reported = state.phase == .error || state.phase == .needsInput
        state.phase = .error
        if !reported || state.message.isEmpty { state.message = fallback }
        state.errorDetail = state.errorDetail ?? fallback
        state.reportedByAgent = false   // the run wrote this pill, whoever wrote the phase before it
        nodeAgentState[node] = state
        print("[SZHost] node \(node.uuidString) → error (run end) \(state.message)")
    }

    /// Set/clear the mid-chat-turn flag on a node (its Coding Agent is editing it) — editor shows
    /// Coding + locks the card. Independent of the reported phase, so it never clobbers a status.
    func setNodeChatting(_ id: SZNodeID, _ chatting: Bool) {
        guard isInGraph(id) else { return }
        var state = nodeAgentState[id] ?? SZNodeAgentState()
        state.isChatting = chatting
        nodeAgentState[id] = state
    }

    /// The status lines for every node that has reported one — the reconcile loop's signal
    /// (`SZOrchestrationContext.nodeStatus`) and `debug_agent_state`'s `statuses` payload.
    var nodeStatusLines: [SZNodeID: String] {
        nodeAgentState.compactMapValues { $0.phase == .idle ? nil : $0.line }
    }

    /// Mark a node to force-fail its next coding dispatch (debug test affordance, `debug_fail_node_once`),
    /// reporting `blocker` as its needsInput message — so a realistic blocker can steer the reconcile turn.
    func forceFailNodeOnce(node: SZNodeID, blocker: String) { forcedFailNodes[node] = blocker }

    /// Record a Director-authored message for a node's Coding Agent during a run (the `ui_send_chat`
    /// during-run path). Two things happen: it's shown in the node's tab right away as a `.director`
    /// message (the node tab reads as a multi-party thread), and it's enqueued as a `.steer` envelope
    /// for the reconcile loop to drain (`takeDirectorMessages`) and fold into the node's retry prompt
    /// — the actual delivery. Two steers to one node are two envelopes, FIFO (the old single-slot
    /// dict silently overwrote the first).
    @discardableResult
    func recordDirectorMessage(node: SZNodeID, message: String) -> UUID {
        let id = recordSteer(to: .node(node), sender: SZChatScope.directorKey,
                             text: message, bubbleText: message)
        print("[SZHost] Director message for node \(node.uuidString.prefix(8)): \(message.prefix(80))")
        return id
    }

    /// Record a CODING agent's mid-run message TO the Director (`ui_send_chat scope=director` during a
    /// run) — previously a silent black hole: the bubble landed in the tab, the turn was rejected, and
    /// no LLM ever read the words. Now a `.steer` envelope the reconcile loop drains into the next
    /// Director turn's prompt (`takeDirectorInboxMessages`), with a `.director`-role bubble marking it
    /// as fleet-internal traffic in the Director tab (the wire carries no finer sender identity).
    @discardableResult
    func recordDirectorInboxMessage(_ message: String) -> UUID {
        recordSteer(to: .director, text: message, bubbleText: "(from a coding agent) \(message)")
    }

    /// The ONE steer-recording choreography both lanes share (Director→node and node→Director):
    /// enqueue the `.steer` envelope, land the `.director`-role bubble in the recipient's tab,
    /// mark it unread when off-screen, and flush (safe mid-stream: the in-flight reply is
    /// filtered out of flushes). Two wrappers, one ritual — the lanes cannot drift.
    @discardableResult
    private func recordSteer(to scope: SZChatScope, sender: String? = nil,
                             text: String, bubbleText: String) -> UUID {
        let envelope = SZMessageEnvelope(
            recipient: scope.key, sender: sender, intent: .steer,
            message: SZChatMessage(role: .director, text: text))
        mailbox.enqueue(envelope)
        store.appendChatMessage(SZChatMessage(role: .director, text: bubbleText), to: scope)

        flushTranscript(scope)
        return envelope.id
    }

    /// Open a node's sources in the user's default `.swift` editor (the card's file button): `Node.swift`,
    /// plus `Card.swift` when the node has one — both handed to the editor in one call, so they land as
    /// tabs of the same window. Saving either hot-reloads live (node via the source watcher, card via
    /// its mount's watcher).
    func openNodeSource(_ id: SZNodeID) {
        guard let url = loadedProjectURL else { return }
        let files = [SZProjectIO.nodeSourceURL(projectURL: url, nodeID: id),
                     SZProjectIO.cardSourceURL(projectURL: url, nodeID: id)]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let first = files.first else { return }
        guard let editor = NSWorkspace.shared.urlForApplication(toOpen: first) else {
            NSWorkspace.shared.open(first)
            return
        }
        NSWorkspace.shared.open(files, withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Hot-reload a node whose `Node.swift` changed on disk (the source watcher's change handler). Drives the
    /// node's pill: Reloading while it recompiles, Error (with a copyable diagnostic) on failure, else back to
    /// Ready. Incremental — only the edited node rebuilds (`reloadNode`); falls back to a full `loadProject`
    /// only when the node isn't currently in the live graph (e.g. a graph stuck failing wholesale).
    private func reloadEditedNode(id: SZNodeID) {
        guard let runtime, let url = loadedProjectURL else { return }
        // Edge case — an agent owns this node: a Director run (isRunning) or its Coding Agent mid-chat
        // (isChatting). The agent's own compile→promote path reloads it and drives its pill; reloading
        // here would clobber that. Leave it to the agent (its promote write fires the watcher while guarded).
        guard !isRunning, nodeAgentState[id]?.isChatting != true else { return }
        Task { @MainActor in
            // Re-check across every suspension: the watcher may have fired for a node that is deleted
            // before this Task starts, or during the yield below. Writing its pill then would resurrect
            // agent state for a node that is no longer in the graph.
            guard isInGraph(id) else { return }
            nodeAgentState[id] = SZNodeAgentState(phase: .reloading)   // pill → Reloading, prior error cleared
            await Task.yield()                          // let the pill paint before the (blocking) compile
            guard isInGraph(id) else { nodeAgentState[id] = nil; return }   // deleted mid-yield: take the pill back
            let source = SZProjectIO.nodeSourceURL(projectURL: url, nodeID: id)
            do {
                if runtime.isNodeLoaded(id) {
                    try runtime.reloadNode(id: id, source: source)   // incremental: just this node
                } else {
                    try runtime.loadProject(at: url)                 // fallback: node not yet in live graph
                }
                nodeAgentState[id] = nil                 // → derived .ready
                classifyRebuild(node: id)                // the hand edit may have opened or closed a port mismatch
                status = "hot-reloaded \(id.uuidString.prefix(8))"
                print("[SZHost] hot-reloaded node \(id.uuidString.prefix(8))")
            } catch {
                let log = "\(error)"
                recordBuildErrors(log)
                // pill → Error (concise first line); full swiftc log → the copyable popover.
                nodeAgentState[id] = SZNodeAgentState(
                    phase: .error, message: Self.firstErrorLine(in: log), errorDetail: log)
                status = "reload failed \(id.uuidString.prefix(8))"
                print("[SZHost] reload failed for \(id.uuidString.prefix(8)): \(log)")
            }
        }
    }

    /// The first swiftc `error:` line in a build log (the concise pill message); the full log goes to the
    /// copyable popover via `nodeErrors`. Falls back to a bounded prefix when no `error:` line is present.
    static func firstErrorLine(in log: String) -> String {
        let line = log.split(whereSeparator: \.isNewline).first { $0.contains(" error:") }
            .map(String.init) ?? String(log.prefix(160))
        return line.trimmingCharacters(in: .whitespaces)
    }

    #if DEBUG
    /// In-app frame-capture self-check (the readback behind `agent_view_frame`): after the camera warms up, read back a frame and confirm
    /// it's a plausible grayscale (R≈G≈B per pixel) and not uniform (the live camera produced content).
    /// Logs the result so a run with camera access confirms the end-to-end path; harmless without it.
    /// Debug-only, and log-only: it must never write `status`, which belongs to the user's own graph —
    /// it assumes the grayscale sample is loaded, so its verdict is meaningless for any other project.
    private func verifyGrayscale() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))   // camera warmup
            guard let frame = runtime?.captureFrame() else { return }
            var grayscale = true
            var values: [Int] = []
            for (x, y) in [(8, 8), (frame.width / 2, frame.height / 2), (frame.width - 8, frame.height - 8)] {
                guard let p = frame.pixel(x: x, y: y) else { continue }
                if abs(Int(p.r) - Int(p.g)) > 2 || abs(Int(p.g) - Int(p.b)) > 2 { grayscale = false }
                values.append(Int(p.r))
            }
            let varied = Set(values).count > 1
            print("[SZHost] frame self-check — grayscale: \(grayscale), live(non-uniform): \(varied), samples: \(values)")
        }
    }
    #endif
}
