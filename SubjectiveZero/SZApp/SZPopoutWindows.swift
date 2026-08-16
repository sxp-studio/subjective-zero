// SPDX-License-Identifier: AGPL-3.0-only
// Pop-out panel windows — the AppKit half of "window out" / "dock back". Host-managed raw NSWindows
// (NOT a SwiftUI WindowGroup: scene restoration would re-open stale pop-outs on its own schedule,
// openWindow gives no initial-frame control, and the host — which owns "main window closed → close
// children" and "docked → close window" — lives outside any scene). One controller per popped-out
// panel, keyed by SZPanelID; the manager dictionary is the retain root (`isReleasedWhenClosed =
// false`).
//
// Lifecycle policy (docs/UI.md): pop-outs are CHILDREN of the main window's lifetime. Main window
// closes → all pop-outs close first, so the main window is genuinely the last window and the app
// quits exactly as before (`applicationShouldTerminateAfterLastWindowClosed`). Hooked on
// willCloseNotification, NOT windowShouldClose — the untitled-save guard runs there and may CANCEL,
// and a cancelled close must not have destroyed the pop-outs. A pop-out's own ✕/⌘W docks the panel
// back into the layout (least destructive; "gone" is reserved for explicit closes — the View menu
// or ui_close_panel — which drop the panel entirely). While the welcome surface is up the pop-outs
// order out; they return (or first restore from app-state) when a project takes over.
import AppKit
import SwiftUI
import SZCore
import SZUI

@MainActor
final class SZPopoutWindowManager {
    /// Wired by SZHost.start(). The chrome configurator can flip `setWorkspaceActive` BEFORE that
    /// (its DispatchQueue hop races startup), so a set re-delivers the current activation — the
    /// relaunch restore must not be lost to that race.
    weak var host: SZHost? {
        didSet { host?.workspaceActivationChanged(workspaceActive) }
    }
    /// Injected by SZApp's `.task` (panelContent needs the App struct's scope). AnyView-erased for
    /// the same reason as the HUD gear menu.
    var makePanelContent: ((SZPanelID) -> AnyView)?

    private var controllers: [SZPanelID: SZPopoutWindowController] = [:]
    private var mainWindowObservers: [NSObjectProtocol] = []
    /// The welcome↔workspace edge (set from the chrome configurator, same signal that resizes the
    /// main window): pop-outs hide behind the welcome surface and return with the workspace.
    private var workspaceActive = false

    /// Why a window is being closed programmatically — windowWillClose consults it to decide
    /// whether this close means "dock the panel back" (a USER close: traffic-light ✕ / ⌘W) or is
    /// our own teardown (dock commit, panel closed for real, main window closing).
    enum CloseReason {
        case docked, panelClosed, mainWindowClosed
    }

