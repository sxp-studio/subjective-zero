// SPDX-License-Identifier: AGPL-3.0-only
// Panel-layout state ops — the host-owned intents behind the rearrangeable panel system (header
// drag & drop, divider resize, close/reopen), following the SZHost+Chat.swift sibling pattern.
// Every mutation ends in normalize() (the quick autolayout that clamps fractions and sanitizes the
// tree) and is persisted to app-state.json — except the live divider drag, which persists once on
// release instead of on every mouse move.
import Foundation
import SZCore

extension SZHost {
    /// The user-facing title for a panel: positional among its kind's LIVE instances (tiles +
    /// pop-out windows), so visible numbers stay dense — "Viewport" alone, "Viewport 1/2/3" in
    /// company — whatever identity gaps exist underneath (SZPanelID.displayTitles). Reads
    /// observable state, so SwiftUI surfaces re-title automatically; pop-out WINDOW titles are
    /// pushed by syncViewportDriver (same triggers: every live-set change).
    func panelTitle(_ id: SZPanelID) -> String {
        SZPanelID.displayTitles(for: panelLayout.root.leafIDs + poppedOutPanels.keys)[id]
            ?? id.displayName
    }

    /// Header maximize toggle: blow `id` up to fill the window (others hidden), or restore if it's
    /// already maximized. A pure render override — no tree mutation, so nothing to normalize or
    /// persist; restore returns the exact prior layout.
    func toggleMaximizePanel(_ id: SZPanelID) {
        maximizedPanel = (maximizedPanel == id) ? nil : id
    }

    /// Commit a header drag & drop: split `target` on an edge zone, or swap the two on `.center`.
    func movePanel(_ id: SZPanelID, onto target: SZPanelID, zone: SZPanelDropZone) {
        maximizedPanel = nil   // any structural edit exits maximize
        panelLayout.movePanel(id, onto: target, zone: zone)
        panelLayout.normalize()
        persistAppState()
    }

    /// Pin a panel to one side of the whole window (a header dropped on the window's border).
    func pinPanel(_ id: SZPanelID, to zone: SZPanelDropZone) {
        maximizedPanel = nil   // any structural edit exits maximize
        panelLayout.movePanel(id, toWindowEdge: zone)
        panelLayout.normalize()
        persistAppState()
    }

    /// Live divider drag — track the cursor without normalizing (min sizes clamp the pixels anyway)
    /// and without touching the disk.
    func setPanelDividerFraction(_ fraction: Double, at path: SZPanelNodePath) {
        panelLayout.setFraction(fraction, at: path)
    }

    /// Divider released — commit + persist the final fraction.
    func commitPanelDividerFraction(_ fraction: Double, at path: SZPanelNodePath) {
        panelLayout.setFraction(fraction, at: path)
        panelLayout.normalize()
        persistAppState()
    }

    /// Header ✕ (or a View-menu toggle off): collapse the panel's split, remembering its spot.
    /// A popped-out panel routes to the real close — window and record both go.
    func closePanel(_ id: SZPanelID) {
        if isPoppedOut(id) {
            closePoppedOutPanel(id)
            return
        }
        maximizedPanel = nil   // any structural edit exits maximize
        panelLayout.removePanel(id)
        panelLayout.normalize()
        persistAppState()
        syncViewportDriver()
    }

    /// Reopen a panel at its remembered spot (View menu, HUD chat icon, `ui_send_chat`…). Idempotent.
    /// A popped-out panel is already visible — "show" means dock it back, not grow a duplicate tile.
    func showPanel(_ id: SZPanelID) {
        if isPoppedOut(id) {
            dockPanel(id)
            return
        }
        maximizedPanel = nil   // any structural edit exits maximize
        panelLayout.insertPanel(id)
        panelLayout.normalize()
        persistAppState()
        syncViewportDriver()
    }

    /// Graph ▸ Snap to Grid — a live pref, persisted like every layout change.
    func setSnapToGrid(_ on: Bool) {
        snapToGrid = on
        persistAppState()
    }

    /// View ▸ Auto-Hide Panel Headers — a live pref, persisted like every layout change.
    func setAutoHidePanelHeaders(_ on: Bool) {
        autoHidePanelHeaders = on
        popoutManager.setAutoHideHeaders(on)
        persistAppState()
    }

    /// View ▸ Rounded Viewport Corners — a live pref, persisted like every layout change.
    func setViewportRoundedCorners(_ on: Bool) {
        viewportRoundedCorners = on
        persistAppState()
    }

    /// Graph ▸ Grid Cursor Trail — a live pref, persisted like every layout change.
    func setGridCursorTrail(_ on: Bool) {
        gridCursorTrail = on
        persistAppState()
    }

    /// Graph ▸ Mini Map — a live pref, persisted like every layout change.
    func setShowMiniMap(_ on: Bool) {
        showMiniMap = on
        persistAppState()
    }

    /// View ▸ Show Token Counts — a live pref, persisted like every layout change.
    func setShowTokenCounts(_ on: Bool) {
        showTokenCounts = on
        persistAppState()
    }

    /// Debug ▸ Show Turn Breakdown — a live pref, persisted like every layout change.
    func setShowTurnBreakdown(_ on: Bool) {
        showTurnBreakdown = on
        persistAppState()
    }

    /// Write the live prefs (layout + pop-outs + snap + header auto-hide + grid cursor trail +
    /// confirmed default provider + project history) to app-state.json (~1 KB, synchronous). The
    /// remaining SZAppState fields (windowSize/theme) are still dormant — nothing reads or writes
    /// them yet, so saving defaults for them loses nothing. Internal: SZHost+ProviderHealth
    /// persists the Confirm and SZHost+ProjectLifecycle the history through here too — ONE writer,
    /// so a layout save can never clobber the provider or history fields.
    func persistAppState() {
        do {
            try SZAppStateIO.save(SZAppState(openProjectPath: lastOpenProjectPath,
                                             panelLayout: panelLayout, snapToGrid: snapToGrid,
                                             livePreviews: livePreviews,
                                             autoHidePanelHeaders: autoHidePanelHeaders,
                                             gridCursorTrail: gridCursorTrail,
                                             showMiniMap: showMiniMap,
                                             viewportRoundedCorners: viewportRoundedCorners,
                                             defaultProviderID: defaultProviderID,
                                             disabledProviderIDs: disabledProviderIDs.isEmpty
                                                ? nil : disabledProviderIDs.sorted(),
                                             recentProjectPaths: recentProjectPaths.isEmpty ? nil : recentProjectPaths,
                                             providerGenerationSettings: providerGenerationSettings.isEmpty
                                                ? nil : providerGenerationSettings,
                                             showWelcomeAtStartup: showWelcomeAtStartup,
                                             showTokenCounts: showTokenCounts,
                                             telemetryEnabled: telemetryEnabled,
                                             showTurnBreakdown: showTurnBreakdown,
                                             poppedOutPanels: poppedOutPanels.isEmpty
                                                ? nil : poppedOutPanels.values.sorted { $0.panel < $1.panel },
                                             routingProfiles: routingProfiles.isEmpty
                                                ? nil : routingProfiles,
                                             activeRoutingProfileName: activeRoutingProfileName,
                                             routingSeededStarterNames: routingSeededStarterNames.isEmpty
                                                ? nil : routingSeededStarterNames,
                                             routingLastProfileName: routingLastProfileName))
        } catch {
            print("[SZHost] app-state save failed: \(error)")   // a pref, not project data — log & move on
        }
    }
}
