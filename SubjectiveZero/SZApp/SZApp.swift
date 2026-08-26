// SPDX-License-Identifier: AGPL-3.0-only
// SZApp — the app bundle and host (docs/ARCHITECTURE.md). Standard SwiftUI App lifecycle.
//
// The host (SZHost) owns the SZRuntime, loads the sample project from disk, and injects the runtime's
// device + per-frame render closure into SZUI's dumb SZViewportPanel — so the window shows the graph's
// live render, with GPU ownership living entirely in SZRuntime, not the view.
//
// The window is a freely rearrangeable panel layout: `SZPanelLayoutContainerView` renders the host's
// `panelLayout` split tree, and each panel (viewport / node editor / chat) wears a name-header drag
// handle, resizes on custom dividers, and closes/reopens without losing its spot. The default
// arrangement is viewport over editor, chat right. Chat's presence
// in the tree IS `chatVisible` (toggled by the editor HUD's message icon). The chat scopes to the
// editor's selected node (hoisted `selectedNodeID`), or the Director when nothing is selected.
import Foundation
import AppKit
import Sparkle
import SwiftUI
import SZAI
import SZCore
import SZUI

// Quit the app when its last window closes. SwiftUI on macOS keeps the
// process alive by default; this delegate restores the conventional single-window behavior.
// Also the quit-path transcript flush: the host is @State in the App struct, so it's wired onto the
// delegate at launch (the `.task` below) rather than constructed with it.
@MainActor
final class SZAppDelegate: NSObject, NSApplicationDelegate {
    weak var host: SZHost?
    /// A `.subz` handed to us by Finder at COLD launch, before the host has finished starting.
    /// Buffered here; `start` consumes it if it arrived early, and `appDidFinishStarting` drains it
    /// if it arrived mid-startup. Once the app is fully started, opens route immediately.
    private var pendingOpenProjectURL: URL?
    /// Set once `start()` has completed (runtime up, initial project loaded). Until then, a Finder
    /// open is buffered rather than run live — running `openProject` before the runtime exists would
    /// be silently refused, and racing the initial load is undefined.
    private var didFinishStarting = false

    // Pop-out panel windows close synchronously in the MAIN window's willClose (SZPopoutWindows),
    // so the main window is genuinely the last one and this fires exactly as in the single-window
    // days. (Pre-existing quirk, out of scope: the DEBUG "Tokens" window also counts as a window
    // and keeps the app alive if it's open when the main window closes.)
    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Finder double-click / drag-to-Dock / "Open With" of a project bundle. Before startup finishes:
    /// buffer it (opened by `start`/`appDidFinishStarting`). Already started: open it now, replacing
    /// the single window's project (an untitled current project stays reachable via Open Recent — no
    /// prompt, per the automatic-persistence policy; the quit prompt is the only rescue gate).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension == "subz" }) else { return }
        if didFinishStarting, let host { host.openProject(at: url) } else { pendingOpenProjectURL = url }
    }

    /// The buffered cold-launch open URL, consumed once (handed to `start`).
    func takePendingOpenURL() -> URL? {
        defer { pendingOpenProjectURL = nil }
        return pendingOpenProjectURL
    }

    /// Called after `host.start()` completes: mark started and open any `.subz` that Finder handed us
    /// DURING startup (arrived too late for `start`'s `openingIfLaunchedWithFile`).
    func appDidFinishStarting() {
        didFinishStarting = true
        if let url = takePendingOpenURL() { host?.openProject(at: url) }
        renameFileMenuToProject()
    }

    /// Retitle the native "File" menu to "Project" — the app's document IS a project (New Project /
    /// Open Recent projects / .subz), and the HUD gear mirrors this label. SwiftUI has no API to rename
    /// the standard File menu, so we retitle the NSMenuItem + its submenu directly. Deferred to the next
    /// runloop turn because SwiftUI populates `NSApp.mainMenu` just after this launch hook fires.
    private func renameFileMenuToProject() {
        DispatchQueue.main.async {
            guard let fileItem = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "File" })
            else { return }
            fileItem.title = "Project"
            fileItem.submenu?.title = "Project"
        }
    }

    /// Back to the front: a file a node points at can be moved, renamed or thrown away in the Finder
    /// while we are in the background, and nothing else would notice. One stat per file port.
    func applicationDidBecomeActive(_ notification: Notification) {
        host?.auditInputFiles()
    }

    /// Quit gate: rescue an untitled project before its temp files are cleaned up (saved projects
    /// autosave, so they quit silently). Offered DURING a run too — Save As no longer needs the
    /// graph quiet, and quitting mid-run was the one way to lose an untitled project outright.
    /// Skipped for `debug_quit` (`quitSkipsUntitledRescue`): a drive has no human to answer the
    /// prompt, and parking terminate on it wedges the automated session.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let host, host.isUntitledProject,
              !host.quitSkipsUntitledRescue else { return .terminateNow }
        Task { @MainActor in
            let proceed = await host.confirmSaveOrDiscardIfUnsaved(actionName: "quitting")
            sender.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }

    /// Last-chance flush — the quit-path counterpart of the per-message/run-end flush points. A
    /// SIGKILL/crash skips this and loses only messages since the last completion flush (bounded).
    func applicationWillTerminate(_ notification: Notification) {
        host?.flushEverything()   // the same set ⌘S writes: queues redeliver, a live run restores as interrupted
        // Pop-out frame moves persist behind a debounce — a quit inside that window must not
        // restore a stale frame next launch (the in-memory record is already authoritative).
        host?.popoutFramePersistDebounce?.cancel()
        host?.persistAppState()
        host?.releaseProjectLock()
    }

    /// Retains the window-close guard (NSWindow.delegate is weak). Re-asserted from the configurator's
    /// updateNSView, so it survives both the first-mount nil-window race and SwiftUI later reasserting
    /// its own window delegate.
    private var windowCloseGuard: SZWindowCloseGuard?

    /// Intercept the window's close button / ⌘W so the untitled-save prompt runs BEFORE the window
    /// disappears (single-window app: closing the window terminates via
    /// `applicationShouldTerminateAfterLastWindowClosed`, and prompting after the window is gone
    /// stranded the app window-less). Self-healing: (re)installs whenever our guard isn't the
    /// window's current delegate — otherwise a dropped guard would silently skip the rescue prompt
    /// and lose the untitled project. Forwards all other delegate calls to SwiftUI's.
    func installWindowCloseGuard(on window: NSWindow, host: SZHost) {
        if let existing = windowCloseGuard, window.delegate === existing { return }
        let guardObj = SZWindowCloseGuard(host: host, forwardingTo: window.delegate)
        windowCloseGuard = guardObj
        window.delegate = guardObj
    }
}