    /// The main window, learned from the chrome configurator. Registers the close-children observer
    /// and the visibility observers behind `mainWindowIsDisplayable`.
    weak var mainWindow: NSWindow? {
        didSet {
            guard mainWindow !== oldValue, let window = mainWindow else { return }
            for observer in mainWindowObservers { NotificationCenter.default.removeObserver(observer) }
            let center = NotificationCenter.default
            mainWindowObservers = [
                center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    // willClose = the close IS proceeding (a cancelled save prompt never gets here).
                    // Synchronous: the children die before the main window finishes closing, so the
                    // app's last-window quit fires exactly as in the single-window days.
                    MainActor.assumeIsolated { self?.closeAll(reason: .mainWindowClosed) }
                },
            ]
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                mainWindowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.host?.mainWindowVisibilityChanged() }
                })
            }
            host?.mainWindowVisibilityChanged()
        }
    }

    /// Whether the main window can show pixels (tiles + node editor live here). `true` before it is
    /// learned (headless/MCP sessions, first frames of launch).
    var mainWindowIsDisplayable: Bool {
        guard let window = mainWindow else { return true }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    var poppedOutIDs: Set<SZPanelID> { Set(controllers.keys) }

    /// Whether `id`'s window can actually show pixels right now. A window that can't — hidden
    /// behind the welcome surface (ordered out), miniaturized, or fully occluded by other windows —
    /// must not count as a visible viewport: its display link auto-suspends, so if it held render
    /// drivership the timeline would stop and every VISIBLE viewport would freeze on the held
    /// frame. The controller re-syncs the driver on every occlusion/miniaturize/fullscreen edge.
    func windowIsDisplayable(_ id: SZPanelID) -> Bool {
        guard let window = controllers[id]?.window else { return false }
        return window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
    }

    /// Whether `id`'s window is in native fullscreen — the top rung of the drivership ladder (a
    /// fullscreen output must never lose native resolution to a large floating preview window).
    func windowIsFullscreen(_ id: SZPanelID) -> Bool {
        controllers[id]?.window.styleMask.contains(.fullScreen) ?? false
    }

    /// Whether `id`'s window is mid dock-flight — its windowDidMove events are OUR animation, not
    /// a user drag (NSEvent.pressedMouseButtons is global, so "button down" alone can't tell a
    /// flight apart from the user simultaneously grabbing ANOTHER window).
    func isDockAnimating(_ id: SZPanelID) -> Bool {
        dockAnimatingIDs.contains(id)
    }

    /// Create (or reveal) the pop-out window for `id` at `frame` (screen coordinates). The caller
    /// has already detached the panel from the layout tree.
    func openPopout(id: SZPanelID, frame: NSRect) {
        if let existing = controllers[id] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        guard let host, let content = makePanelContent?(id) else { return }
        let controller = SZPopoutWindowController(id: id, frame: frame, host: host, manager: self,
                                                  content: content)
        controllers[id] = controller
        if workspaceActive { controller.window.makeKeyAndOrderFront(nil) }
    }

    /// Close `id`'s window for `reason`. The reason is stamped on the controller FIRST so its
    /// windowWillClose doesn't misread the programmatic close as a user dock-back.
    func closePopout(id: SZPanelID, reason: CloseReason) {
        guard let controller = controllers.removeValue(forKey: id) else { return }
        controller.teardownReason = reason
        controller.window.close()
    }

    func closeAll(reason: CloseReason) {
        for id in Array(controllers.keys) { closePopout(id: id, reason: reason) }
    }

    /// A user close (✕/⌘W) already mid-flight: drop the bookkeeping without re-closing.
    func noteUserClose(of id: SZPanelID) {
        controllers[id] = nil
    }

    /// Re-apply the positional titles (window title bar + the shell's strip) — called by the
    /// host whenever the live panel set changes, since "Viewport 2" names a POSITION, not an
    /// identity (closing a sibling can renumber a window).
    func refreshTitles(_ title: (SZPanelID) -> String) {
        for (id, controller) in controllers { controller.updateTitle(title(id)) }
    }

    /// The welcome↔workspace edge: hide pop-outs behind the launcher, bring them back with the
    /// workspace. The first activation is also the relaunch-restore hook (the host re-opens
    /// persisted pop-outs when the workspace first appears).
    func setWorkspaceActive(_ active: Bool) {
        guard active != workspaceActive else { return }
        workspaceActive = active
        for controller in controllers.values {
            if active { controller.window.orderFront(nil) } else { controller.window.orderOut(nil) }
        }
        host?.workspaceActivationChanged(active)
    }

    // MARK: - Drag-to-dock

    /// The live user-drag watcher + the id it is watching. NATIVE window drags (titlebar /
    /// movable-background) have no end-of-drag API, so the drag is reconstructed: windowDidMove
    /// with the left button down (and not our own dock flight, and not a live resize) marks a
    /// user drag, and this poll then tracks the cursor at ~30ms until release. The MOVED WINDOW's
    /// id is the ground truth for which drag is live — a report for a different id supersedes the
    /// running watcher (release+regrab between polls must not dock the stale window).
    private var dragWatcher: Task<Void, Never>?
    private var dragWatcherID: SZPanelID?
    /// Windows mid dock-flight animation (see `isDockAnimating`).
    private var dockAnimatingIDs: Set<SZPanelID> = []
    /// Ignore-jitter gate: dock intent requires actually dragging some distance, so a 1px nudge
    /// of a window that happens to sit over the main window can never dock it.
    private static let dragCommitThreshold: CGFloat = 8

    /// A pop-out window moved with the mouse button down — a user drag. Publish the dock candidate
    /// under the cursor (the container renders the same drop-preview overlay as internal header
    /// drags) and watch for release: over a tile → dock there; anywhere else → stay floating.
    func noteUserDragMoved(id: SZPanelID) {
        if let watched = dragWatcherID, watched != id {
            // A different window is moving now — the old drag ended between polls. Abandon it
            // (its release point is unknowable; its frame persists via windowDidMove/EndLiveResize).
            dragWatcher?.cancel()
            dragWatcher = nil
            dragWatcherID = nil
            host?.popoutDockCandidate = nil
        }
        guard dragWatcher == nil else { return }
        dragWatcherID = id
        let start = NSEvent.mouseLocation
        dragWatcher = Task { @MainActor [weak self] in
            var traveled = false
            while !Task.isCancelled, NSEvent.pressedMouseButtons & 1 == 1 {
                guard let self else { return }
                let cursor = NSEvent.mouseLocation
                traveled = traveled || hypot(cursor.x - start.x, cursor.y - start.y) >= Self.dragCommitThreshold
                self.host?.popoutDockCandidate = !traveled ? nil
                    : self.dockCandidate(at: cursor).map {
                        SZPanelDockPreview(rect: $0.preview, label: self.dockLabel(dragged: id, candidate: $0))
                    }
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard let self, !Task.isCancelled else { return }
            self.dragWatcher = nil
            self.dragWatcherID = nil
            if traveled {
                self.finishUserDrag(id: id, at: NSEvent.mouseLocation)
            } else {
                self.host?.popoutDockCandidate = nil
                self.noteFrameChanged(id)
            }
        }
    }

    private func finishUserDrag(id: SZPanelID, at screenPoint: NSPoint) {
        defer { host?.popoutDockCandidate = nil }
        guard let host, let candidate = dockCandidate(at: screenPoint) else {
            noteFrameChanged(id)
            return
        }
        let target = screenRect(forContainerRect: candidate.preview)
        animateThenDock(id: id, toScreenRect: target) {
            host.dockPanel(id, onto: candidate.target, zone: candidate.zone)
        }
    }

    /// The dock-back button / menu / MCP path: animate home to the remembered (or default) spot,
    /// then insert. The tile rect is only knowable AFTER the layout mutation, so this animates to
    /// the restore preview when it can, else docks without ceremony.
    func dockToRememberedSpot(id: SZPanelID) {
        guard let host else { return }
        animateThenDock(id: id, toScreenRect: rememberedDockScreenRect(for: id)) {
            host.dockPanel(id)
        }
    }

    /// Persist a moved/resized pop-out frame (move/resize-end, drag release off-grid).
    func noteFrameChanged(_ id: SZPanelID) {
        guard let frame = controllers[id]?.window.frame else { return }
        host?.notePopoutFrameChanged(id, frame: frame)
    }

    // MARK: - Internals

    /// The main-window state the pure session math needs, nil when the main window can't take a
    /// dock right now (closed, miniaturized, on another Space — a drag on THIS Space must not
    /// commit a dock against tiles the user can't see — or welcome up).
    private func mainContentGeometry() -> (screenFrame: CGRect, safeAreaTop: CGFloat, size: CGSize)? {
        guard workspaceActive, let window = mainWindow, window.isVisible, !window.isMiniaturized,
              window.isOnActiveSpace, let contentView = window.contentView else { return nil }
        let frameInWindow = contentView.convert(contentView.bounds, to: nil)
        let screenFrame = window.convertToScreen(frameInWindow)
        return (screenFrame, contentView.safeAreaInsets.top, contentView.bounds.size)
    }

    private func dockCandidate(at screenPoint: NSPoint) -> SZPopoutDockSession.Candidate? {
        guard let host, let geometry = mainContentGeometry() else { return nil }
        let point = SZPopoutDockSession.containerPoint(fromScreen: screenPoint,
                                                       contentScreenFrame: geometry.screenFrame,
                                                       safeAreaTop: geometry.safeAreaTop)
        let usable = CGSize(width: geometry.size.width,
                            height: geometry.size.height - geometry.safeAreaTop)
        // topInset 0 — the same contract as the container's call site (the titlebar strip is the
        // safe area, already excluded from `usable` and the converted point).
        return SZPopoutDockSession.candidate(at: point, layout: host.panelLayout,
                                             maximized: host.maximizedPanel,
                                             containerSize: usable, topInset: 0)
    }

    /// "Dock Viewport 2 — left of Node Editor" — the drag-over affordance's capsule text
    /// (positional titles from the host, like every other user-facing name).
    private func dockLabel(dragged: SZPanelID, candidate: SZPopoutDockSession.Candidate) -> String {
        let side = switch candidate.zone {
        case .left: "left of"
        case .right: "right of"
        case .top: "above"
        case .bottom: "below"
        case .center: "onto"   // unreachable — the session maps center to an edge
        }
        let name = { (id: SZPanelID) in self.host?.panelTitle(id) ?? id.displayName }
        return "Dock \(name(dragged)) — \(side) \(name(candidate.target))"
    }

    private func screenRect(forContainerRect rect: CGRect) -> NSRect? {
        guard let geometry = mainContentGeometry() else { return nil }
        return SZPopoutDockSession.screenRect(forContainerRect: rect,
                                              contentScreenFrame: geometry.screenFrame,
                                              safeAreaTop: geometry.safeAreaTop)
    }

    /// Where a remembered-spot dock will land, best effort: the restore position's preview rect
    /// against the CURRENT layout (mirrors SZPanelLayoutState.insertPanel's neighbor/zone logic
    /// closely enough for an animation target; the model does the authoritative insert after).
    private func rememberedDockScreenRect(for id: SZPanelID) -> NSRect? {
        guard let host, let geometry = mainContentGeometry() else { return nil }
        guard let record = host.panelLayout.restorePositions[id],
              host.panelLayout.contains(record.neighbor) else { return nil }
        let usable = CGSize(width: geometry.size.width,
                            height: geometry.size.height - geometry.safeAreaTop)
        let frames = SZPopoutDockSession.tileFrames(layout: host.panelLayout, maximized: nil,
                                                    containerSize: usable, topInset: 0)
        guard let neighborRect = frames[record.neighbor] else { return nil }
        let preview = SZPanelLayoutGeometry.dropPreviewRect(zone: record.zone, in: neighborRect)
        return screenRect(forContainerRect: preview)
    }

    /// The dock affordance: fly the window to the target tile rect (matching maximize's 0.2
    /// ease-in-out), then commit the layout insert and close the window — the panel lands via the
    /// container's own structural settle. Reduce Motion, a fullscreen window (its frame is the
    /// Space — AppKit owns the exit transition on close), or no computable target skip the flight.
    private func animateThenDock(id: SZPanelID, toScreenRect target: NSRect?, commit: @escaping () -> Void) {
        guard let controller = controllers[id] else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let dock = { [weak self] in
            commit()
            self?.dockAnimatingIDs.remove(id)
            self?.closePopout(id: id, reason: .docked)
        }
        guard let target, !reduceMotion, !controller.window.styleMask.contains(.fullScreen) else {
            dock()
            return
        }
        dockAnimatingIDs.insert(id)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            controller.window.animator().setFrame(target, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated { dock() }
        })
    }
}

