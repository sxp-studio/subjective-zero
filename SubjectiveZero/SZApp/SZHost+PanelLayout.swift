// SPDX-License-Identifier: AGPL-3.0-only
// Panel-layout state ops — the host-owned intents behind the rearrangeable panel system (header
// drag & drop, divider resize, close/reopen), following the SZHost+Chat.swift sibling pattern.
// Every mutation ends in normalize() (the quick autolayout that clamps fractions and sanitizes the
// tree) and is persisted to app-state.json — except the live divider drag, which persists once on
// release instead of on every mouse move.
import Foundation
import SZCore

extension SZHost {
    /// Header maximize toggle: blow `kind` up to fill the window (others hidden), or restore if it's
    /// already maximized. A pure render override — no tree mutation, so nothing to normalize or
    /// persist; restore returns the exact prior layout.
    func toggleMaximizePanel(_ kind: SZPanelKind) {
        maximizedPanel = (maximizedPanel == kind) ? nil : kind
    }

    /// Commit a header drag & drop: split `target` on an edge zone, or swap the two on `.center`.
    func movePanel(_ kind: SZPanelKind, onto target: SZPanelKind, zone: SZPanelDropZone) {
        maximizedPanel = nil   // any structural edit exits maximize
        panelLayout.movePanel(kind, onto: target, zone: zone)
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
    func closePanel(_ kind: SZPanelKind) {
        maximizedPanel = nil   // any structural edit exits maximize
        panelLayout.removePanel(kind)
        panelLayout.normalize()
        persistAppState()
    }

    /// Reopen a panel at its remembered spot (View menu, HUD chat icon, `ui_send_chat`…). Idempotent.
    func showPanel(_ kind: SZPanelKind) {
        maximizedPanel = nil   // any structural edit exits maximize
        panelLayout.insertPanel(kind)
        panelLayout.normalize()
        persistAppState()
    }

    /// Graph ▸ Snap to Grid — a live pref, persisted like every layout change.
    func setSnapToGrid(_ on: Bool) {
        snapToGrid = on
        persistAppState()
    }

    /// View ▸ Auto-Hide Panel Headers — a live pref, persisted like every layout change.
    func setAutoHidePanelHeaders(_ on: Bool) {
        autoHidePanelHeaders = on
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

    /// View ▸ Show Token Counts — a live pref, persisted like every layout change.
    func setShowTokenCounts(_ on: Bool) {
        showTokenCounts = on
        persistAppState()
    }

    /// Write the live prefs (layout + snap + header auto-hide + grid cursor trail + confirmed default
    /// provider + project history) to app-state.json (~1 KB, synchronous). The remaining SZAppState fields
    /// (windowSize/theme) are still dormant — nothing reads or writes them yet, so saving defaults
    /// for them loses nothing. Internal: SZHost+ProviderHealth persists the Confirm and
    /// SZHost+ProjectLifecycle the history through here too — ONE writer, so a layout save can
    /// never clobber the provider or history fields.
    func persistAppState() {
        do {
            try SZAppStateIO.save(SZAppState(openProjectPath: lastOpenProjectPath,
                                             panelLayout: panelLayout, snapToGrid: snapToGrid,
                                             autoHidePanelHeaders: autoHidePanelHeaders,
                                             gridCursorTrail: gridCursorTrail,
                                             viewportRoundedCorners: viewportRoundedCorners,
                                             defaultProviderID: defaultProviderID,
                                             recentProjectPaths: recentProjectPaths.isEmpty ? nil : recentProjectPaths,
                                             providerGenerationSettings: providerGenerationSettings.isEmpty
                                                ? nil : providerGenerationSettings,
                                             showWelcomeAtStartup: showWelcomeAtStartup,
                                             showTokenCounts: showTokenCounts))
        } catch {
            print("[SZHost] app-state save failed: \(error)")   // a pref, not project data — log & move on
        }
    }
}