/// The window-close save gate. `windowShouldClose` prompts (untitled projects only) before the
/// window closes; on proceed it closes the window programmatically (which then terminates the app),
/// on cancel it keeps the window. Everything else is forwarded to SwiftUI's own window delegate so
/// window behaviors (title, fullscreen, restoration) keep working. AppKit only ever touches this on
/// the main thread; the `nonisolated(unsafe)` weak refs let the ObjC-forwarding overrides stay
/// nonisolated while `windowShouldClose` hops to the main actor for the host calls.
final class SZWindowCloseGuard: NSObject, NSWindowDelegate {
    nonisolated(unsafe) private weak var host: SZHost?
    nonisolated(unsafe) private weak var forwardee: NSWindowDelegate?

    init(host: SZHost, forwardingTo forwardee: NSWindowDelegate?) {
        self.host = host
        self.forwardee = forwardee
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            guard let host, host.isUntitledProject else { return true }
            // Defer the close: prompt, and only close (→ terminate) if the user didn't cancel. After
            // a Save/Discard the project is no longer untitled, so a re-entrant close won't re-prompt.
            Task { @MainActor in
                if await host.confirmSaveOrDiscardIfUnsaved(actionName: "closing") { sender.close() }
            }
            return false
        }
    }

    // Transparent forwarding of every other NSWindowDelegate method to SwiftUI's delegate.
    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (forwardee?.responds(to: aSelector) ?? false)
    }
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        (forwardee?.responds(to: aSelector) ?? false) ? forwardee : super.forwardingTarget(for: aSelector)
    }
}

// Window chrome for the panel layout: no titlebar block (`.hiddenTitleBar` on the scene), just a
// slim strip above the tiles where the traffic lights live — the titlebar's safe area, kept on
// purpose as the native window-drag zone (tiles flush to the window top would put the panel-drag
// headers where users grab to move the window). SwiftUI has no direct handle on these NSWindow
// knobs, hence the zero-size representable fishing the window out of the hierarchy. NOTE:
// deliberately NOT `isMovableByWindowBackground` — that made every panel HEADER a window-move
// region (the window drag pre-empted the SwiftUI drag gesture and broke panel drag & drop). Extra
// window dragging also lives in the container's backdrop (any gap/margin).
private struct SZWindowChromeConfigurator: NSViewRepresentable {
    let host: SZHost
    let appDelegate: SZAppDelegate

    /// The compact frame the window snaps to while the welcome/home surface is up — the split
    /// launcher is designed at roughly this size (the full workspace size leaves it marooned in
    /// empty space). Restored to the user's workspace frame the moment a project opens.
    private static let welcomeWindowSize = NSSize(width: 940, height: 600)

    /// Persists across SwiftUI updates: the workspace frame to restore, and the last welcome state so
    /// we resize only on the edge (not every re-render, which would fight a manual resize).
    final class Coordinator {
        var savedWorkspaceFrame: NSRect?
        var lastWelcome: Bool?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        configure(view, context.coordinator)
        return view
    }

    // Re-run on every SwiftUI update: chases down the window if it wasn't attached at first mount,
    // and re-asserts the close guard if SwiftUI reassigned the window delegate since (both would
    // otherwise drop the untitled-save prompt). installWindowCloseGuard is idempotent.
    func updateNSView(_ nsView: NSView, context: Context) { configure(nsView, context.coordinator) }

    private func configure(_ view: NSView, _ coord: Coordinator) {
        let host = host
        let appDelegate = appDelegate
        let welcome = host.welcomePresented
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(white: 0.04, alpha: 1)
            appDelegate.installWindowCloseGuard(on: window, host: host)
            // The pop-out manager learns the MAIN window here (this configurator only ever lives
            // in it) — the close-children observer and dock-drag hit-testing hang off it. The
            // welcome edge doubles as the pop-outs' hide/show + relaunch-restore signal.
            host.popoutManager.mainWindow = window
            host.popoutManager.setWorkspaceActive(!welcome)

            // Resize on the welcome↔workspace edge only: shrink to the compact launcher frame while
            // welcome is up, restore the saved workspace frame when a project takes over.
            guard coord.lastWelcome != welcome else { return }
            coord.lastWelcome = welcome
            if welcome {
                if coord.savedWorkspaceFrame == nil { coord.savedWorkspaceFrame = window.frame }
                let size = Self.welcomeWindowSize
                let origin = NSPoint(x: window.frame.midX - size.width / 2,
                                     y: window.frame.midY - size.height / 2)
                // Snap, don't animate: an animated shrink re-lays out the welcome content mid-flight,
                // which made the New Project button + its pulse overlay appear to slide in on launch.
                window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
            } else if let saved = coord.savedWorkspaceFrame {
                window.setFrame(saved, display: true, animate: true)
                coord.savedWorkspaceFrame = nil
            }
        }
    }
}

