// SPDX-License-Identifier: AGPL-3.0-only
// Pop-out panel intents — the host half of "window out" / "dock back" (the AppKit half is
// SZPopoutWindows.swift). A popped-out panel is REMOVED from the layout tree (removePanel records
// its restore position = the dock-back target) and tracked in `poppedOutPanels`, persisted through
// the one app-state writer so pop-outs restore on relaunch like the rest of the workspace
// arrangement. Every visibility change re-syncs the viewport driver registry (one driver, the rest
// mirror — SZViewportDriverRegistry), which SZHost+Viewports pushes to the runtime.
import AppKit
import Foundation
import SZCore
import SZUI

extension SZHost {
    /// The kinds that offer the pop-out affordance — the ONE viewport-specific gate in the whole
    /// mechanism (everything else is generic over panels).
    static let popoutAllowedKinds: Set<SZPanelKind> = [.viewport]

    /// Pop-out gate for the header button / menu / MCP: the kind allows it, the panel is actually
    /// a tile right now, and it isn't the last one (an empty main window would break the container
    /// and the closing-the-window-quits story).
    func canPopOutPanel(_ id: SZPanelID) -> Bool {
        Self.popoutAllowedKinds.contains(id.kind) && panelLayout.contains(id)
            && panelLayout.presentIDs.count > 1 && !isPinnedViewport(id)
    }

    /// A viewport whose renderer cannot show a second copy (the page has one parent view).
    private func isPinnedViewport(_ id: SZPanelID) -> Bool {
        id.kind == .viewport && !capabilities.supportsViewportClones
    }

    /// Clone gate for the header button / menu: the kind is cloneable and a free instance exists
    /// (popped-out instances count as taken — their identities must never be reallocated).
    func canClonePanel(_ id: SZPanelID) -> Bool {
        guard id.kind.maxInstances > 1, panelLayout.contains(id), !isPinnedViewport(id) else { return false }
        let taken = panelLayout.presentIDs.union(poppedOutPanels.keys).filter { $0.kind == id.kind }
        return taken.count < id.kind.maxInstances
    }

    /// Header clone button / View ▸ Clone Viewport / `ui_clone_panel`: split the source tile 50/50
    /// with a new instance of its kind. Returns the clone's id, nil when refused (cap reached,
    /// source hidden).
    @discardableResult
    func clonePanel(_ source: SZPanelID) -> SZPanelID? {
        maximizedPanel = nil   // any structural edit exits maximize
        guard let clone = panelLayout.clonePanel(source, excluding: Set(poppedOutPanels.keys)) else {
            return nil
        }
        panelLayout.normalize()
        persistAppState()
        syncViewportDriver()
        return clone
    }

    /// Header pop-out button / View menu / `ui_popout_panel`: detach the tile into its own window.
    /// The window opens at the tile's exact screen rect — the tile visually detaches in place while
    /// the layout closes the gap behind it (the structural settle is the affordance; no window
    /// animation needed, inherently Reduce-Motion-safe). `frame` overrides that (the MCP path).
    @discardableResult
    func popOutPanel(_ id: SZPanelID, frame: NSRect? = nil) -> Bool {
        guard canPopOutPanel(id) else { return false }
        maximizedPanel = nil
        let target = frame ?? tileScreenRect(for: id) ?? fallbackPopoutRect(for: id)
        panelLayout.removePanel(id)
        panelLayout.normalize()
        poppedOutPanels[id] = SZPoppedOutPanel(panel: id, x: target.origin.x, y: target.origin.y,
                                               width: target.width, height: target.height)
        popoutManager.openPopout(id: id, frame: target)
        persistAppState()
        syncViewportDriver()
        return true
    }

    /// A tile's header dragged OUT of the main window and released (the container's tear-out):
    /// pop it out right where the drag let go — the window materializes under the cursor, its
    /// strip (the drag handle) on the release point, keeping the tile's size.
    func tearOutPanel(_ id: SZPanelID) {
        guard canPopOutPanel(id) else { return }
        let size = tileScreenRect(for: id)?.size ?? fallbackPopoutRect(for: id).size
        let cursor = NSEvent.mouseLocation
        let frame = NSRect(x: cursor.x - size.width / 2,
                           y: cursor.y - size.height + SZPopoutPanelShellMetrics.headerHeight / 2,
                           width: size.width, height: size.height)
        popOutPanel(id, frame: frame)
    }

