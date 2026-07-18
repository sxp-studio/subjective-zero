// SPDX-License-Identifier: AGPL-3.0-only
// The host coordinator — composition root + router + run-lifecycle owner (ARCHITECTURE.md). It owns
// the SZRuntime, the SZStore, and the MCP server; loads the project from disk; watches node sources
// for hot reload; and vends the device + per-frame viewport render closure to the UI. It also owns the procedures
// that span the packages: staging→promote (typed-boundary contract pinning), run + per-node agent
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
    /// Per-frame viewport render, vended to SZUI's panel — called on the panel's display-link render
    /// thread (SZRuntime.drawLive(into:) is thread-safe; see its threading contract).
    private(set) var renderViewportFrame: ((CAMetalLayer) -> Void)?
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
    /// The nodes this run is implementing — its captured in-flight WORK SET. Snapshotted at `startRun`
    /// from the prompt nodes then present, and GROWN as the run's own tooling creates work (a Director
    /// split/merge or `ui_add_prompt_node` mid-run, via `noteRunCreatedWork`). A node the USER adds on
    /// the canvas mid-run shares `store.addPromptNode` but is deliberately NOT noted here, so it never
    /// joins the fleet's work: dispatch (`plans`), the editor lock/pill, and the `ui_connect` guard all
    /// consult this set. Single-writer (host/MCP writes; the UI only reads). Cleared at run end — a
    /// node chat runs with this empty. This is the seed of the behavior-tree's per-step in-flight set.
    internal(set) var runWorkSet: Set<SZNodeID> = []
    /// Messages the Director Agent authored for coding agents DURING a run (`ui_send_chat` to a node
    /// while `isRunning`), keyed by node id. Recorded — not delivered inline (deadlock-safe); the reconcile
    /// loop drains them (`takeDirectorMessages`) and folds each into the node's retry. Each is also shown
    /// immediately in the node's tab as a `.director` chat message (`recordDirectorMessage`); this map is
    /// only the delivery side-channel, so it stays modestly named — not a first-class type.
    internal(set) var pendingDirectorMessages: [SZNodeID: String] = [:]
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
    /// The host-pinned typed boundary contract for each dirty node in flight during a run. The agent owns
    /// its source + title/summary/symbol, but the host OWNS the typed I/O boundary — `promoteStagedNode`
    /// re-pins these `inputs`/`outputs`/`permissions` over the agent's authored contract, so a node can't
    /// lose a port's real type/ui/default/permission by the agent guessing `texture`. Snapshotted at
    /// `startRun` from every dirty node that already SHIPS a contract — split/merge pieces (their drafted
    /// boundary) AND a normal node re-implemented by its Coding Agent. A contract-less drawn prompt
    /// node is left unpinned (its agent authors the boundary). Cleared
    /// at run end (and eagerly at commit/rollback for graph ops).
    internal(set) var pinnedContracts: [SZNodeID: SZNodeContract] = [:]
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
    /// the host's pump delivers them as their resources free.
    let mailbox = SZMessageQueue()

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
    internal(set) var maximizedPanel: SZPanelKind?

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

    /// The window title: the project's name, suffixed while the project is still untitled. App
    /// name before anything is loaded (launch, Metal-less fallback).
    var projectWindowTitle: String {
        guard let project = store.project else { return "SubjectiveZero" }
        return isUntitledProject ? "\(project.name) — not saved" : project.name
    }

    // Chat panel UI state — host-owned so BOTH the SwiftUI panel and the `ui_*` MCP surface drive it
    // (the command bus; lets a closed-loop test select a tab the way a user clicks one).
    /// Panel shown? Now derived from the layout tree — chat visibility IS chat's presence in it.
    var chatVisible: Bool { panelLayout.contains(.chat) }
    internal(set) var activeChatScope: SZChatScope = .director   // the selected tab (Director / a node / the debug chat agent)
    internal(set) var tabOrder: [SZChatScope] = [.director]   // every open tab in user order (Director movable)
    /// A host-drafted composer message awaiting the panel (a context-menu suggestion click). The
    /// panel consumes it exactly once (`consumeComposerDraft`) so a re-render can't stomp edits.
    internal(set) var pendingComposerDraft: SZComposerDraftInjection?

    /// A run requested by `ui_run` DURING the Director Agent's own streaming chat turn — recorded
    /// (starting it mid-turn would race the same transcript; the `recordedForReconcile` pattern)
    /// and fired when that turn ends, with `directorAlreadyBriefed` so the run skips its decompose
    /// turn (the chat turn was it). The value is the run's instruction ("" = none given).
    var pendingDirectorRun: String?

    /// Scopes whose latest agent turn finished while the user was elsewhere — the tab's static
    /// unread dot, cleared when the tab is visited (`showChat`). During runs, node tabs finish at
    /// different times; this keeps "which ones have I not looked at" legible.
    internal(set) var unreadScopes: Set<String> = []

    /// The open tabs in user order — the Director plus every open node chat that still exists in the graph
    /// (deleted nodes drop out) plus the debug chat tab when open. The Director is always present even if
    /// it somehow fell out of the order.
    var chatTabs: [SZChatScope] {
        let present = Set(store.project?.graph.nodes.map(\.id) ?? [])
        var tabs = tabOrder.filter { $0 == .director || $0 == .debug || $0.nodeID.map(present.contains) == true }
        if !tabs.contains(.director) { tabs.insert(.director, at: 0) }
        return tabs
    }

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
    /// The active orchestration strategy — a pluggable `SZOrchestrating` selected by a debug
    /// setting (`SZ_ORCHESTRATOR` env at launch, swappable live via `debug_set_orchestrator` for
    /// closed-loop tests; TODO: replace with a Settings screen). Concrete SZAI; no SZCore seam.
    /// Default = `.agentic`: an LLM Director Agent declares each node's REAL typed contract + wiring,
    /// so a drawn node keeps its true I/O instead of being force-drafted to texture-in/out. The
    /// `.procedural` path stays the deterministic / offline / CI opt-in (set `SZ_ORCHESTRATOR=procedural`).
    private(set) var orchestratorStrategy: SZOrchestrationStrategy =
        ProcessInfo.processInfo.environment["SZ_ORCHESTRATOR"]
            .flatMap(SZOrchestrationStrategy.init(rawValue:)) ?? .agentic
    var orchestrator: any SZOrchestrating { orchestratorStrategy.make() }
    /// The in-flight `ui_run`, if any.
    internal(set) var runTask: Task<Void, Never>?
    /// In-flight interactive chat turns by scope key (`sendChat`'s tasks) — retained so the
    /// transcript's per-turn stop control can cancel ONE scope's turn (`cancelChatTurn`) without
    /// touching the others; a run's coding turns ride `runTask` instead.
    internal(set) var chatTurnTasks: [String: Task<Void, Never>] = [:]
    /// True for the whole duration of a Director run (drives the HUD Run↔Stop state; node locking is
    /// per-node — while running, only the unimplemented `.prompt` nodes lock, see `isLocked` in
    /// `SZNodeEditorPanel`). A VIEW over the ledger: the run's claim on `.run` IS the run state, so
    /// this can never drift from what the run actually holds. `cancelRun` releases eagerly (the
    /// zombie task's deferred release is idempotent), which is what flips this false at Stop.
    var isRunning: Bool { ledger.isHeld(.run) }
    /// The in-flight run's claim token — holds `.run`, the Director transcript, and the work set's
    /// node+transcript pairs. Set by `startRun`, threaded into the run's `deliver` calls, released
    /// (eagerly by `cancelRun`, deferredly by the run task) and cleared with the run.
    internal(set) var runClaim: SZClaimToken?

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
    static var libraryURL: URL {
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
        installStoreFenceBackstop()   // the fence's debug tripwire (SZHost+Fence.swift)
        // Geometry gate follows the restored pref BEFORE anything can render a card (project loads
        // below) — and before the Metal-unavailable early return, which must not strand the gate at
        // its compile-time default while the pref says otherwise.
        SZNodeLayout.previewsEnabled = livePreviews

        guard let runtime = SZRuntime() else {
            status = "Metal device unavailable"
            return
        }
        self.runtime = runtime
        self.renderViewportFrame = { layer in runtime.drawLive(into: layer) }
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
        verifyGrayscale()
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

        // 1. Validate first — a corrupt bundle must fail before the old project is touched.
        let project = try SZProjectIO.load(from: newURL)
        // 2. The only await: permissions (camera…) before the camera node's setup runs.
        try await runtime.requestDeclaredPermissions(at: newURL)
        // Re-check after the await: the busy guard above passed, but an event-driven delivery (the
        // mailbox pump fires on ledger releases) can start a turn inside that one suspension —
        // and everything below tears the project down under it.
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
        // project keeps rendering, its lock untouched).
        do {
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

    /// Note nodes CREATED by the run's own tooling (Director split/merge, `ui_add_prompt_node` mid-run)
    /// into its work set — the single place the "created via the run" rule lives. No-op outside a run
    /// (including a cancelled run's zombie tooling — `isRunning` reads the released claim), so callers
    /// invoke it unconditionally. The run's claim grows with the work set: the new nodes' resources
    /// are free by construction (fresh uuids), so the acquire cannot contend.
    func noteRunCreatedWork(_ ids: Set<SZNodeID>) {
        guard isRunning, let runClaim else { return }
        runWorkSet.formUnion(ids)
        var resources: Set<SZResourceID> = []
        for id in ids {
            resources.insert(.node(id))
            resources.insert(.transcript(.node(id)))
        }
        let claimed = ledger.tryAcquire(resources, as: runClaim)
        assert(claimed, "noteRunCreatedWork: fresh nodes unexpectedly contended — "
            + ledger.blockers(of: resources).map(\.label).joined(separator: ", "))
    }

    /// A split/merge is staged and awaiting its run's commit. Only one at a time (see `pendingGraphOp`).
    var hasStagedGraphOp: Bool { pendingGraphOp != nil }

    private func clearPerProjectState() {
        resetPreviewStreamForProjectSwitch()   // SZHost+NodePreviews — the one unwatch/teardown home
        nodeAgentState = [:]
        runWorkSet = []
        pendingDirectorMessages = [:]
        forcedFailNodes = [:]
        graphOpStatus = [:]
        hiddenPieces = []
        pendingGraphOp = nil
        pinnedContracts = [:]
        agentSessions = [:]
        restoredSessions = [:]
        inFlightAssistantIDs = [:]
        optionsCache = [:]
        lastBuildErrors = nil
        tabOrder = [.director]
        activeChatScope = .director
        // A freshly opened project starts playing from t=0 — reset the render clock and clear any pause
        // carried over from the previous project. (Deliberately here, not in `runtime.loadProject`, so
        // incremental live reloads — promote / graph edits — never yank the animation back to 0.)
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
        let bridge = SZHostBridge(host: self)
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
    /// copy `.staging/nodes/<id>/Node.swift` → live, fold the staged contract into the store
    /// (kind → generated), persist `project.json` + contracts, then reload the runtime so the new
    /// module renders. Called by `agent_compile_node` ONLY after `compileNodeSource` returns `.ok`,
    /// so a broken source can never reach here — live state stays intact on failure.
    func promoteStagedNode(id: SZNodeID) throws {
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

        // Fold the staged contract (if any) into the store and flip the node to generated.
        let stagedContract = (try? Data(contentsOf: staging.appending(path: "node-contract.json")))
            .flatMap { try? JSONDecoder().decode(SZNodeContract.self, from: $0) }
        store.mutate { project in
            guard let i = project.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
            project.graph.nodes[i].kind = .generated
            // The one place a rebuild is discharged: this source was just compiled against this contract, so
            // whatever surface change raised the flag is now honoured. `editPorts` raises it, promote clears it.
            project.graph.nodes[i].rebuildReason = nil
            if var contract = stagedContract {
                // The host OWNS the typed I/O boundary of any dirty node that shipped a contract at
                // dispatch — re-pin it over whatever the agent authored (the agent is told the boundary
                // but only the host guarantees it, so a port keeps its real type/ui/default). Permissions
                // pin ONLY when the host actually declared some (split/merge pieces): a contract-first
                // drawn node's drafted boundary carries none — the host can't infer them from flow — so
                // there the agent's authored permissions stand (e.g. the camera node keeps `.camera`).
                if let pinned = pinnedContracts[id] {
                    contract.inputs = pinned.inputs
                    contract.outputs = pinned.outputs
                    if !pinned.requiredPermissions.isEmpty { contract.permissions = pinned.permissions }
                }
                project.graph.nodes[i].contract = contract
                project.graph.nodes[i].title = contract.title
                project.graph.nodes[i].sfSymbol = contract.sfSymbol
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
        if sourceChanged, runtime?.isNodeLoaded(id) == true {
            try runtime?.reloadNode(id: id, source: liveSource)
        }
        try runtime?.loadProject(at: projectURL)
        watchNodeSources(in: projectURL)          // a newly-generated node becomes hot-reloadable
        nodeAgentState[id]?.errorDetail = nil     // a successful promote clears any prior failure detail
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
                                inputDefaults: [String: SZPortValue] = [:]) throws -> SZNodeID {
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
        let node = SZNode(kind: .generated, title: contract.title, sfSymbol: contract.sfSymbol,
                          contract: contract, position: position)
        let live = projectURL.appending(path: "nodes/\(node.id.uuidString)")
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        try fm.copyItem(at: sourceURL, to: live.appending(path: "Node.swift"))

        store.mutate { $0.graph.nodes.append(node) }
        if let project = store.project { try SZProjectIO.save(project, to: projectURL) }
        try runtime?.loadProject(at: projectURL)   // diffs node ids → compiles + loads the new module
        watchNodeSources(in: projectURL)           // the new node becomes hot-reloadable
        status = "added \(libraryID)"
        return node.id
    }

    /// Create library media nodes for a set of media files — the canvas drop (drag & drop) and the
    /// `ui_add_source_node` tool both land here. Each spawn instantiates its library node with `path`
    /// pre-set to the file; the LAST successfully created node becomes the viewport render endpoint so
    /// the freshly-added media shows immediately (live runtime push + persist, mirroring `toggleDisplay`).
    /// Returns the ids it created, in order — a spawn that failed to instantiate is simply absent, so a
    /// caller that must answer for what happened (the MCP tool) can compare against what it asked for.
    @discardableResult
    func createMediaNodes(_ spawns: [(libraryID: String, path: String, position: SZPoint)]) -> [SZNodeID] {
        var created: [SZNodeID] = []
        for spawn in spawns {
            do {
                created.append(try instantiateLibraryNode(
                    libraryID: spawn.libraryID, position: spawn.position,
                    inputDefaults: ["path": .string(spawn.path)]))
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
            status = "\(action) — persist failed: \(error)"
            print("[SZHost] \(action) persist failed: \(error)")
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
        guard store.disconnect(connection: id) else { return false }
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
        guard let id = store.connect(from: from, to: to, kind: kind) else { return nil }
        persistGraphEditAndReload(action: "connected")
        return id
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
              store.disconnect(connection: id),
              store.connect(from: end == .from ? newRef : old.from,
                            to: end == .to ? newRef : old.to, kind: old.kind) != nil else { return false }
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

    /// Select the orchestration strategy for the next run (`debug_set_orchestrator`). Stop-gap —
    /// TODO: replace with a Settings screen. The live render is unaffected until the next `ui_run`.
    /// Returns false for an unknown name (left unchanged).
    @discardableResult
    func setOrchestrator(_ name: String) -> Bool {
        guard let strategy = SZOrchestrationStrategy(rawValue: name) else { return false }
        orchestratorStrategy = strategy
        return true
    }

    /// Append a host-emitted line to the Director Agent transcript. During a run the Director tab
    /// carries operation-level narration (run begin / split-merge ops / complete) while each node's tab
    /// streams that agent's implementation detail. These are plain host strings, distinct from an LLM
    /// Director's own streamed narration.
    func narrateDirector(_ text: String) {
        store.appendChatMessage(SZChatMessage(role: .assistant, text: text), to: .director)
        // Narration is part of the durable narrative, but mid-run it can arrive per node — the
        // run-end flushAllTranscripts covers those; only standalone narrations flush eagerly.
        if !isRunning { flushTranscript(.director) }
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
        if persist { persistProject() }
        return value
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

    func recordNodeStatus(node: SZNodeID, phase: SZNodeAgentPhase, message: String) {
        guard isInGraph(node) else { return }
        var state = nodeAgentState[node] ?? SZNodeAgentState()
        state.phase = phase
        state.message = message
        // Maintain the clickable error pill's detail too: an error keeps the agent's message; else clear it.
        state.errorDetail = phase == .error ? (message.isEmpty ? phase.rawValue : message) : nil
        nodeAgentState[node] = state
        print("[SZHost] node \(node.uuidString) → \(phase.rawValue) \(message)")
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
    /// message (the node tab reads as a multi-party thread), and it's stashed for the reconcile loop to
    /// drain (`takeDirectorMessages`) and fold into the node's retry prompt — the actual delivery.
    func recordDirectorMessage(node: SZNodeID, message: String) {
        pendingDirectorMessages[node] = message
        store.appendChatMessage(SZChatMessage(role: .director, text: message), to: .node(node))
        if SZChatScope.node(node).key != activeChatScope.key {   // a Director note lands off-screen → unread dot
            unreadScopes.insert(SZChatScope.node(node).key)
        }
        flushTranscript(.node(node))   // safe mid-stream: the in-flight coding reply is filtered out
        print("[SZHost] Director message for node \(node.uuidString.prefix(8)): \(message.prefix(80))")
    }

    /// Open a node's `Node.swift` in the user's default `.swift` editor (the card's file button). Saving the
    /// file then hot-reloads the node live (`reloadEditedNode`, via the source watcher).
    func openNodeSource(_ id: SZNodeID) {
        guard let url = loadedProjectURL else { return }
        let source = SZProjectIO.nodeSourceURL(projectURL: url, nodeID: id)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        NSWorkspace.shared.open(source)
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
    private static func firstErrorLine(in log: String) -> String {
        let line = log.split(whereSeparator: \.isNewline).first { $0.contains(" error:") }
            .map(String.init) ?? String(log.prefix(160))
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// In-app frame-capture self-check (the readback behind `agent_view_frame`): after the camera warms up, read back a frame and confirm
    /// it's a plausible grayscale (R≈G≈B per pixel) and not uniform (the live camera produced content).
    /// Logs the result so a run with camera access confirms the end-to-end path; harmless without it.
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
            status = grayscale ? "grayscale camera live ✓" : "loaded (grant camera to see grayscale)"
        }
    }
}