/// One pop-out window + its delegate: dock-back on a USER close, frame persistence on move/resize
/// end, driver re-sync on every visibility edge. Holds the window strongly (`isReleasedWhenClosed
/// = false`; the manager's dictionary is the retain root for the controller).
@MainActor
final class SZPopoutWindowController: NSObject, NSWindowDelegate {
    let id: SZPanelID
    let window: NSWindow
    /// Stamped by the manager BEFORE a programmatic close; nil means the close came from the user
    /// (traffic-light ✕ / ⌘W) and should dock the panel back.
    var teardownReason: SZPopoutWindowManager.CloseReason?

    private weak var host: SZHost?
    private weak var manager: SZPopoutWindowManager?
    /// The live title (window bar + shell strip) — positional, re-pushed via `updateTitle`.
    private let titleBox: SZPopoutWindowTitle
    /// Occlusion has no delegate method — observed via NotificationCenter (removed in deinit).
    private nonisolated(unsafe) var occlusionObserver: NSObjectProtocol?

    init(id: SZPanelID, frame: NSRect, host: SZHost, manager: SZPopoutWindowManager, content: AnyView) {
        self.id = id
        self.host = host
        self.manager = manager
        let title = host.panelTitle(id)
        self.titleBox = SZPopoutWindowTitle(title)

        // The main window's chrome language: transparent titlebar over full-bleed content, the
        // shell's glass strip SHARING the titlebar row (name + dock-back beside the traffic
        // lights — one slim strip, matching a docked tile's header in weight). System rounded
        // corners, native resizing, and real fullscreen (the projector case: green-button the
        // pop-out on the big display and it takes the top rung of the drivership ladder). The
        // whole body drags (`isMovableByWindowBackground`) — a pop-out's content has no competing
        // drag gestures, so anywhere-grab is free discoverability, and drag-to-dock reconstructs
        // native window drags from move events, not a dedicated strip.
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = title   // Mission Control / the Dock (positional, see updateTitle)
        window.backgroundColor = NSColor(white: 0.04, alpha: 1)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed   // pop-outs must never merge into a native tab group
        let minSize = SZPanelLayoutGeometry.minSize(for: id.kind)
        window.contentMinSize = NSSize(width: minSize.width,
                                       height: minSize.height + SZPopoutPanelShellMetrics.headerHeight)
        let shell = SZPopoutPanelShell(
            title: titleBox,
            headerLeadingInset: 78,   // clears the traffic lights sharing the strip
            onDock: { [weak manager] in manager?.dockToRememberedSpot(id: id) }
        ) { content }
        window.contentView = NSHostingView(rootView: shell)
        window.setFrame(frame, display: true)

        super.init()
        window.delegate = self
        // An occluded window's display link auto-suspends — it must not hold render drivership
        // (windowIsDisplayable reads occlusionState; this keeps the registry current on the edge).
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak host] _ in
            MainActor.assumeIsolated { host?.syncViewportDriver() }
        }
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    /// The live panel set changed — this window's positional name may have too.
    func updateTitle(_ title: String) {
        window.title = title
        titleBox.text = title
    }

    // MARK: NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Programmatic teardown (dock commit / panel closed / main window closing): the
            // manager already did the bookkeeping. A USER close is a dock-back gesture.
            guard teardownReason == nil else { return }
            manager?.noteUserClose(of: id)
            host?.dockPanel(id)
        }
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        MainActor.assumeIsolated {
            // A USER drag = left button down AND not our own dock flight (pressedMouseButtons is
            // global — during the flight the user may be pressing anywhere) AND not a live resize
            // (dragging the left/bottom resize edge moves the origin too, and a resize must never
            // read as drag-to-dock). Everything else just keeps the persisted frame honest.
            guard let manager else { return }
            if NSEvent.pressedMouseButtons & 1 == 1, !manager.isDockAnimating(id), !window.inLiveResize {
                manager.noteUserDragMoved(id: id)
            } else {
                manager.noteFrameChanged(id)
            }
        }
    }

    nonisolated func windowDidEndLiveResize(_ notification: Notification) {
        MainActor.assumeIsolated { manager?.noteFrameChanged(id) }
    }

    // A miniaturized window must not count as a visible viewport (nor hold render drivership).
    nonisolated func windowDidMiniaturize(_ notification: Notification) {
        MainActor.assumeIsolated { host?.syncViewportDriver() }
    }

    nonisolated func windowDidDeminiaturize(_ notification: Notification) {
        MainActor.assumeIsolated { host?.syncViewportDriver() }
    }

    // Fullscreen is the top rung of the drivership ladder — re-rank on both edges.
    nonisolated func windowDidEnterFullScreen(_ notification: Notification) {
        MainActor.assumeIsolated { host?.syncViewportDriver() }
    }

    nonisolated func windowDidExitFullScreen(_ notification: Notification) {
        MainActor.assumeIsolated { host?.syncViewportDriver() }
    }
}