    /// Dock a popped-out panel back at its remembered spot (the dock-back button's commit, the ✕
    /// dock-back, `ui_dock_panel` without a target). `insertPanel` rides the restore record that
    /// `removePanel` wrote on the way out.
    func dockPanel(_ id: SZPanelID) {
        dock(id) { panelLayout.insertPanel(id) }
    }

    /// Dock a popped-out panel at an EXPLICIT spot (the drag-to-dock commit): the drop zone
    /// overrides the remembered position.
    func dockPanel(_ id: SZPanelID, onto target: SZPanelID, zone: SZPanelDropZone) {
        dock(id) {
            panelLayout.insertPanel(id, onto: target, zone: zone)
            // The target can vanish between candidate and commit (an MCP close racing the dock
            // flight): the explicit insert no-ops then, and a panel that is in NEITHER the tree
            // NOR a window would simply cease to exist — fall back to the remembered spot.
            if !panelLayout.contains(id) { panelLayout.insertPanel(id) }
        }
    }

    /// The shared dock commit: drop the window + record, land the panel via `insert`, settle.
    private func dock(_ id: SZPanelID, insert: () -> Void) {
        guard poppedOutPanels[id] != nil else { return }
        poppedOutPanels[id] = nil
        popoutManager.closePopout(id: id, reason: .docked)
        maximizedPanel = nil
        insert()
        panelLayout.normalize()
        persistAppState()
        syncViewportDriver()
    }

    /// Close a popped-out panel for REAL (View-menu toggle off / `ui_close_panel`): window gone,
    /// record gone — the panel is reopenable via showPanel, like any closed tile.
    func closePoppedOutPanel(_ id: SZPanelID) {
        guard poppedOutPanels[id] != nil else { return }
        poppedOutPanels[id] = nil
        popoutManager.closePopout(id: id, reason: .panelClosed)
        persistAppState()
        syncViewportDriver()
    }

    func isPoppedOut(_ id: SZPanelID) -> Bool { poppedOutPanels[id] != nil }