// The document name, drawn in the titlebar's safe-area strip (`.hiddenTitleBar` hides the native
// text; the strip itself is kept as the window-drag zone — see SZWindowChromeConfigurator). The
// GeometryReader reads the strip's height off the content's top safe-area inset and offsets the
// label up into it; non-hit-testing so window drag keeps working underneath.
private struct SZWindowTitleOverlay: View {
    let title: String

    var body: some View {
        GeometryReader { geo in
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 80)   // clear of the traffic lights when the window narrows
                .frame(width: geo.size.width, height: geo.safeAreaInsets.top)
                .offset(y: -geo.safeAreaInsets.top)
        }
        .allowsHitTesting(false)
    }
}

// Entry point is SZMain (SZMain.swift) — it services `--verify-agent-providers` before this
// scene (and its Metal/runtime spin-up) ever exists.
struct SZApp: App {
    @NSApplicationDelegateAdaptor(SZAppDelegate.self) private var appDelegate
    @State private var host = SZHost()
    @State private var selectedNodeID: SZNodeID?      // canvas selection (edit/move/wire) — NOT chat scope
    /// The AI Settings section last viewed — reopening the sheet returns there (per launch,
    /// like the edit selection above; not persisted).
    @State private var setupSection: SZProviderSetupSection = .providers
    /// A Routing card's View Graph ask: land the Agent Graph panel on this agent's plan.
    /// Consumed by the panel, the same handshake as the host's run-focus request.
    @State private var agentGraphPlanFocus: String?
    /// Opens the "Tokens" scene (the Profiler's token-inspection window).
    @Environment(\.openWindow) private var openWindow
    // Sparkle (SZUpdater.swift). Explicit init: constructing the controller in a default-value
    // expression would run outside the struct's MainActor isolation under Swift 6.
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if host.welcomePresented {
                    // The launch/home surface — shown INSTEAD of the workspace (not over it), so a cold
                    // launch opens no project until the user picks one (nothing touches the camera).
                    welcomeView
                } else if host.runtime != nil {
                    SZPanelLayoutContainerView(
                        layout: host.panelLayout,
                        // Hidden titlebar: the container lays out below the titlebar's safe area, so
                        // the traffic lights live in a slim strip ABOVE the tiles — which is also the
                        // native window-drag zone, deliberately kept (tiles flush to the window top
                        // would put the panel-drag headers where users grab to move the window). No
                        // windowControlsZone: nothing overlaps the tiles, titles stay hard-left.
                        topInset: 0,
                        autoHideHeaders: host.autoHidePanelHeaders,
                        viewportRoundedCorners: host.viewportRoundedCorners,
                        maximizedPanel: host.maximizedPanel,
                        externalDockPreview: host.popoutDockCandidate,
                        title: { host.panelTitle($0) },
                        canClone: { host.canClonePanel($0) },
                        canPopOut: { host.canPopOutPanel($0) },
                        onDividerFractionChange: { host.setPanelDividerFraction($1, at: $0) },
                        onDividerDragEnd: { host.commitPanelDividerFraction($1, at: $0) },
                        onMovePanel: { host.movePanel($0, onto: $1, zone: $2) },
                        onPinPanel: { host.pinPanel($0, to: $1) },
                        onClosePanel: { host.closePanel($0) },
                        onToggleMaximize: { host.toggleMaximizePanel($0) },
                        onClonePanel: { host.clonePanel($0) },
                        onPopOutPanel: { host.popOutPanel($0) },
                        onTearOutPanel: { host.tearOutPanel($0) }) { id in
                            panelContent(id)
                        }
                } else {
                    Color.black.overlay(Text(host.status).foregroundStyle(.white))
                }
            }
            .frame(minWidth: 640, minHeight: 480)
            .background(SZWindowChromeConfigurator(host: host, appDelegate: appDelegate))
            // The document name, drawn where the hidden titlebar's text would be (the safe-area
            // strip). navigationTitle still names the window for Mission Control / the Dock.
            .navigationTitle(host.projectWindowTitle)
            // The home screen carries its own identity (the big wordmark), so drop the titlebar-strip
            // document title there — it reads as redundant chrome over the launcher.
            .overlay(alignment: .top) {
                if !host.welcomePresented { SZWindowTitleOverlay(title: host.projectWindowTitle) }
            }
            // The AI Settings sheet — auto-presents on a first-run launch (SZHost+ProviderHealth,
            // landing on Providers), reopened via ⌘, or the composer's ⋯ menu. A set-false
            // (Esc/swipe) is a Skip: dismiss without confirming, so first-run simply re-presents
            // next launch.
            .sheet(isPresented: Binding(get: { host.providerSetupPresented },
                                        set: { if !$0 { host.skipProviderSetup() } })) {
                SZProviderSetupSheet(cards: host.providerSetupCards,
                                     selectedID: host.selectedSetupProviderID,
                                     activeID: host.activeProviderID,
                                     routing: routingSettingsView,
                                     initialSection: setupSection,
                                     onSelect: { host.selectSetupProvider($0) },
                                     onRefresh: { Task { await host.refreshProviderHealthOnce() } },
                                     onTest: { host.runProviderProbe($0) },
                                     onSetModel: { host.pickSetupModel($1, for: $0) },
                                     onOpenLogin: { host.openProviderLoginTerminal($0) },
                                     onUseFallback: { host.adoptFallbackProvider(insteadOf: $0) },
                                     onSetEnabled: { host.setProviderEnabled($0, $1) },
                                     onConfirm: { host.confirmDefaultProvider() },
                                     onSkip: { host.skipProviderSetup() },
                                     onOpenSetupGuide: { host.openProviderSetupGuide() },
                                     onJoinDiscord: { host.joinDiscord() },
                                     onSectionChange: { setupSection = $0 },
                                     // First run = the default provider is still unconfirmed;
                                     // afterwards the Providers pane closes with a plain Done.
                                     isFirstRun: host.defaultProviderID == nil)
            }
            .task {
                appDelegate.host = host   // wire the quit-path flush + Finder-open (see SZAppDelegate)
                // The pop-out windows render the same panel content as the tiles. AnyView-erased
                // like the HUD gear menu; safe to build outside a scene today because the only
                // allowed kind (viewport) touches no view-local @State — revisit this capture if
                // more kinds join popoutAllowedKinds.
                host.popoutManager.makePanelContent = { id in AnyView(panelContent(id)) }
                await host.start(openingIfLaunchedWithFile: appDelegate.takePendingOpenURL())
                appDelegate.appDidFinishStarting()   // open a .subz that arrived mid-startup
            }
        }
        .defaultSize(width: 1440, height: 860)
        .windowStyle(.hiddenTitleBar)
        // View → per-panel toggles (⌘⌥1/2/3): the reopen affordance once a panel's header ✕ closed
        // it (chat also reopens via the HUD message icon; the others have no other way back).
        .commands {
            // App menu, under About — Sparkle's conventional slot for Check for Updates….
            CommandGroup(after: .appInfo) {
                SZCheckForUpdatesView(updater: updaterController.updater)
            }
            // File — the document lifecycle (roadmap Task 1). Replacing .newItem also drops
            // "New Window" — intended (single-window app). Persistence is automatic, so only an
            // UNTITLED project gets a ⌘S item, and it opens the Save As panel. New / Open / Open
            // Recent sit out a run or in-flight chat; Save As does not, because it never swaps the
            // project (the methods are guarded too — MCP can race a click).
            CommandGroup(replacing: .newItem) {
                Button("New Project") { host.newProject() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(host.isBusyForProjectSwitch)
                Button("Open…") { host.openProjectViaPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(host.isBusyForProjectSwitch)
                // The busy disable sits on the ITEMS: .disabled on the Menu itself doesn't render
                // on macOS (verified live 2026-07-04 — siblings grayed, the submenu didn't).
                Menu("Open Recent") {
                    ForEach(host.existingRecentProjectPaths, id: \.self) { path in
                        Button(URL(filePath: path).deletingPathExtension().lastPathComponent) {
                            host.openProject(at: URL(filePath: path))
                        }
                        .disabled(host.isBusyForProjectSwitch)
                    }
                    Divider()
                    Button("Clear Menu") { host.clearRecentProjects() }
                        .disabled(host.recentProjectPaths.isEmpty || host.isBusyForProjectSwitch)
                }
                Divider()
                // No Save item for a PLACED project: it is written as it changes, so an item saying
                // "Save" would imply dirty state that doesn't exist. An untitled one has nowhere to
                // save yet, and ⌘S is the reflex for exactly that, so it keeps the shortcut and opens
                // the same panel Save As does.
                if host.isUntitledProject {
                    Button("Save…") { host.saveProjectAs() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(host.isOpeningProject || !host.hasSavableProject)
                }
                Button("Save As…") { host.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(host.isOpeningProject || !host.hasSavableProject)
            }
            // ⌘, — the app's only settings surface today; graduates into a real Settings window
            // once more prefs earn one (docs/UI.md).
            CommandGroup(replacing: .appSettings) {
                Button("AI Settings…") { host.presentProviderSetup() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(Array(SZPanelKind.availableCases.enumerated()), id: \.element) { index, kind in
                    Toggle(kind.displayName, isOn: panelVisibilityBinding(kind))
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                }
                Divider()
                // The viewport's window affordances (menu mirrors of the header buttons — clones
                // beyond the primary are addressed by their own headers, not menu items).
                Button("Clone Viewport") { host.clonePanel(.viewport) }
                    .disabled(!host.canClonePanel(.viewport))
                Button(host.isPoppedOut(.viewport) ? "Dock Viewport" : "Pop Out Viewport") {
                    if host.isPoppedOut(.viewport) {
                        host.popoutManager.dockToRememberedSpot(id: .viewport)
                    } else {
                        host.popOutPanel(.viewport)
                    }
                }
                .disabled(!host.isPoppedOut(.viewport) && !host.canPopOutPanel(.viewport))
                Divider()
                // The display prefs, grouped so the menu stays panels-first as panels accrue
                // (the Profiler pushed it past comfortable).
                Menu("Display") {
                    Toggle("Auto-Hide Panel Headers", isOn: Binding(get: { host.autoHidePanelHeaders },
                                                                    set: { host.setAutoHidePanelHeaders($0) }))
                    // Appearance — squares just the viewport tile.
                    Toggle("Rounded Viewport Corners", isOn: Binding(get: { host.viewportRoundedCorners },
                                                                     set: { host.setViewportRoundedCorners($0) }))
                    // Chat display — each coding agent's own turns while it builds.
                    Toggle("Show Agent Activity", isOn: Binding(get: { host.showAgentActivity },
                                                                set: { host.setShowAgentActivity($0) }))
                }
                Divider()
            }
            // Graph — the node-graph view/arrange commands. Framing (Center View /
            // Zoom to Fit) leaves the model untouched; Tidy Graph reflows node positions. The three
            // graph-dependent items gate on a non-empty graph (Snap to Grid is a standing pref).
            CommandMenu("Graph") {
                Button("Center View") { host.centerView() }
                    .disabled(host.store.project?.graph.nodes.isEmpty ?? true)
                Button("Zoom to Fit") { host.zoomToFit() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(host.store.project?.graph.nodes.isEmpty ?? true)
                Divider()
                Button("Tidy Graph") { host.tidyGraph() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(host.store.project?.graph.nodes.isEmpty ?? true)
                Divider()
                // Stopping ONE build is done from its lane in the chat strip; this is the
                // everything-at-once escape hatch, reachable with the panel closed.
                Button("Stop All Builds") { host.cancelRun() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!host.isRunning)
                Divider()
                Toggle("Snap to Grid", isOn: Binding(get: { host.snapToGrid },
                                                     set: { host.setSnapToGrid($0) }))
                Toggle("Grid Cursor Trail", isOn: Binding(get: { host.gridCursorTrail },
                                                          set: { host.setGridCursorTrail($0) }))
                Toggle("Mini Map", isOn: Binding(get: { host.showMiniMap },
                                                 set: { host.setShowMiniMap($0) }))
                Toggle("Live Previews", isOn: Binding(get: { host.livePreviews },
                                                      set: { host.setLivePreviews($0) }))
            }
            // Help — the community/support links (Website / GitHub / Discord / Send Feedback). Replacing
            // .help drops the default "SubjectiveZero Help" item (there's no help book, so it only errored).
            // Same `helpLinks` as the HUD gear's Help submenu.
            CommandGroup(replacing: .help) {
                helpLinks
            }
        }
        #if DEBUG
        // Debug-only entry to the debug chat agent — a provider-backed scratch chat tab (no graph/Director
        // role, no MCP tools) for exercising the composer, notably file attachments, against a real agent.
        // (The editor prefs that used to live here — Snap to Grid, Auto-Hide Panel Headers — graduated to
        // the Graph and View menus respectively; they ship in Release.)
        .commands {
            CommandMenu("Debug") {
                // Per-turn phase breakdown under chat replies (collection rides the host's trace
                // flag; this only shows/hides what was recorded).
                Toggle("Show Turn Breakdown", isOn: Binding(get: { host.showTurnBreakdown },
                                                            set: { host.setShowTurnBreakdown($0) }))
                // Same binding as View ▸ Debug (⌘⌥4) — listed here too so the trace browser is
                // discoverable next to its sibling debug affordances.
                Toggle("Show Profiler", isOn: panelVisibilityBinding(.profiler))
            }
        }
        #endif
        #if DEBUG
        // The Profiler's token-report viewer (the thinking rows' ↑↓ icon): an in-app utility
        // window holding the per-turn token text — selectable, paste-anywhere, and guaranteed
        // visible, unlike handing a temp file to whatever app owns ".txt". Opens via
        // `openWindow(value: <report text>)`; dormant otherwise.
        WindowGroup("Tokens", for: String.self) { $report in
            ScrollView {
                Text($report.wrappedValue ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color(red: 0.09, green: 0.09, blue: 0.10))
            .frame(minWidth: 560, minHeight: 200)
        }
        .defaultSize(width: 660, height: 280)
        #endif
    }

    /// View-menu checkmark ↔ the panel's visibility: a tile in the layout tree OR a popped-out
    /// window both count as "shown" (toggling off a popped-out panel closes its window; toggling
    /// a popped-out panel "on" is showPanel's dock-back). The menu enumerates KINDS and binds to
    /// each kind's primary instance — clones have no menu entry (their affordances are the header
    /// buttons). Closing the last panel is refused by the model, so the checkmark snaps back.
    private func panelVisibilityBinding(_ kind: SZPanelKind) -> Binding<Bool> {
        let id = SZPanelID(kind)
        return Binding(get: { host.panelLayout.contains(id) || host.isPoppedOut(id) },
                       set: { $0 ? host.showPanel(id) : host.closePanel(id) })
    }

    /// The AI Settings Routing pane, wired to the host mapping (SZHost+RoutingSettings).
    /// No presentation state: the selected row IS the active profile, so the host's
    /// `activeRoutingProfileName` is the whole story — the gearMenu pattern, typed.
    private var routingSettingsView: SZRoutingSettingsView {
        // A launch pin owns the session: the pane renders the PINNED profile, locked, not
        // whatever app-state happens to persist underneath it.
        let selection = host.routingEnvPinnedProfileName ?? host.activeRoutingProfileName
        return SZRoutingSettingsView(
            profiles: host.routingProfileRows,
            selectedProfileName: selection,
            agents: host.routingAgentCards(editedName: selection),
            activeProviderSummary: host.routingAppDefaultDisplay,
            envPinnedProfileName: host.routingEnvPinnedProfileName,
            envKilled: host.routingEnvKilled,
            onSetRoutingEnabled: { host.setRoutingEnabled($0) },
            onSelectProfile: { _ = host.setActiveRoutingProfile($0) },
            onCreateProfile: { _ = host.createRoutingProfile() },
            onRenameProfile: { old, new in _ = host.renameRoutingProfile(from: old, to: new) },
            onDuplicateProfile: { name in
                if let copy = host.duplicateRoutingProfile(named: name) {
                    _ = host.setActiveRoutingProfile(copy)   // identical table: no move
                }
            },
            onDeleteProfile: { host.deleteRoutingProfile(named: $0) },
            onAssignEnvelope: {
                host.assignRoutingEnvelope(profileNamed: selection, position: $0,
                                           providerID: $1, modelID: $2)
            },
            onSetPositionEffort: {
                host.setRoutingPositionEffort(profileNamed: selection, position: $0, effort: $1)
            },
            onSetPositionFastMode: {
                host.setRoutingPositionFastMode(profileNamed: selection, position: $0, enabled: $1)
            },
            onShowAgentGraph: { agentID in
                // Dismiss via the host path, NOT the sheet binding — its set-false is a Skip
                // (skipProviderSetup), and a navigation must not read as one.
                host.dismissProviderSetupForNavigation()
                agentGraphPlanFocus = agentID
                if !host.panelLayout.contains(.agentGraph) { host.showPanel(.agentGraph) }
            },
            onApplyRecommended: { agentID, replace in
                host.applyRecommendedRouting(agent: agentID, profileNamed: selection,
                                             replacingExisting: replace)
            })
    }

    /// The HUD gear menu's items — the canvas-side mirror of the macOS menu bar. Mirrors the `.commands`
    /// wiring verbatim (same host methods + bindings) so the two stay in lockstep, then adds AI Settings…
    /// and the community links. Keyboard shortcuts are deliberately omitted here — the menu bar owns the
    /// canonical ⌘-shortcuts; duplicating them on these items would double-register the key equivalents.
    @ViewBuilder
    private var gearMenuContent: some View {
        // Return to the home/welcome screen from the editor (also in the Help menu). The project stays
        // loaded behind it — Esc / continue drops straight back into the workspace.
        Button { host.presentWelcome() } label: { Label("Welcome Screen", systemImage: "house") }
        Divider()
        Menu("Project") {
            Button("New Project") { host.newProject() }
                .disabled(host.isBusyForProjectSwitch)
            Button("Open…") { host.openProjectViaPanel() }
                .disabled(host.isBusyForProjectSwitch)
            Menu("Open Recent") {
                ForEach(host.existingRecentProjectPaths, id: \.self) { path in
                    Button(URL(filePath: path).deletingPathExtension().lastPathComponent) {
                        host.openProject(at: URL(filePath: path))
                    }
                    .disabled(host.isBusyForProjectSwitch)
                }
                Divider()
                Button("Clear Menu") { host.clearRecentProjects() }
                    .disabled(host.recentProjectPaths.isEmpty || host.isBusyForProjectSwitch)
            }
            Divider()
            if host.isUntitledProject {
                Button("Save…") { host.saveProjectAs() }
                    .disabled(host.isOpeningProject || !host.hasSavableProject)
            }
            Button("Save As…") { host.saveProjectAs() }
                .disabled(host.isOpeningProject || !host.hasSavableProject)
        }
        Menu("View") {
            // availableCases, like the menu bar — the Profiler toggle must not surface in a
            // release build's gear menu either.
            ForEach(Array(SZPanelKind.availableCases.enumerated()), id: \.element) { _, kind in
                Toggle(kind.displayName, isOn: panelVisibilityBinding(kind))
            }
            Divider()
            // Mirrors View ▸ Clone/Pop Out Viewport verbatim (lockstep rule; no shortcuts here).
            Button("Clone Viewport") { host.clonePanel(.viewport) }
                .disabled(!host.canClonePanel(.viewport))
            Button(host.isPoppedOut(.viewport) ? "Dock Viewport" : "Pop Out Viewport") {
                if host.isPoppedOut(.viewport) {
                    host.popoutManager.dockToRememberedSpot(id: .viewport)
                } else {
                    host.popOutPanel(.viewport)
                }
            }
            .disabled(!host.isPoppedOut(.viewport) && !host.canPopOutPanel(.viewport))
            Divider()
            Menu("Display") {
                Toggle("Auto-Hide Panel Headers", isOn: Binding(get: { host.autoHidePanelHeaders },
                                                                set: { host.setAutoHidePanelHeaders($0) }))
                Toggle("Rounded Viewport Corners", isOn: Binding(get: { host.viewportRoundedCorners },
                                                                 set: { host.setViewportRoundedCorners($0) }))
                Toggle("Show Agent Activity", isOn: Binding(get: { host.showAgentActivity },
                                                            set: { host.setShowAgentActivity($0) }))
            }
        }
        Menu("Graph") {
            Button("Center View") { host.centerView() }
                .disabled(host.store.project?.graph.nodes.isEmpty ?? true)
            Button("Zoom to Fit") { host.zoomToFit() }
                .disabled(host.store.project?.graph.nodes.isEmpty ?? true)
            Divider()
            Button("Tidy Graph") { host.tidyGraph() }
                .disabled(host.store.project?.graph.nodes.isEmpty ?? true)
            Divider()
            Toggle("Snap to Grid", isOn: Binding(get: { host.snapToGrid },
                                                 set: { host.setSnapToGrid($0) }))
            Toggle("Grid Cursor Trail", isOn: Binding(get: { host.gridCursorTrail },
                                                      set: { host.setGridCursorTrail($0) }))
            Toggle("Mini Map", isOn: Binding(get: { host.showMiniMap },
                                             set: { host.setShowMiniMap($0) }))
            Toggle("Live Previews", isOn: Binding(get: { host.livePreviews },
                                                  set: { host.setLivePreviews($0) }))
        }
        Divider()
        Button("AI Settings…") { host.presentProviderSetup() }
        Divider()
        // Collapse the community/support links into one Help submenu so the gear's top level stays light.
        // Mirrors the macOS menu bar's Help menu — both render `helpLinks`, so they never drift.
        Menu("Help") { helpLinks }
    }

    /// The community/support links — shared by the HUD gear's Help submenu and the macOS menu bar's Help
    /// menu (single source, so the two stay identical). "github"/"discord" are custom symbol sets
    /// (SZApp/Assets.xcassets, from github.com/jeremieb/social-symbols); as .symbolsets they render like
    /// native SF Symbols, baseline-aligned and font-scaled to sit flush with the globe/envelope. The
    /// GitHub/Discord labels are action-worded ("Star on GitHub", "Join the Discord") so the menu
    /// itself gently nudges — matching the welcome window's CTAs.
    @ViewBuilder
    private var helpLinks: some View {
        Button { host.presentWelcome() } label: { Label("Welcome to SubjectiveZero", systemImage: "sparkles") }
        Divider()
        Button { host.openWebsite() } label: { Label("Website", systemImage: "globe") }
        Button { host.openGitHub() } label: { Label("Star on GitHub", image: "github") }
        Button { host.joinDiscord() } label: { Label("Join the Discord", image: "discord") }
        Divider()
        Button { host.sendFeedbackEmail() } label: { Label("Send Feedback", systemImage: "envelope") }
    }

    /// "Version 1.2 (345)" — the welcome window's identity line (same format as SZMain's verifier).
    private static var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "dev"
        return "\(version) (\(build))"   // just the numbers; the view prints the "Version" label outside the pill
    }

    /// The welcome/home split launcher (SZUI), built here where `host` and the app-bundle GitHub/Discord
    /// symbolsets are in scope. Load paths (New / Open / Open Recent / continue) all route through
    /// `switchProject`, which dismisses the welcome on success; Star retires the earned nudge.
    private var welcomeView: some View {
        SZWelcomeOverlay(
            versionText: Self.appVersionText,
            taglines: [
                "An agentic harness for creative coding.",
                "Explore at the speed of prompts. Refine with the precision of code.",
                "An agentic node editor for creative coding.",
                "A node editor that adapts to your context.",
                "Creative coding POWERED BY AI™ OMG",   // the wink — never index 0, so never shown first
            ],
            recents: Array(host.existingRecentProjectPaths.prefix(6)).map { path in
                SZWelcomeRecent(id: path,
                                name: URL(filePath: path).deletingPathExtension().lastPathComponent,
                                path: path)
            },
            showAtStartup: host.showWelcomeAtStartup,
            shareUsageData: host.telemetryEnabled,
            githubIcon: Image("github"),      // symbolsets live in the app bundle, not SZUI's
            discordIcon: Image("discord"),
            opening: host.openingProject,
            onOpenRecent: { host.openProject(at: URL(filePath: $0)) },
            onNewProject: { host.newProject() },
            onOpenProject: { host.openProjectViaPanel() },
            onClearRecents: { host.clearRecentProjects() },
            onStarGitHub: { host.openGitHub() },
            onJoinDiscord: { host.joinDiscord() },
            onOpenWebsite: { host.openWebsite() },
            onSetShowAtStartup: { host.setShowWelcomeAtStartup($0) },
            onSetShareUsageData: { host.setTelemetryEnabled($0) },
            onOpenPrivacyInfo: { host.openPrivacyInfo() },
            onClose: { host.continueFromWelcome() })
    }

    /// The transcript's jump action, nil where the Profiler surface doesn't exist (its link then
    /// never renders). Extracted so the panelContent builder stays type-checkable.
    private var revealInProfilerAction: (@Sendable @MainActor (UUID) -> Void)? {
        guard SZPanelKind.profilerPanelAvailable else { return nil }
        let host = host
        return { host.revealInProfiler($0) }
    }

    /// The transcript's jump into the Agent Graph. Unconditional, unlike the Profiler's above: that
    /// panel is debug-only, this one ships everywhere the packs do.
    private var revealInAgentGraphAction: (@Sendable @MainActor (UUID) -> Void)? {
        let host = host
        return { host.revealInAgentGraph($0) }
    }

    /// Prompt inspection, nil when tracing isn't recording prompts (the button then never renders).
    private var viewTurnPromptAction: (@Sendable @MainActor (UUID) -> Void)? {
        guard SZTrace.isEnabled else { return nil }
        let host = host
        return { host.viewTurnPrompt($0) }
    }

    /// Token inspection — the turn's actual in/out text in the "Tokens" window. Composed here
    /// because `openWindow` is a scene-level action the SZUI panel can't reach on its own.
    private var viewTurnTokensAction: (@Sendable @MainActor (UUID) -> Void)? {
        guard SZTrace.isEnabled else { return nil }
        let host = host
        let openWindow = openWindow
        return { openWindow(value: host.turnTokenReport(for: $0)) }
    }

    /// One case per panel; the initializers are the pre-refactor ones, moved verbatim out of the old
    /// SplitView tree (min sizes now live in SZPanelLayoutGeometry, not `.frame` constraints).
    /// Addressed by SZPanelID: the viewport case wires the instance's surface events (attach /
    /// resize / detach — SZHost+Viewports.swift); the single-instance panels only care about the kind. Note a
    /// pop-out/dock intentionally recreates the panel's view in its new window (one expected
    /// "[SZViewportPanel] makeNSView" print per transition — render state lives in the runtime);
    /// WITHIN a window, layout edits still never recreate it (the container's stable ForEach ids).
    @ViewBuilder
    private func panelContent(_ id: SZPanelID) -> some View {
        switch id.kind {
        case .viewport:
            SZViewportPanel(device: host.runtime?.device, events: host.viewportEvents(for: id))
        case .nodeEditor:
            SZNodeEditorPanel(store: host.store, project: host.store.project,
                              status: host.status, isRunning: host.isRunning,
                              isPaused: host.isPaused,
                              nodeAgentState: host.nodeAgentState,
                              graphOpStatus: host.graphOpStatus, runWorkSet: host.runWorkSet,
                              lockedNodes: host.lockedNodes, hiddenPieces: host.hiddenPieces,
                              chatShown: host.chatVisible,
                              agentsWorking: host.isRunning || !host.chatInFlight.isEmpty,
                              // "There's unimplemented work you should kick off" — pending nodes, no
                              // run, AND the Director isn't already mid-decompose-turn on it (that
                              // turn IS the kick-off, so the beacon would misread as "needs you").
                              pendingWorkHint: host.pendingWorkAvailable
                                  && !host.chatInFlight.contains(SZChatScope.directorKey),
                              pendingNodeCount: host.pendingNodeCount,
                              snapToGrid: host.snapToGrid,
                              gridCursorTrail: host.gridCursorTrail,
                              showMiniMap: host.showMiniMap,
                              livePreviews: host.livePreviews,
                              previewFrames: host.previewFrames,
                              cardProvider: host.cardHost,
                              onVisibleNodesChanged: { host.setVisiblePreviewNodes($0) },
                              cameraCommand: host.cameraCommand,
                              selectedNodeID: $selectedNodeID,
                              onMentionNodeInChat: { host.mentionNodeInComposer($0) },
                              onOpenNodeSource: { host.openNodeSource($0) },
                              onFixNode: { host.stageRebuildFix(node: $0) },
                              onToggleDirectorChat: { host.toggleDirectorChat() },
                              onBuild: { host.buildPressed() },
                              onTogglePause: { host.togglePlayback() },
                              onResetTime: { host.resetPlayback() },
                              onSetInputDefault: { host.setInputDefault(node: $0, port: $1, value: $2, persist: $3) },
                              onToggleDisplay: { host.toggleDisplay(node: $0, port: $1) },
                              onCommitPrompt: { host.updateNodeContent(id: $0, prompt: $1) },
                              onLivePrompt: { host.notePendingPromptEdit(id: $0, text: $1) },
                              onTogglePreview: { host.toggleNodePreview(node: $0, port: $1) },
                              onTogglePlugs: { host.toggleNodePlugs(node: $0) },
                              optionsFor: { host.effectiveOptions(node: $0, port: $1) },
                              onDeleteNodes: { host.deleteNodes(ids: $0) },
                              onDeleteConnection: { host.deleteConnection(id: $0) },
                              onConnect: { host.addConnection(from: $0, to: $1, kind: $2) },
                              onReconnectConnection: { host.reconnectConnection(id: $0, end: $1, to: $2) },
                              contextSuggestionsFor: { host.contextSuggestions(for: $0) },
                              onPickContextSuggestion: { host.pickContextSuggestion($0) },
                              onContextFreeText: { host.contextFreeText(target: $0, text: $1) },
                              onCreateMediaNodes: { host.createMediaNodes($0) },
                              onNodeAdded: { host.noteNodeAdded($0) },
                              // The HUD gear menu — an in-canvas mirror of the macOS menu bar (Project /
                              // View / Graph), plus AI Settings… and community links. Built here where
                              // `host`, panelVisibilityBinding, and the app-bundle Discord asset are in
                              // scope; erased to AnyView for the pure SZUI panel. Re-evaluates on host
                              // changes (Observation) so disabled states / toggles stay live.
                              gearMenu: AnyView(gearMenuContent))
        case .chat:
            // One pass over the (small) live queue per body evaluation, not a scan per bubble row —
            // the panel calls isQueued for every user message on every streamed token.
            let queuedIDs = Set(host.mailbox.envelopes.lazy.filter { $0.state == .queued }.map(\.id))
            SZChatPanel(store: host.store, feed: host.chatFeed,
                        project: host.store.project,
                        streaming: !host.chatInFlight.isEmpty,
                        streamingIDs: Set(host.inFlightAssistantIDs.values),
                        isRunning: host.isRunning, isLoading: host.openingProject != nil,
                        showTurnBreakdown: host.showTurnBreakdown,
                        agentAccents: host.chatAgentAccents,
                        workingScopes: host.chatInFlight,
                        runThreadIDs: host.liveThreadIDs,
                        agentGraphRuns: host.agentGraphRuns,
                        scheduledTasks: host.scheduledTaskRows,
                        onCancelScheduledTask: { host.withdrawTask($0) },
                        onStopOneRun: { host.cancelRun(thread: $0) },
                        isQueued: { queuedIDs.contains($0) },   // envelope id == bubble id (sendChat)
                        onSend: { host.sendChat(scope: .director, message: $0, attachments: $1) },
                        onClearTranscript: { host.clearChatTranscript($0) },
                        canStopTurn: !host.chatTurnTasks.isEmpty,
                        onCancelChatTurn: { _ in host.cancelStreamingChatTurns() },
                        mentionCandidates: host.mentionCandidates,
                        pendingDraft: host.pendingComposerDraft,
                        onConsumePendingDraft: { host.consumeComposerDraft($0) },
                        pendingMention: host.pendingComposerMention,
                        onConsumePendingMention: { host.consumeComposerMention($0) },
                        onOpenAISettings: { host.presentProviderSetup() })
                // The transcript's "open in Profiler" link — set only where the surface exists,
                // so the button simply doesn't render in builds without the panel.
                .environment(\.szRevealInProfiler, revealInProfilerAction)
                .environment(\.szRevealInAgentGraph, revealInAgentGraphAction)
                .environment(\.szViewTurnPrompt, viewTurnPromptAction)
                .environment(\.szHeldPromptTurnIDs, host.heldPromptIDs)
        case .profiler:
            // The trace browser (DEBUG builds — normalize() strips the leaf elsewhere). Reads
            // transcripts via the store; no live host wiring beyond node titles for lane names.
            SZProfilerPanel(store: host.store, titles: host.nodeTitlesByScopeKey,
                            tracingEnabled: SZTrace.isEnabled,
                            unreadRunIDs: host.unreadRunIDs,
                            onSelectRun: { host.unreadRunIDs.remove($0) },
                            focusRequest: host.profilerFocusRequest,
                            onConsumeFocus: { host.profilerFocusRequest = nil })
                .environment(\.szViewTurnPrompt, viewTurnPromptAction)
                .environment(\.szHeldPromptTurnIDs, host.heldPromptIDs)
                .environment(\.szViewTurnTokens, viewTurnTokensAction)
        case .agentGraph:
            // How you read what the agents actually did: the pack library's plans and the
            // RUNS records, all plain values + closures (SZUI never sees SZAI).
            SZAgentGraphPanel(planAgents: host.agentGraphPlanAgents(),
                              runs: host.agentGraphRuns,
                              resolveGraph: { [weak host] in host?.agentGraphResolve($0) },
                              nodeTitle: { [weak host] id in
                                  guard let nodeID = SZNodeID(uuidString: id) else { return nil }
                                  return host?.store.project?.graph.node(id: nodeID)?.title
                              },
                              openStepSource: { [weak host] in host?.openPackSource(agent: $0, source: $1) },
                              focusRequest: host.agentGraphFocusRequest,
                              onConsumeFocus: { host.agentGraphFocusRequest = nil },
                              planFocusRequest: agentGraphPlanFocus,
                              onConsumePlanFocus: { agentGraphPlanFocus = nil },
                              store: host.store)
        }
    }
}
