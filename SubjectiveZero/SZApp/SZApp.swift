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

    /// Quit gate: rescue an untitled project before its temp files are cleaned up (saved projects
    /// autosave, so they quit silently). Skipped while a run/chat owns the graph — Save As can't run
    /// then anyway, and the untitled project is already autosaved, so a mid-run quit loses nothing.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let host, host.isUntitledProject, !host.isBusyForProjectOps else { return .terminateNow }
        Task { @MainActor in
            let proceed = await host.confirmSaveOrDiscardIfUnsaved(actionName: "quitting")
            sender.reply(toApplicationShouldTerminate: proceed)
        }
        return .terminateLater
    }

    /// Last-chance flush — the quit-path counterpart of the per-message/run-end flush points. A
    /// SIGKILL/crash skips this and loses only messages since the last completion flush (bounded).
    func applicationWillTerminate(_ notification: Notification) {
        host?.flushAllTranscripts()
        host?.persistAgentSessions()
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
            guard let host, host.isUntitledProject, !host.isBusyForProjectOps else { return true }
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
                        onDividerFractionChange: { host.setPanelDividerFraction($1, at: $0) },
                        onDividerDragEnd: { host.commitPanelDividerFraction($1, at: $0) },
                        onMovePanel: { host.movePanel($0, onto: $1, zone: $2) },
                        onClosePanel: { host.closePanel($0) },
                        onToggleMaximize: { host.toggleMaximizePanel($0) }) { kind in
                            panelContent(kind)
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
            // The Agent Providers setup sheet — auto-presents on a first-run launch (SZHost+
            // ProviderHealth), reopened via ⌘, or the HUD provider picker. A set-false (Esc/swipe) is a
            // Skip: dismiss without confirming, so first-run simply re-presents next launch.
            .sheet(isPresented: Binding(get: { host.providerSetupPresented },
                                        set: { if !$0 { host.skipProviderSetup() } })) {
                SZProviderSetupSheet(cards: host.providerSetupCards,
                                     selectedID: host.selectedSetupProviderID,
                                     onSelect: { host.selectSetupProvider($0) },
                                     onRefresh: { Task { await host.refreshProviderHealthOnce() } },
                                     onTest: { host.runProviderProbe($0) },
                                     onOpenLogin: { host.openProviderLoginTerminal($0) },
                                     onConfirm: { host.confirmDefaultProvider() },
                                     onSkip: { host.skipProviderSetup() },
                                     onOpenSetupGuide: { host.openProviderSetupGuide() })
            }
            .task {
                appDelegate.host = host   // wire the quit-path flush + Finder-open (see SZAppDelegate)
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
            // "New Window" — intended (single-window app). Persistence is automatic, so ⌘S "Save"
            // is a force-flush for a saved project (reassurance, not a state change) and routes to
            // Save As… for an untitled one (rescue to a chosen location). All items sit out a run /
            // in-flight chat (the methods are guarded too — MCP can race a click).
            CommandGroup(replacing: .newItem) {
                Button("New Project") { host.newProject() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(host.isBusyForProjectOps)
                Button("Open…") { host.openProjectViaPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(host.isBusyForProjectOps)
                // The busy disable sits on the ITEMS: .disabled on the Menu itself doesn't render
                // on macOS (verified live 2026-07-04 — siblings grayed, the submenu didn't).
                Menu("Open Recent") {
                    ForEach(host.existingRecentProjectPaths, id: \.self) { path in
                        Button(URL(filePath: path).deletingPathExtension().lastPathComponent) {
                            host.openProject(at: URL(filePath: path))
                        }
                        .disabled(host.isBusyForProjectOps)
                    }
                    Divider()
                    Button("Clear Menu") { host.clearRecentProjects() }
                        .disabled(host.recentProjectPaths.isEmpty || host.isBusyForProjectOps)
                }
                Divider()
                // Untitled → "Save…" opens the Save As panel (there's nowhere to save yet); a saved
                // project → "Save" force-flushes to disk. The label tracks isUntitledProject (derived,
                // observable), so it flips after a Save As.
                Button(host.isUntitledProject ? "Save…" : "Save") { host.saveProject() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(host.isBusyForProjectOps || host.store.project == nil)
                Button("Save As…") { host.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(host.isBusyForProjectOps || host.store.project == nil)
            }
            // ⌘, — the app's only settings surface today; graduates into a real Settings window
            // once more prefs earn one (docs/UI.md).
            CommandGroup(replacing: .appSettings) {
                Button("AI Providers…") { host.presentProviderSetup() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(Array(SZPanelKind.allCases.enumerated()), id: \.element) { index, kind in
                    Toggle(kind.displayName, isOn: panelVisibilityBinding(kind))
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                }
                // Panel chrome, so it lives with the panel-visibility toggles rather than in Graph.
                Toggle("Auto-Hide Panel Headers", isOn: Binding(get: { host.autoHidePanelHeaders },
                                                                set: { host.setAutoHidePanelHeaders($0) }))
                // Appearance, so it sits with the panel-chrome prefs. Squares just the viewport tile.
                Toggle("Rounded Viewport Corners", isOn: Binding(get: { host.viewportRoundedCorners },
                                                                 set: { host.setViewportRoundedCorners($0) }))
                // Chat display, kept with the other view prefs — per-turn tokens under replies.
                Toggle("Show Token Counts", isOn: Binding(get: { host.showTokenCounts },
                                                          set: { host.setShowTokenCounts($0) }))
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
                Toggle("Snap to Grid", isOn: Binding(get: { host.snapToGrid },
                                                     set: { host.setSnapToGrid($0) }))
                Toggle("Grid Cursor Trail", isOn: Binding(get: { host.gridCursorTrail },
                                                          set: { host.setGridCursorTrail($0) }))
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
                Button("Open Debug Chat") { host.showChat(.debug) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
        #endif
    }

    /// View-menu checkmark ↔ the panel's presence in the layout tree. Closing the last panel is
    /// refused by the model, so the checkmark simply snaps back.
    private func panelVisibilityBinding(_ kind: SZPanelKind) -> Binding<Bool> {
        Binding(get: { host.panelLayout.contains(kind) },
                set: { $0 ? host.showPanel(kind) : host.closePanel(kind) })
    }

    /// The HUD gear menu's items — the canvas-side mirror of the macOS menu bar. Mirrors the `.commands`
    /// wiring verbatim (same host methods + bindings) so the two stay in lockstep, then adds AI Providers…
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
                .disabled(host.isBusyForProjectOps)
            Button("Open…") { host.openProjectViaPanel() }
                .disabled(host.isBusyForProjectOps)
            Menu("Open Recent") {
                ForEach(host.existingRecentProjectPaths, id: \.self) { path in
                    Button(URL(filePath: path).deletingPathExtension().lastPathComponent) {
                        host.openProject(at: URL(filePath: path))
                    }
                    .disabled(host.isBusyForProjectOps)
                }
                Divider()
                Button("Clear Menu") { host.clearRecentProjects() }
                    .disabled(host.recentProjectPaths.isEmpty || host.isBusyForProjectOps)
            }
            Divider()
            Button(host.isUntitledProject ? "Save…" : "Save") { host.saveProject() }
                .disabled(host.isBusyForProjectOps || host.store.project == nil)
            Button("Save As…") { host.saveProjectAs() }
                .disabled(host.isBusyForProjectOps || host.store.project == nil)
        }
        Menu("View") {
            ForEach(Array(SZPanelKind.allCases.enumerated()), id: \.element) { _, kind in
                Toggle(kind.displayName, isOn: panelVisibilityBinding(kind))
            }
            Toggle("Auto-Hide Panel Headers", isOn: Binding(get: { host.autoHidePanelHeaders },
                                                            set: { host.setAutoHidePanelHeaders($0) }))
            Toggle("Rounded Viewport Corners", isOn: Binding(get: { host.viewportRoundedCorners },
                                                             set: { host.setViewportRoundedCorners($0) }))
            Toggle("Show Token Counts", isOn: Binding(get: { host.showTokenCounts },
                                                      set: { host.setShowTokenCounts($0) }))
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
            Toggle("Live Previews", isOn: Binding(get: { host.livePreviews },
                                                  set: { host.setLivePreviews($0) }))
        }
        Divider()
        Button("AI Providers…") { host.presentProviderSetup() }
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
            githubIcon: Image("github"),      // symbolsets live in the app bundle, not SZUI's
            discordIcon: Image("discord"),
            onOpenRecent: { host.openProject(at: URL(filePath: $0)) },
            onNewProject: { host.newProject() },
            onOpenProject: { host.openProjectViaPanel() },
            onClearRecents: { host.clearRecentProjects() },
            onStarGitHub: { host.openGitHub() },
            onJoinDiscord: { host.joinDiscord() },
            onOpenWebsite: { host.openWebsite() },
            onSetShowAtStartup: { host.setShowWelcomeAtStartup($0) },
            onClose: { host.continueFromWelcome() })
    }

    /// One case per panel; the initializers are the pre-refactor ones, moved verbatim out of the old
    /// SplitView tree (min sizes now live in SZPanelLayoutGeometry, not `.frame` constraints).
    @ViewBuilder
    private func panelContent(_ kind: SZPanelKind) -> some View {
        switch kind {
        case .viewport:
            SZViewportPanel(device: host.runtime?.device, renderFrame: host.renderViewportFrame)
        case .nodeEditor:
            SZNodeEditorPanel(store: host.store, project: host.store.project,
                              status: host.status, isRunning: host.isRunning,
                              isPaused: host.isPaused,
                              nodeAgentState: host.nodeAgentState,
                              graphOpStatus: host.graphOpStatus, runWorkSet: host.runWorkSet, hiddenPieces: host.hiddenPieces,
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
                              livePreviews: host.livePreviews,
                              previewFrames: host.previewFrames,
                              onVisibleNodesChanged: { host.setVisiblePreviewNodes($0) },
                              cameraCommand: host.cameraCommand,
                              selectedNodeID: $selectedNodeID,
                              onOpenNodeChat: { host.showChat(.node($0)) },
                              onOpenNodeSource: { host.openNodeSource($0) },
                              onFixNode: { host.stageRebuildFix(node: $0) },
                              onToggleDirectorChat: { host.toggleDirectorChat() },
                              onBuild: { host.startRun() },
                              onStopRun: { host.cancelRun() },
                              onTogglePause: { host.togglePlayback() },
                              onResetTime: { host.resetPlayback() },
                              onSetInputDefault: { host.setInputDefault(node: $0, port: $1, value: $2, persist: $3) },
                              onToggleDisplay: { host.toggleDisplay(node: $0, port: $1) },
                              onTogglePreview: { host.toggleNodePreview(node: $0, port: $1) },
                              optionsFor: { host.effectiveOptions(node: $0, port: $1) },
                              onDeleteNodes: { host.deleteNodes(ids: $0) },
                              onDeleteConnection: { host.deleteConnection(id: $0) },
                              onConnect: { host.addConnection(from: $0, to: $1, kind: $2) },
                              onReconnectConnection: { host.reconnectConnection(id: $0, end: $1, to: $2) },
                              contextSuggestionsFor: { host.contextSuggestions(for: $0) },
                              onPickContextSuggestion: { host.pickContextSuggestion($0) },
                              onContextFreeText: { host.contextFreeText(target: $0, text: $1) },
                              onCreateMediaNodes: { host.createMediaNodes($0) },
                              // The HUD gear menu — an in-canvas mirror of the macOS menu bar (Project /
                              // View / Graph), plus AI Providers… and community links. Built here where
                              // `host`, panelVisibilityBinding, and the app-bundle Discord asset are in
                              // scope; erased to AnyView for the pure SZUI panel. Re-evaluates on host
                              // changes (Observation) so disabled states / toggles stay live.
                              gearMenu: AnyView(gearMenuContent))
        case .chat:
            SZChatPanel(store: host.store, scope: host.activeChatScope, tabs: host.chatTabs,
                        project: host.store.project, provider: host.activeProviderID,
                        streaming: host.chatInFlight.contains(host.activeChatScope.key),
                        isRunning: host.isRunning, showTokenCounts: host.showTokenCounts,
                        onStopRun: { host.cancelRun() },
                        workingScopes: host.chatInFlight,
                        unreadScopes: host.unreadScopes,
                        needsInputScopes: host.needsInputScopes,
                        onSend: { host.sendChat(scope: host.activeChatScope, message: $0, attachments: $1) },
                        onSelectScope: { host.showChat($0) },
                        onCloseTab: { host.closeChatTab($0) },
                        onReorderTab: { host.reorderChatTabs(move: $0, before: $1) },
                        onClearTranscript: { host.clearChatTranscript($0) },
                        canStopTurn: host.chatTurnTasks[host.activeChatScope.key] != nil,
                        onCancelChatTurn: { host.cancelChatTurn($0) },
                        scopeLocked: host.activeScopeLocked,
                        mentionCandidates: host.mentionCandidates,
                        pendingDraft: host.pendingComposerDraft,
                        onConsumePendingDraft: { host.consumeComposerDraft($0) },
                        generationPickerItems: host.providerGenerationPickerItems,
                        onSetProvider: { host.setActiveProvider($0) },
                        onSetModel: { host.setActiveModel($0) },
                        onSetReasoningEffort: { host.setActiveReasoningEffort($0) },
                        onSetFastMode: { host.setActiveFastMode($0) },
                        onOpenProviderSetup: { host.presentProviderSetup() })
        }
    }
}