    /// A pop-out window moved or resized — keep the persisted frame current (relaunch restore).
    /// The in-memory record updates immediately; the disk write is debounced, because
    /// windowDidMove fires per mouse move during a drag and app-state writes are synchronous
    /// (the divider drag's persist-on-release spirit, adapted to a signal with no release event).
    func notePopoutFrameChanged(_ id: SZPanelID, frame: NSRect) {
        guard poppedOutPanels[id] != nil else { return }
        poppedOutPanels[id] = SZPoppedOutPanel(panel: id, x: frame.origin.x, y: frame.origin.y,
                                               width: frame.width, height: frame.height)
        popoutFramePersistDebounce?.cancel()
        popoutFramePersistDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.persistAppState()
        }
    }

    /// The welcome↔workspace edge (from the window manager): the workspace appearing is the
    /// relaunch-restore hook — re-open persisted pop-outs, frames sanitized against the current
    /// screens (a disconnected display must not strand a window off-screen). Also the driver
    /// re-sync point: pop-outs order out behind the welcome surface, so their viewports stop
    /// counting as visible.
    func workspaceActivationChanged(_ active: Bool) {
        if active { restorePersistedPopouts() }
        syncViewportDriver()
    }

    /// Re-open the pop-outs a previous session persisted. Runs once per record: openPopout is
    /// idempotent per id, and records whose panel is (somehow) also in the tree are dropped —
    /// the tree wins, normalize()'s duplicate rule backs this up. Every drop-the-record path
    /// also closes any live window for that id (this re-runs on each welcome↔workspace edge,
    /// when windows from earlier in the session may still exist — folding a panel into the tree
    /// while its window stays open would double it).
    private func restorePersistedPopouts() {
        for (id, record) in poppedOutPanels {
            guard !panelLayout.contains(id), Self.popoutAllowedKinds.contains(id.kind) else {
                poppedOutPanels[id] = nil
                popoutManager.closePopout(id: id, reason: .panelClosed)
                continue
            }
            let saved = CGRect(x: record.x, y: record.y, width: record.width, height: record.height)
            let minSize = SZPanelLayoutGeometry.minSize(for: id.kind)
            guard let frame = SZPopoutDockSession.sanitizedRestoreFrame(
                saved, visibleScreenFrames: NSScreen.screens.map(\.visibleFrame),
                minSize: minSize) else {
                // Corrupt/unplaceable record: fold the panel back into the layout instead of
                // silently losing it.
                poppedOutPanels[id] = nil
                popoutManager.closePopout(id: id, reason: .docked)
                panelLayout.insertPanel(id)
                panelLayout.normalize()
                continue
            }
            if frame != saved { notePopoutFrameChanged(id, frame: frame) }
            popoutManager.openPopout(id: id, frame: frame)
        }
    }

    /// Visible viewport instances → the driver registry, from the surfaces actually in a window (so a
    /// maximized-away or closed viewport can't be a ghost driver). Tiles count while the main window
    /// can show pixels, pop-outs while their window can (a hidden window's link suspends — it must
    /// not hold drivership). Called on every edge of either set, then pushed by `applyRenderDrive()`.
    func syncViewportDriver() {
        var tiles: Set<Int> = [], windows: Set<Int> = [], fullscreen: Set<Int> = []
        let mainWindow = popoutManager.mainWindow
        let mainShows = popoutManager.mainWindowIsDisplayable
        for surface in viewportSurfaces where surface.id.kind == .viewport {
            let id = surface.id
            // Pop-out surface: the id has a window and the view isn't in the main window (both
            // exist for one turn during a pop-out/dock transition).
            if popoutManager.poppedOutIDs.contains(id), surface.view?.window !== mainWindow {
                guard popoutManager.windowIsDisplayable(id) else { continue }
                windows.insert(id.instance)
                if popoutManager.windowIsFullscreen(id) { fullscreen.insert(id.instance) }
            } else if mainShows {
                tiles.insert(id.instance)
            }
        }
        viewportDriver.setVisible(tiles: tiles, windows: windows, fullscreen: fullscreen)
        applyRenderDrive()
        // Positional titles depend on the same live set — retitle pop-out windows on its edges.
        popoutManager.refreshTitles { panelTitle($0) }
    }

    /// The main window's visibility changed (occluded/miniaturized/restored): tiles and the node
    /// editor's thumbs — its only home — follow.
    func mainWindowVisibilityChanged() {
        syncViewportDriver()
        refreshPreviewStream()
    }

    // MARK: - Pop-out placement

    /// The tile's current rect in screen coordinates — where its pop-out window opens so the panel
    /// detaches in place.
    private func tileScreenRect(for id: SZPanelID) -> NSRect? {
        guard let window = popoutManager.mainWindow, let contentView = window.contentView else { return nil }
        let safeAreaTop = contentView.safeAreaInsets.top
        let usable = CGSize(width: contentView.bounds.width,
                            height: contentView.bounds.height - safeAreaTop)
        let frames = SZPopoutDockSession.tileFrames(layout: panelLayout, maximized: maximizedPanel,
                                                    containerSize: usable, topInset: 0)
        guard let rect = frames[id] else { return nil }
        let contentScreenFrame = window.convertToScreen(contentView.convert(contentView.bounds, to: nil))
        return SZPopoutDockSession.screenRect(forContainerRect: rect,
                                              contentScreenFrame: contentScreenFrame,
                                              safeAreaTop: safeAreaTop)
    }

    /// No main window to measure (headless MCP call before the window exists): a centered default.
    private func fallbackPopoutRect(for id: SZPanelID) -> NSRect {
        let size = NSSize(width: 640, height: 420)
        guard let screen = NSScreen.main?.visibleFrame else {
            return NSRect(origin: .zero, size: size)
        }
        return NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
