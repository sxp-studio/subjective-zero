// SPDX-License-Identifier: AGPL-3.0-only
// The node-editor panel — the human-facing canvas. It observes the injected @Observable SZStore
// and renders the live graph: node cards (positioned at node.position, the card center) over the
// connection layer, inside a pannable/zoomable canvas, with a HUD bar (Run · chat · ＋node · delete)
// along the bottom (provider selection lives in the chat composer's generation picker).
// Bottom pane of the app's VSplitView; the chat panel docks beside the combo.
//
// Navigation: trackpad pinch / ⌘+scroll zoom pivoted on the cursor (clamped),
// two-finger-scroll / mouse-wheel pan (suppressed while a prompt field is focused). Node drag commits
// through store.moveNode; tap selects; the ＋ button adds a prompt node; editing a prompt commits via
// store.updateNode; Run calls the host (injected onRun). All edits route through the shared SZStore ops.
import AppKit
import SwiftUI
import SZCore
import UniformTypeIdentifiers

/// A one-shot node-editor camera command raised by the host (Graph ▸ Center View / Zoom to Fit) and
/// applied by the panel, which owns the actual zoom/offset. `token` is fresh per issue so re-selecting
/// the same item re-fires the panel's `.onChange` even though `action` is unchanged.
public enum SZCameraAction: Equatable, Sendable { case center, fit }
public struct SZCameraCommand: Equatable, Sendable {
    public let action: SZCameraAction
    public let token: UUID
    public init(action: SZCameraAction, token: UUID = UUID()) { self.action = action; self.token = token }
}

public struct SZNodeEditorPanel: View {
    private let store: SZStore
    private let project: SZProject?
    private let status: String
    private let isRunning: Bool
    private let isPaused: Bool                     // HUD Pause/Play toggle state (owned by SZHost)
    private let nodeAgentState: [SZNodeID: SZNodeAgentState]   // typed per-node agent state (pill / lock / error popover)
    private let graphOpStatus: [SZNodeID: String]   // original node id → "Splitting"/"Merging"
    private let runWorkSet: Set<SZNodeID>   // the run's captured work (host-owned) — members lock + read Coding
    private let hiddenPieces: Set<SZNodeID>          // staged split/merge pieces hidden until commit
    private let chatShown: Bool                   // for the HUD icon state; chat/tab state is owned by SZApp
    private let agentsWorking: Bool               // any run/turn in flight → the closed-panel chat-toggle dot
    private let pendingWorkHint: Bool             // pending nodes, no run, Director not mid-decompose → the Build button shows + pulses
    private let pendingNodeCount: Int             // pending prompt nodes → the Build button's count badge
    private let snapToGrid: Bool                  // host-owned pref (Graph menu); grid dots draw regardless
    private let gridCursorTrail: Bool             // host-owned pref (Graph menu); dots morph to glyphs near the cursor
    private let cameraCommand: SZCameraCommand?   // host-raised one-shot: Center View / Zoom to Fit
    private let onOpenNodeChat: (SZNodeID) -> Void   // context menu "Open Transcript" → the node's chat tab
    private let onOpenNodeSource: (SZNodeID) -> Void  // a node's file button → open its Node.swift in the editor
    private let onFixNode: (SZNodeID) -> Void         // Outdated/Error pill → compose a rebuild request
    private let onToggleDirectorChat: () -> Void     // HUD message icon → Director Agent chat
    private let onBuild: () -> Void                  // HUD Build button → host.startRun() (headless whole-graph run)
    private let onStopRun: () -> Void                // HUD Build button while running → cancel the run
    private let onTogglePause: () -> Void            // HUD Pause/Play → host.togglePlayback()
    private let onResetTime: () -> Void              // HUD Reset Time (rewind) → host.resetPlayback()
    private let onSetInputDefault: (SZNodeID, String, SZPortValue, Bool) -> Void  // node input control → host
    private let onToggleDisplay: (SZNodeID, String) -> Void   // texture output monitor icon → ui_toggle_display
    private let optionsFor: (SZNodeID, String) -> [SZEnumOption]   // effective enum options (dynamic ?? static)
    // The right-click message-suggestion menu (run-UX paradigm): the HOST derives the drafted
    // messages for a target; picking one (or free text) routes back for composer injection.
    private let contextSuggestionsFor: (SZCanvasContextTarget) -> [SZContextSuggestion]
    private let onPickContextSuggestion: (SZContextSuggestion) -> Void
    private let onContextFreeText: (SZCanvasContextTarget, String) -> Void
    private let onDeleteNodes: ([SZNodeID]) -> Void       // ⌫ / trash → host (batch: one persist+reload)
    private let onDeleteConnection: (SZConnectionID) -> Void   // ⌫ on a selected wire → host (persists)
    private let onConnect: (SZPortRef, SZPortRef, SZConnectionKind) -> Void   // wire-drag drop → host (persists)
    private let onReconnectConnection: (SZConnectionID, SZConnectionEnd, SZPortRef) -> Void   // picked-up wire re-drop → host (persists)
    // Files dropped on the canvas → create media library nodes (video-file / image-file) with `path`
    // pre-set. The panel classifies + converts the drop point to graph space; the host instantiates.
    private let onCreateMediaNodes: ([(libraryID: String, path: String, position: SZPoint)]) -> Void
    // The HUD gear menu's CONTENT (Project/View/Graph commands, AI Providers…, community links). Built
    // by the host (SZApp) where `host` + the app-bundle Discord asset are in scope, injected as an
    // erased view — the panel just renders it inside a HUD-styled Menu. Empty by default (previews/tests).
    private let gearMenu: AnyView

    @State private var camera = SZCanvasCamera()   // zoom + pan offset + the screen↔world transforms
    @State private var pinchAnchor: SZCanvasCamera?   // camera at pinch start — the zoom-about-pivot base
    @State private var chatToggleHover = false   // HUD chat-toggle hover highlight
    @State private var cursor: CGPoint?
    @State private var viewSize: CGSize = .zero
    @Binding private var selectedNodeID: SZNodeID?   // hoisted so the chat panel scopes to the selection
    @State private var multiSelection: Set<SZNodeID> = []   // marquee / shift-click set, for Merge
    @State private var marquee: (start: CGPoint, current: CGPoint)?   // rubber-band rect, panel space
    @State private var selectedConnectionID: SZConnectionID?
    @State private var editingNodeID: SZNodeID?
    @State private var autoEditNodeID: SZNodeID?   // a just-added prompt node → its card opens straight into editing
    @State private var drag: NodeDrag?
    @State private var wire: SZWireDragSession?
    @State private var autoPan = SZEdgeAutoPanDriver()   // edge auto-pan while a node/wire drag is held
    @State private var panEdges = SZEdgeAutoPan.Intensities()   // drives the edge indicator bands
    @FocusState private var canvasFocused: Bool
    @State private var contextMenu: SZContextMenuSession?
    @State private var contextMenuSize: CGSize = .zero   // measured; .zero = first frame, drawn invisible
    @State private var dropTargeted = false   // a file drag is hovering the canvas (drop-target highlight)

    private struct NodeDrag {
        let primary: SZNodeID                              // the grabbed node (selection anchor)
        let members: [(id: SZNodeID, start: CGPoint)]      // all nodes moving + their start positions
        var translation: CGSize = .zero                    // gesture translation, screen (szcanvas) space
        var panAccum: CGSize = .zero                       // Σ auto-pan camera-offset deltas this drag
    }

    private static let space = "szcanvas"

    /// `project` is the live graph to render, passed (and observed) by the host so the panel re-renders
    /// on every graph change — including agent promotes during a run. `store` is kept for edits.
    public init(store: SZStore, project: SZProject?, status: String, isRunning: Bool,
                isPaused: Bool = false,
                nodeAgentState: [SZNodeID: SZNodeAgentState] = [:],
                graphOpStatus: [SZNodeID: String] = [:], runWorkSet: Set<SZNodeID> = [], hiddenPieces: Set<SZNodeID> = [],
                chatShown: Bool,
                agentsWorking: Bool = false,
                pendingWorkHint: Bool = false,
                pendingNodeCount: Int = 0,
                snapToGrid: Bool = true,
                gridCursorTrail: Bool = true,
                cameraCommand: SZCameraCommand? = nil,
                selectedNodeID: Binding<SZNodeID?>,
                onOpenNodeChat: @escaping (SZNodeID) -> Void,
                onOpenNodeSource: @escaping (SZNodeID) -> Void = { _ in },
                onFixNode: @escaping (SZNodeID) -> Void = { _ in },
                onToggleDirectorChat: @escaping () -> Void,
                onBuild: @escaping () -> Void = {},
                onStopRun: @escaping () -> Void = {},
                onTogglePause: @escaping () -> Void = {},
                onResetTime: @escaping () -> Void = {},
                onSetInputDefault: @escaping (SZNodeID, String, SZPortValue, Bool) -> Void,
                onToggleDisplay: @escaping (SZNodeID, String) -> Void = { _, _ in },
                optionsFor: @escaping (SZNodeID, String) -> [SZEnumOption] = { _, _ in [] },
                onDeleteNodes: @escaping ([SZNodeID]) -> Void = { _ in },
                onDeleteConnection: @escaping (SZConnectionID) -> Void = { _ in },
                onConnect: @escaping (SZPortRef, SZPortRef, SZConnectionKind) -> Void = { _, _, _ in },
                onReconnectConnection: @escaping (SZConnectionID, SZConnectionEnd, SZPortRef) -> Void = { _, _, _ in },
                contextSuggestionsFor: @escaping (SZCanvasContextTarget) -> [SZContextSuggestion] = { _ in [] },
                onPickContextSuggestion: @escaping (SZContextSuggestion) -> Void = { _ in },
                onContextFreeText: @escaping (SZCanvasContextTarget, String) -> Void = { _, _ in },
                onCreateMediaNodes: @escaping ([(libraryID: String, path: String, position: SZPoint)]) -> Void = { _ in },
                gearMenu: AnyView = AnyView(EmptyView())) {
        self.store = store
        self.project = project
        self.status = status
        self.isRunning = isRunning
        self.isPaused = isPaused
        self.nodeAgentState = nodeAgentState
        self.graphOpStatus = graphOpStatus
        self.runWorkSet = runWorkSet
        self.hiddenPieces = hiddenPieces
        self.chatShown = chatShown
        self.agentsWorking = agentsWorking
        self.pendingWorkHint = pendingWorkHint
        self.pendingNodeCount = pendingNodeCount
        self.snapToGrid = snapToGrid
        self.gridCursorTrail = gridCursorTrail
        self.cameraCommand = cameraCommand
        self._selectedNodeID = selectedNodeID
        self.onOpenNodeChat = onOpenNodeChat
        self.onOpenNodeSource = onOpenNodeSource
        self.onFixNode = onFixNode
        self.onToggleDirectorChat = onToggleDirectorChat
        self.onBuild = onBuild
        self.onStopRun = onStopRun
        self.onTogglePause = onTogglePause
        self.onResetTime = onResetTime
        self.onSetInputDefault = onSetInputDefault
        self.onToggleDisplay = onToggleDisplay
        self.optionsFor = optionsFor
        self.onDeleteNodes = onDeleteNodes
        self.onDeleteConnection = onDeleteConnection
        self.onConnect = onConnect
        self.onReconnectConnection = onReconnectConnection
        self.contextSuggestionsFor = contextSuggestionsFor
        self.onPickContextSuggestion = onPickContextSuggestion
        self.onContextFreeText = onContextFreeText
        self.onCreateMediaNodes = onCreateMediaNodes
        self.gearMenu = gearMenu
    }

    /// Whether an agent currently owns this node (can't edit/delete/wire it) — the shared rule lives on
    /// SZNodeCanvasContentView (single source for content rendering, the drag-ghost overlay, and these
    /// gesture guards).
    private func isLocked(_ id: SZNodeID) -> Bool {
        SZNodeCanvasContentView.isLocked(id, agentState: nodeAgentState, ops: graphOpStatus,
                                         isRunning: isRunning, graph: project?.graph, workSet: runWorkSet)
    }

    public var body: some View {
        canvasArea
            .overlay(alignment: .bottom) { hudBar.padding(.bottom, 16) }
            // Declared AFTER the HUD → the menu always draws above it (and everything else).
            .overlay(alignment: .topLeading) { contextMenuOverlay }
            // A deleted target (agent promote/merge mid-run) closes the menu rather than leaving
            // rows pointing at a ghost.
            .onChange(of: project?.graph.nodes.map(\.id)) { validateContextMenuTarget() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                dismissContextMenu()
            }
    }

    private var canvasArea: some View {
        let graph = project?.graph
        autoPan.onTick = { autoPanTick($0) }   // idempotent per render, like the scroll monitor's onScroll
        return GeometryReader { proxy in
            ZStack {
                SZDotGridView.canvasBackground
                    .contentShape(Rectangle())
                    .onTapGesture { clearSelection() }
                    // Double-click empty canvas = add a prompt node here (the classic gesture). The
                    // context menu is right-click / ctrl-click / two-finger only; "Add Node Here"
                    // is also in that menu for a precise add.
                    .gesture(SpatialTapGesture(count: 2, coordinateSpace: .named(Self.space))
                        .onEnded { addPromptNode(atScreen: $0.location) })
                    .gesture(marqueeGesture)
                SZDotGridView(zoom: camera.zoom, offset: camera.offset)
                    .allowsHitTesting(false)   // decorative — the Color above keeps tap/marquee gestures
                if gridCursorTrail {
                    SZGridCursorTrailView(cursor: cursor, zoom: camera.zoom, offset: camera.offset)
                        .allowsHitTesting(false)   // decorative overlay; idle-dormant (see the view's header)
                }
                if let graph {
                    // World-space layers under ONE camera transform. The content is camera-independent
                    // and `.equatable()` (see SZNodeCanvasContentView) — pan/zoom ticks only move this
                    // transform; drag/wire ticks only update the lightweight overlay layers above it.
                    ZStack(alignment: .topLeading) {
                        canvasContent(contentGraph(graph))
                        selectedConnectionHighlight(graph)
                        dragOverlay
                        if let wire { wireTargetsOverlay(wire); wirePreview(wire) }
                    }
                    .scaleEffect(camera.zoom, anchor: .topLeading)
                    .offset(camera.offset)
                } else {
                    Text("No project loaded")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                marqueeOverlay   // rubber-band selection rect (panel space, drawn over the canvas)
                SZEdgePanIndicatorView(edges: panEdges)
            }
            .coordinateSpace(name: Self.space)
            // Right-click / ctrl-click / two-finger tap → the message-suggestion menu. A local
            // NSEvent monitor (SwiftUI has no right-click gesture); its NSView frame == this space.
            .background(SZCanvasRightClickCatcher(onMouseDown: handleCanvasMouseDown))
            // Drop a video/image file → auto-create a video-file / image-file node under the cursor with
            // its `path` pre-set. Whole-area catcher (same "szcanvas" frame, so its top-left drop point
            // matches the double-tap gesture's screen point); non-media files are ignored (not consumed).
            .background(SZFileDropCatcher(onDrop: handleFileDrop, onTargeted: { dropTargeted = $0 }))
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                switch phase {
                case .active(let p): cursor = p
                case .ended: cursor = nil
                }
            }
            .simultaneousGesture(zoomGesture)
            .monitorCanvasScrollWheel { handleScroll($0) }
            // Delete / Backspace removes the selected node or connection. The canvas holds keyboard
            // focus (set on appear + on every selection below); a focused prompt TextField captures
            // the key instead, so editing prompts is unaffected.
            .focusable()
            .focusEffectDisabled()
            .focused($canvasFocused)
            .onDeleteCommand { deleteSelected() }
            .onKeyPress(.delete) { deleteSelected(); return .handled }
            .onKeyPress(.deleteForward) { deleteSelected(); return .handled }
            .onAppear { viewSize = proxy.size; canvasFocused = true }
            .onChange(of: proxy.size) { _, size in viewSize = size }
            // Host-raised camera commands (Graph ▸ Center View / Zoom to Fit) — the fresh token per
            // issue makes a repeat press re-fire even when the action is unchanged.
            .onChange(of: cameraCommand) { _, command in
                if let command { applyCameraCommand(command) }
            }
            .onDisappear { stopAutoPan() }
        }
    }

    // A floating glass control bar. The conversation group leads — the Build button (whole-graph run,
    // shown only when there's pending work or a run is in flight) sits next to the chat toggle, then a
    // divider fences them off from the canvas tools (add · delete): [Build][chat] | [＋][trash]. Stop is
    // offered here AND in the composer, so a run can be halted from either place. While agents work with
    // the panel CLOSED, the chat toggle carries a small working dot so the canvas is never signal-blind.
    private var hudBar: some View {
        HStack(spacing: 8) {
            buildButton
            chatToggleButton
            RoundedRectangle(cornerRadius: 0.5)
                .fill(.white.opacity(0.16))
                .frame(width: 1, height: 20)
            SZHudIconButton(name: "plus", help: "Add prompt node") { addPromptNode() }
            SZHudIconButton(name: "trash", help: "Delete selected", enabled: canDeleteSelection) { deleteSelected() }
            RoundedRectangle(cornerRadius: 0.5)
                .fill(.white.opacity(0.16))
                .frame(width: 1, height: 20)          // divider before the playback controls
            SZHudIconButton(name: isPaused ? "play.fill" : "pause.fill",
                            help: isPaused ? "Play" : "Pause") { onTogglePause() }
            SZHudIconButton(name: "backward.end.fill", help: "Reset time") { onResetTime() }
            RoundedRectangle(cornerRadius: 0.5)
                .fill(.white.opacity(0.16))
                .frame(width: 1, height: 20)          // divider before the settings gear
            SZHudMenuButton(name: "gearshape", help: "Settings") { gearMenu }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .animation(.spring(response: 0.34, dampingFraction: 0.72), value: showBuildSegment)
    }

    /// Show the run button when there's kickable work (pending nodes, no run, Director not
    /// mid-decompose — that's `pendingWorkHint`) or a run is already in flight (then it's the Stop).
    private var showBuildSegment: Bool { pendingWorkHint || isRunning }

    /// The whole-graph run control, present only while `showBuildSegment`. It grows/collapses beside the
    /// chat toggle — the `.animation` on `hudBar` drives the scale-from-the-chat-side + fade transition.
    @ViewBuilder
    private var buildButton: some View {
        if showBuildSegment {
            SZHudBuildButton(isRunning: isRunning, pendingCount: pendingNodeCount,
                             pulse: pendingWorkHint, onBuild: onBuild, onStop: onStopRun)
                .transition(.scale(scale: 0.55, anchor: .trailing).combined(with: .opacity))
        }
    }

    /// The chat toggle — opens/closes the Director Agent chat. The "there's work to kick off" cue now
    /// lives on the Build button, so this is a plain toggle; an orange dot still marks agents working
    /// while the panel is closed.
    private var chatToggleButton: some View {
        Button { onToggleDirectorChat() } label: {
            Image(systemName: chatShown ? "message.fill" : "message")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(chatToggleHover ? 0.14 : 0.06)))
        }
        .buttonStyle(.plain)
        .trackingHover($chatToggleHover)
        .help("Director Agent chat")
        .overlay(alignment: .topTrailing) {
            if agentsWorking, !chatShown { chatToggleDot(Color.orange) }
        }
    }

    /// The chat toggle's small status dot — agents working while the panel is closed.
    private func chatToggleDot(_ color: Color) -> some View {
        TimelineView(.animation) { context in
            let phase = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 4)
            Circle().fill(color)
                .frame(width: 6, height: 6)
                .opacity(0.4 + 0.55 * phase)
        }
        .offset(x: -3, y: 3)
        .allowsHitTesting(false)
    }

    private func deleteSelected() {
        if let id = selectedConnectionID {
            // Can't unwire a locked (agent-owned) node — same rule as wiring one (`wireDrag`).
            if let c = project?.graph.connections.first(where: { $0.id == id }),
               isLocked(c.from.node) || isLocked(c.to.node) { return }
            onDeleteConnection(id)   // through the host: persists + reloads (a real delete)
            selectedConnectionID = nil
        } else if !selectedNodeIDs.isEmpty {
            // Through the host, as ONE batch: node removal + chat-artifact purge + a single
            // persist/reload for the whole selection.
            onDeleteNodes(selectedNodeIDs.filter { !isLocked($0) })   // can't delete mid-implementation
            selectedNodeID = nil
            multiSelection = []
        }
    }

    /// The node(s) under selection — the marquee/shift-click set, or the lone single selection. A marquee
    /// drag clears `selectedNodeID` and fills `multiSelection`, so deletion must consider both.
    private var selectedNodeIDs: Set<SZNodeID> {
        var ids = multiSelection
        if let id = selectedNodeID { ids.insert(id) }
        return ids
    }

    private var hasSelection: Bool { !selectedNodeIDs.isEmpty || selectedConnectionID != nil }

    /// Whether the current selection has anything the user is actually allowed to delete right now — mirrors
    /// `deleteSelected`'s own guards so the HUD trash button dims (rather than silently no-opping) when the
    /// whole selection is locked mid-run: a connection is deletable only if neither endpoint is locked; a
    /// node selection is deletable only if at least one selected node is unlocked.
    private var canDeleteSelection: Bool {
        if let id = selectedConnectionID {
            guard let c = project?.graph.connections.first(where: { $0.id == id }) else { return false }
            return !isLocked(c.from.node) && !isLocked(c.to.node)
        }
        return selectedNodeIDs.contains { !isLocked($0) }
    }

    /// Whether a node card is drawn selected (the primary single selection OR a member of the multi-set).
    private func isSelected(_ id: SZNodeID) -> Bool { selectedNodeID == id || multiSelection.contains(id) }

    /// Render tier of a node: the primary (chat/edit target) selection rides above the multi-selection,
    /// which rides above the rest — so the card being inspected is readable even when several selected
    /// cards overlap. Shared verbatim by the canvas zIndex AND occlusion hit-testing (isOccluded), so
    /// what you see is what you can hit.
    private func zTier(_ id: SZNodeID) -> Int {
        if selectedNodeID == id { return 2 }
        if multiSelection.contains(id) { return 1 }
        return 0
    }

    /// The non-zero tiers as a lookup for SZGraphCanvasModel.isOccluded.
    private var raisedTiers: [SZNodeID: Int] {
        var tiers: [SZNodeID: Int] = [:]
        for id in multiSelection { tiers[id] = 1 }
        if let id = selectedNodeID { tiers[id] = 2 }
        return tiers
    }

    /// Tap-select a node. Shift-click toggles it in the multi-selection (for Merge); a plain click selects
    /// just it. `selectedNodeID` (the chat/edit target) tracks the most-recently-touched node.
    private func selectNode(_ id: SZNodeID, additive: Bool) {
        if additive {
            if multiSelection.contains(id) {
                multiSelection.remove(id)
                if selectedNodeID == id { selectedNodeID = multiSelection.first }
            } else {
                multiSelection.insert(id)
                selectedNodeID = id
            }
        } else {
            selectedNodeID = id
            multiSelection = [id]
        }
        selectedConnectionID = nil
        canvasFocused = true
    }

    private func clearSelection() {
        selectedNodeID = nil
        multiSelection = []
        selectedConnectionID = nil
        canvasFocused = true
    }

    // MARK: - Context menu (right-click = "what can I say here")

    /// Every window mouse-down routes through here (see SZCanvasRightClickCatcher). Returning true
    /// swallows the event. Ordering matters: an open menu handles the click FIRST (row clicks pass
    /// through to SwiftUI; anything else dismisses — a left click still lands where it fell,
    /// standard custom-popover behavior), then a fresh secondary click on the canvas opens a menu.
    private func handleCanvasMouseDown(_ point: CGPoint, isSecondary: Bool, inCanvas: Bool) -> Bool {
        if let session = contextMenu {
            if session.frame(menuSize: contextMenuSize, in: viewSize).contains(point),
               !isSecondary { return false }   // a row click passes through
            dismissContextMenu()
            guard isSecondary else { return false }
        }
        guard isSecondary, inCanvas, project?.graph != nil else { return false }
        guard drag == nil, wire == nil, marquee == nil else { return false }   // not during a live drag
        openContextMenu(at: point)
        return true
    }

    /// The topmost node card under a canvas point (render z-order: tier, then declaration order,
    /// mirroring `isOccluded`'s what-you-see-is-what-you-hit rule), or nil for empty canvas.
    private func nodeHit(at point: CGPoint) -> SZNode? {
        guard let graph = project?.graph else { return nil }
        return SZGraphCanvasModel.topmostNode(at: camera.worldPoint(screen: point),
                                              in: contentGraph(graph), tiers: raisedTiers)
    }

    /// Open the menu at a canvas point: hit-test, update the selection FIRST (an unselected node
    /// gets selected; a click on a multi-selection member keeps the set), then snapshot the host's
    /// suggestions for the target.
    private func openContextMenu(at point: CGPoint) {
        guard project?.graph != nil else { return }
        let target: SZCanvasContextTarget
        if let node = nodeHit(at: point) {
            if multiSelection.count > 1, multiSelection.contains(node.id) {
                target = .selection(multiSelection)
            } else {
                selectNode(node.id, additive: false)
                target = .node(node.id)
            }
        } else {
            target = .canvas
        }
        presentContextMenu(target: target, anchor: point)
    }

    /// The card's "⋯" button — open THIS node's menu, anchored at the card's top-right (world →
    /// screen), so the ⋯ is a discoverable entry to the same actions as right-click.
    private func openNodeMenu(_ id: SZNodeID) {
        guard let node = project?.graph.node(id: id) else { return }
        let card = SZNodeLayout.cardRect(of: node)
        let anchor = camera.screenPoint(world: CGPoint(x: card.maxX, y: card.minY))
        selectNode(id, additive: false)
        presentContextMenu(target: .node(id), anchor: anchor)
    }

    private func presentContextMenu(target: SZCanvasContextTarget, anchor: CGPoint) {
        contextMenuSize = .zero   // re-measure; the menu stays invisible until it has a size
        contextMenu = SZContextMenuSession(target: target, anchor: anchor,
                                           suggestions: contextSuggestionsFor(target))
    }

    private func dismissContextMenu() {
        guard contextMenu != nil else { return }
        contextMenu = nil
        canvasFocused = true   // the menu held focus while open
    }

    private func validateContextMenuTarget() {
        guard let session = contextMenu, let graph = project?.graph else { return }
        let present = Set(graph.nodes.map(\.id))
        let valid = switch session.target {
        case .node(let id): present.contains(id)
        case .selection(let ids): ids.isSubset(of: present)
        case .canvas: true
        }
        if !valid { dismissContextMenu() }
    }

    @ViewBuilder
    private var contextMenuOverlay: some View {
        if let session = contextMenu {
            let origin = session.origin(menuSize: contextMenuSize, in: viewSize)
            SZCanvasContextMenuView(
                suggestions: session.suggestions,
                actions: contextActions(for: session.target),
                freeTextPlaceholder: freeTextPlaceholder(for: session.target),
                onPickSuggestion: { suggestion in
                    dismissContextMenu()
                    onPickContextSuggestion(suggestion)
                },
                onFreeText: { text in
                    dismissContextMenu()
                    onContextFreeText(session.target, text)
                },
                onPickAction: { handleContextAction($0) },
                onDismiss: { dismissContextMenu() })
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { contextMenuSize = $0 }
                .offset(x: origin.x, y: origin.y)
                .opacity(contextMenuSize == .zero ? 0 : 1)   // no first-frame flash at the wrong spot
                .id(session.id)
        }
    }

    /// The direct-action rows (below the message rows): read a node's transcript + open its
    /// Node.swift (generated only), or add a node at the click point (empty canvas).
    private func contextActions(for target: SZCanvasContextTarget) -> [SZContextAction] {
        switch target {
        case .node(let id):
            guard let node = project?.graph.node(id: id) else { return [] }
            var actions = [SZContextAction(kind: .openTranscript(id), label: "Open Transcript",
                                           sfSymbol: "text.quote")]
            if node.kind == .generated {
                actions.append(SZContextAction(kind: .openSource(id), label: "Open Node.swift",
                                               sfSymbol: "doc.text"))
            }
            return actions
        case .canvas:
            // The direct add-node action — the successor to double-click-adds-a-node (now the
            // double-click opens this menu).
            return [SZContextAction(kind: .addNode, label: "Add Node Here", sfSymbol: "plus.square")]
        case .selection:
            return []
        }
    }

    private func handleContextAction(_ action: SZContextAction) {
        let anchor = contextMenu?.anchor   // read before dismiss nils the session
        dismissContextMenu()
        switch action.kind {
        case .openTranscript(let id): onOpenNodeChat(id)
        case .openSource(let id): onOpenNodeSource(id)
        case .addNode: if let anchor { addPromptNode(atScreen: anchor) }
        }
    }

    private func freeTextPlaceholder(for target: SZCanvasContextTarget) -> String {
        switch target {
        case .node(let id):
            let title = project?.graph.node(id: id)?.title
            return "Message @\(title?.isEmpty == false ? title! : "node")…"
        case .selection, .canvas:
            return "Message @project…"
        }
    }

    // MARK: - Marquee (rubber-band multi-select)

    /// Drag on empty canvas → rubber-band select. The rect is tracked in PANEL space (so it draws under
    /// the cursor at any zoom), but membership is tested in WORLD space — `worldPoint` divides out the
    /// zoom + pan, so the same nodes are caught whether you're zoomed in or out.
    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                marquee = (start: value.startLocation, current: value.location)
                cursor = value.location   // marquee drag suppresses onContinuousHover; keep the trail following
                updateMarqueeSelection()
                canvasFocused = true
            }
            .onEnded { _ in marquee = nil }
    }

    private func updateMarqueeSelection() {
        guard let marquee, let nodes = project?.graph.nodes else { return }
        let a = camera.worldPoint(screen: marquee.start)
        let b = camera.worldPoint(screen: marquee.current)
        let world = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        // Select a node if the marquee touches its CARD (SZNodeLayout.cardRect), not just its
        // center — standard "rubber-band intersects = select".
        multiSelection = Set(nodes.filter { node in
            guard !hiddenPieces.contains(node.id) else { return false }
            return world.intersects(SZNodeLayout.cardRect(of: node))
        }.map(\.id))
        selectedNodeID = nil            // a multi-select supersedes the single chat/edit selection
        selectedConnectionID = nil
    }

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let marquee {
            let r = CGRect(x: min(marquee.start.x, marquee.current.x), y: min(marquee.start.y, marquee.current.y),
                           width: abs(marquee.start.x - marquee.current.x), height: abs(marquee.start.y - marquee.current.y))
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay(Rectangle().stroke(Color.accentColor.opacity(0.85), lineWidth: 1))
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }

    /// The camera-independent world content, `.equatable()` so camera ticks (and drag/wire ticks,
    /// whose per-frame state lives in the overlay layers) skip the whole subtree. Everything the
    /// content RENDERS is passed as a compared value prop; everything it can DO is a closure routed
    /// back into the panel's live handlers below.
    private func canvasContent(_ graph: SZGraph) -> some View {
        SZNodeCanvasContentView(
            graph: graph,
            strokeZoom: Self.quantizedStrokeZoom(camera.zoom),
            space: Self.space,
            selectedNodeID: selectedNodeID,
            multiSelection: multiSelection,
            selectedConnectionID: selectedConnectionID,
            hiddenConnectionID: wire?.picked?.id,
            ghostedNodeIDs: Set(drag?.members.map(\.id) ?? []),
            raisedTiers: raisedTiers,
            connectedSockets: SZGraphCanvasModel.connectedSocketIDs(in: graph, excluding: wire?.picked?.id),
            connectedInputsByNode: Self.connectedInputsByNode(graph),
            nodeAgentState: nodeAgentState,
            graphOpStatus: graphOpStatus,
            isRunning: isRunning,
            runWorkSet: runWorkSet,
            onSelectNode: { selectNode($0, additive: $1) },
            onSelectConnection: { id in
                selectedConnectionID = id
                selectedNodeID = nil
                canvasFocused = true
            },
            onNodeDragChanged: { nodeDragChanged($0, translation: $1, location: $2) },
            onNodeDragEnded: { nodeDragEnded() },
            onSocketDragChanged: { socketDragChanged($0, location: $1) },
            onSocketDragEnded: { endWireDrag(); stopAutoPan() },
            onEdgeDragChanged: { edgeDragChanged($0, at: $1) },
            onEdgeDragEnded: { endWireDrag(); stopAutoPan() },
            autoEditNodeID: autoEditNodeID,
            onOpenNodeMenu: { openNodeMenu($0) },
            onOpenNodeChat: onOpenNodeChat,
            onOpenNodeSource: onOpenNodeSource,
            onFixNode: onFixNode,
            onSetInputDefault: onSetInputDefault,
            onToggleDisplay: onToggleDisplay,
            optionsFor: optionsFor,
            onCommitPrompt: { store.updateNode(id: $0, prompt: $1) },
            onPromptEditingChanged: { id, editing in
                editingNodeID = editing ? id : nil
                if editing, autoEditNodeID == id { autoEditNodeID = nil }   // consume the one-shot auto-focus
            })
            .equatable()
    }

    /// The moving copies of an in-flight node drag: the dragged cards (at their live, snapped
    /// positions), their sockets, and every edge touching them. The originals stay ghosted (invisible,
    /// gesture alive) in the content layer, so per drag tick ONLY this small overlay re-renders — and
    /// the card views' position-excluding `==` means even here only `.position()` layout moves.
    /// Hit-testing is off: the ghost is a pure visual; events keep flowing to the original's gesture.
    @ViewBuilder
    private var dragOverlay: some View {
        if let drag, let raw = project?.graph {
            let ghost = displayGraph(raw)   // hidden pieces removed + drag delta applied
            let memberIDs = Set(drag.members.map(\.id))
            let members = ghost.nodes.filter { memberIDs.contains($0.id) }
            let connected = SZGraphCanvasModel.connectedSocketIDs(in: ghost, excluding: wire?.picked?.id)
            let inputsByNode = Self.connectedInputsByNode(ghost)   // once per tick, shared by the ghosts
            ZStack(alignment: .topLeading) {
                ForEach(ghost.connections.filter {
                    memberIDs.contains($0.from.node) || memberIDs.contains($0.to.node)
                }) { connection in
                    if let points = SZGraphCanvasModel.endpoints(of: connection, in: ghost) {
                        SZConnectionStrokeView(from: points.from, to: points.to, kind: connection.kind,
                                               selected: connection.id == selectedConnectionID,
                                               hidden: false, zoom: Self.quantizedStrokeZoom(camera.zoom))
                    }
                }
                ForEach(members) { node in
                    ghostCard(node, graph: ghost, connectedInputs: inputsByNode[node.id] ?? [])
                        .position(x: node.position.x, y: node.position.y)
                }
                // Member-scoped socket enumeration: only the dragged nodes' dots move, so don't build
                // (and discard) the whole graph's socket array every tick.
                ForEach(SZGraphCanvasModel.sockets(in: SZGraph(nodes: members))) { socket in
                    SZPortSocket(kind: socket.kind, isConnected: connected.contains(socket.id))
                        .frame(width: 22, height: 22)
                        .position(socket.point)
                }
            }
            .allowsHitTesting(false)
        }
    }

    /// A dragged node's visual stand-in — built by the SAME shared constructor the content layer uses
    /// (SZNodeCanvasContentView.card), so a mid-drag card can't render differently from itself at rest;
    /// its `==` ignores position, so per tick this only MOVES, its body untouched. Interaction closures
    /// stay no-op defaults (the overlay doesn't hit-test) except `optionsFor`, which is render-affecting
    /// (enum chip labels).
    @ViewBuilder
    private func ghostCard(_ node: SZNode, graph: SZGraph, connectedInputs: Set<String>) -> some View {
        SZNodeCanvasContentView.card(
            for: node,
            status: SZNodeCanvasContentView.pillStatus(for: node, agentState: nodeAgentState,
                                                       ops: graphOpStatus, isRunning: isRunning,
                                                       workSet: runWorkSet),
            isSelected: isSelected(node.id),
            locked: isLocked(node.id),
            isRunning: isRunning,
            errorDetail: nodeAgentState[node.id]?.errorDetail,
            renderEndpoint: graph.renderEndpoint,
            connectedInputs: connectedInputs,
            optionsFor: { port in optionsFor(node.id, port) })
    }

    /// Input ports fed by a data edge, per node, in one pass — those rows hide their inline control
    /// (the wire's value wins at runtime; disconnecting restores the control with the untouched default).
    private static func connectedInputsByNode(_ graph: SZGraph) -> [SZNodeID: Set<String>] {
        graph.connections.reduce(into: [:]) { acc, c in
            guard c.kind == .data else { return }
            acc[c.to.node, default: []].insert(c.to.port)
        }
    }

    /// Edge stroke weights divide by zoom to hold constant on-screen width — but feeding the LIVE zoom
    /// to the content view would re-diff the whole subtree on every pinch tick. Quantizing to quarter
    /// powers of two (≤ ~9% width error mid-step) re-diffs a handful of times across a full pinch.
    private static func quantizedStrokeZoom(_ zoom: CGFloat) -> CGFloat {
        exp2((log2(max(zoom, 0.1)) * 4).rounded() / 4)
    }

    /// The compatible-slot feedback for an in-flight wire: a soft ring on every socket a drop would
    /// validly connect to, and a brighter breathing glow on the one currently snapped (`wire.target`).
    /// A sibling of `wirePreview` in the world-space overlay — it reads `wire` + the live display graph
    /// and never touches the frozen socket layer, so it's as cheap as the preview. Gated on `wire.moved`
    /// so a bare click (sub-threshold wobble) doesn't flash rings.
    @ViewBuilder
    private func wireTargetsOverlay(_ wire: SZWireDragSession) -> some View {
        if wire.moved, let graph = project?.graph {
            let display = displayGraph(graph)
            ForEach(SZGraphCanvasModel.validTargets(for: wire.source, in: display, tiers: raisedTiers,
                                                    pickedConnectionID: wire.picked?.id,
                                                    isLocked: isLocked)) { socket in
                SZWireTargetHighlight(kind: socket.kind, isActiveTarget: socket.id == wire.target?.id)
                    .position(socket.point)
            }
        }
    }

    /// When a connection is selected, light up the two socket dots it joins — drawn ABOVE the content so
    /// the glow sits on top of the normal dots. Colour follows the edge kind (violet flow, cyan data).
    @ViewBuilder
    private func selectedConnectionHighlight(_ graph: SZGraph) -> some View {
        if let id = selectedConnectionID,
           let conn = graph.connections.first(where: { $0.id == id }),
           let pts = SZGraphCanvasModel.endpoints(of: conn, in: displayGraph(graph)) {
            let color: Color = conn.kind == .flow ? SZEdgeStyle.intentViolet : .cyan
            endpointGlow(pts.from, color)
            endpointGlow(pts.to, color)
        }
    }

    private func endpointGlow(_ p: CGPoint, _ color: Color) -> some View {
        let r = max(3, 6 / max(camera.zoom, 0.1))
        return Circle()
            .fill(color)
            .frame(width: SZNodeLayout.socketSize + 3, height: SZNodeLayout.socketSize + 3)
            .shadow(color: color.opacity(0.95), radius: r)
            .shadow(color: color.opacity(0.6), radius: r)
            .position(p)
            .allowsHitTesting(false)
    }

    private func wirePreview(_ wire: SZWireDragSession) -> some View {
        // The bezier's control points assume `from` exits an output (rightward) and `to` enters an
        // input (leftward) — so when the fixed anchor is an INPUT socket, the free end is the `from`.
        let free = wire.target?.point ?? wire.current
        let (from, to) = wire.source.side == .input ? (free, wire.source.point) : (wire.source.point, free)
        let kind = wire.source.kind
        let z = max(camera.zoom, 0.1)
        // Dash = intent: a FLOW preview is violet + dashed; a data preview is a solid blue wire, its
        // in-flight cue being opacity + cursor-follow.
        let isFlow = kind == .flow
        let color: Color = isFlow ? SZEdgeStyle.intentViolet : .blue
        let dash: [CGFloat] = isFlow ? [max(4, 6 / z), max(3, 5 / z)] : []
        let width = isFlow ? max(1.8, 3.2 / z) : max(2, 3 / z)
        return SZConnectionShape(from: from, to: to)
            .stroke(color.opacity(0.85),
                    style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash))
            .allowsHitTesting(false)
    }

    /// The graph as the CONTENT layer draws it: staged split/merge pieces (+ their edges) hidden until
    /// the op commits. Drag movement is deliberately NOT applied — dragged cards are ghosted in place
    /// (gesture kept alive) and `dragOverlay` draws the moving copies, so a drag tick never re-diffs
    /// the content subtree.
    private func contentGraph(_ graph: SZGraph) -> SZGraph {
        var copy = graph
        if !hiddenPieces.isEmpty {
            copy.nodes.removeAll { hiddenPieces.contains($0.id) }
            copy.connections.removeAll { hiddenPieces.contains($0.from.node) || hiddenPieces.contains($0.to.node) }
        }
        return copy
    }

    /// The graph as the user SEES it mid-interaction: `contentGraph` plus the in-flight drag delta.
    /// Backs the drag overlay's ghost positions and every wire-gesture computation (snap targets track
    /// live card positions; hidden split/merge pieces can never become targets).
    private func displayGraph(_ graph: SZGraph) -> SZGraph {
        var copy = contentGraph(graph)
        if let drag {
            let delta = effectiveDelta(drag)
            for member in drag.members {
                guard let i = copy.nodes.firstIndex(where: { $0.id == member.id }) else { continue }
                copy.nodes[i].position = SZPoint(x: member.start.x + delta.width,
                                                 y: member.start.y + delta.height)
            }
        }
        return copy
    }

    /// The drag translation as applied: raw, or (when snapping) adjusted so the PRIMARY node's card
    /// edges land on the grid (top-left anchor — card dims are pitch multiples, so all edges align).
    /// Group members share the one delta, preserving their relative offsets — and because both the
    /// live preview and the commit go through here, the card never jumps on drop.
    private func effectiveDelta(_ drag: NodeDrag) -> CGSize {
        let delta = rawDelta(drag)
        guard snapToGrid,
              let primary = drag.members.first(where: { $0.id == drag.primary }),
              let node = project?.graph.node(id: drag.primary) else { return delta }
        let raw = CGPoint(x: primary.start.x + delta.width,
                          y: primary.start.y + delta.height)
        let target = SZNodeLayout.snappedCenter(raw, size: SZNodeLayout.size(of: node))
        return CGSize(width: target.x - primary.start.x, height: target.y - primary.start.y)
    }

    /// The raw world-space drag delta. Edge auto-pan moves the camera under a possibly stationary
    /// cursor — the gesture translation doesn't change, so the accumulated offset delta is subtracted
    /// (panning to reveal rightward makes panAccum negative, growing the delta) before dividing out
    /// the live zoom.
    private func rawDelta(_ drag: NodeDrag) -> CGSize {
        CGSize(width: (drag.translation.width - drag.panAccum.width) / camera.zoom,
               height: (drag.translation.height - drag.panAccum.height) / camera.zoom)
    }

    // MARK: - Add node

    // HUD "+" button: drop a node at the viewport center.
    private func addPromptNode() {
        addPromptNode(atScreen: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    }

    // Shared creation path. `screen` is a point in the "szcanvas" coordinate space (viewport pixels);
    // we divide out the zoom + pan to land the card center under it. Used by the HUD button and by
    // double-click-on-empty-canvas.
    private func addPromptNode(atScreen screen: CGPoint) {
        let center = snappedPromptCenter(camera.worldPoint(screen: screen))
        if let id = store.addPromptNode(prompt: "", position: SZPoint(x: center.x, y: center.y)) {
            selectedNodeID = id
            autoEditNodeID = id   // the new card opens into editing + grabs the field (see SZPromptNodeView)
        }
    }

    /// A prompt-card center honoring the snap pref — the ONE placement rule shared by every creation
    /// site (HUD/double-click add, file drop, flow-wire spawn).
    private func snappedPromptCenter(_ center: CGPoint) -> CGPoint {
        snapToGrid ? SZNodeLayout.snappedCenter(center, size: SZNodeLayout.promptCardSize) : center
    }

    // MARK: - File drop → media nodes

    /// Handle files dropped on the canvas (`screen` is the drop point in "szcanvas" space, matching the
    /// double-tap gesture). Converts the point to graph space, then defers classification + staggering to
    /// `SZMediaSource` — the same rules `ui_add_source_node` applies. Returns whether ANY media file was
    /// handled: false leaves the drag un-consumed (so a stray .txt just bounces back).
    private func handleFileDrop(_ urls: [URL], at screen: CGPoint) -> Bool {
        let origin = snappedPromptCenter(camera.worldPoint(screen: screen))
        let specs = SZMediaSource.specs(for: urls, origin: SZPoint(x: origin.x, y: origin.y))
        guard !specs.isEmpty else { return false }
        onCreateMediaNodes(specs)
        return true
    }

    // MARK: - Node drag

    /// Per-tick node-drag handler (the gesture itself is attached by the content view; logic lives
    /// here where the drag state is).
    private func nodeDragChanged(_ id: SZNodeID, translation: CGSize, location: CGPoint) {
        // Moving is allowed even while locked (run/chat) — only edits/wiring/values are blocked.
        if drag?.primary != id {
            // Grabbing a node that's part of a multi-selection drags the WHOLE group by the same
            // delta; grabbing any other node drags just it and collapses the selection to it.
            let groupDrag = multiSelection.contains(id) && multiSelection.count > 1
            let ids = groupDrag ? multiSelection : [id]
            let members = ids.compactMap { mid in storePosition(mid).map { (id: mid, start: $0) } }
            drag = NodeDrag(primary: id, members: members)
            if !groupDrag { selectedNodeID = id; multiSelection = [id] }
            selectedConnectionID = nil
            canvasFocused = true
        }
        // Screen-space inputs only; rawDelta folds in auto-pan and divides out the zoom.
        drag?.translation = translation
        feedAutoPan(cursor: location)
    }

    private func nodeDragEnded() {
        stopAutoPan()
        if let drag {
            let delta = effectiveDelta(drag)   // same (snapped) delta the ghost preview showed
            store.moveNodes(drag.members.map {
                ($0.id, SZPoint(x: $0.start.x + delta.width, y: $0.start.y + delta.height))
            })
        }
        drag = nil
    }

    private func storePosition(_ id: SZNodeID) -> CGPoint? {
        project?.graph.node(id: id).map { CGPoint(x: $0.position.x, y: $0.position.y) }
    }

    // MARK: - Wire drag (connect)

    /// Per-tick socket-drag handler (gesture attached by the content view). The graph is re-derived
    /// from the store on every event rather than captured at render time — the content view's
    /// `.equatable()` skip means an attached gesture's closures can be from an older render.
    private func socketDragChanged(_ source: SZSocket, location: CGPoint) {
        guard let raw = project?.graph else { return }
        let graph = displayGraph(raw)
        guard !isLocked(source.nodeID) else { return }   // can't wire a locked (in-progress) node
        let world = camera.worldPoint(screen: location)
        if wire?.grabbed.id != source.id {
            wire = SZWireDragSession.begin(from: source, atWorld: world, screen: location,
                                           in: graph, isLocked: isLocked)
        } else {
            wire?.lastScreen = location
            updateWireDrag(to: world, in: graph)
        }
        feedAutoPan(cursor: location)
    }

    /// Grab anywhere ALONG an edge (data or flow) to pick it up — the session picks the detachable
    /// end. Graph re-derived per event (see `socketDragChanged`).
    private func edgeDragChanged(_ connection: SZConnection, at screen: CGPoint) {
        guard let raw = project?.graph else { return }
        let graph = displayGraph(raw)
        guard !isLocked(connection.from.node), !isLocked(connection.to.node) else { return }
        let world = camera.worldPoint(screen: screen)
        if wire?.picked?.id != connection.id {
            wire = SZWireDragSession.begin(along: connection, atWorld: world, screen: screen, in: graph)
        } else {
            wire?.lastScreen = screen
            updateWireDrag(to: world, in: graph)
        }
        feedAutoPan(cursor: screen)
    }

    private func updateWireDrag(to world: CGPoint, in graph: SZGraph) {
        wire?.update(toWorld: world, zoom: camera.zoom, in: graph, tiers: raisedTiers,
                     isLocked: isLocked)
    }

    /// Shared drop for both wire gestures: the session decides (`outcome`), the panel dispatches —
    /// re-route / disconnect / connect through the host (persists + reloads; a connect swaps out an
    /// occupied data input), spawn directly on the store (authoring-only — flow is not a runtime
    /// construct, so no host round-trip / reload, like `addPromptNode(atScreen:)`).
    private func endWireDrag() {
        defer { wire = nil }
        guard let outcome = wire?.outcome(snapToGrid: snapToGrid) else { return }
        switch outcome {
        case .none:
            break
        case let .reconnect(id, end, ref):
            onReconnectConnection(id, end, ref)
        case let .disconnect(id):
            onDeleteConnection(id)
        case let .connect(from, to, kind):
            onConnect(from, to, kind)
        case let .spawnPromptNode(center, source, downstream):
            guard let newID = store.addPromptNode(prompt: "",
                                                  position: SZPoint(x: center.x, y: center.y))
            else { break }
            let newRef = SZPortRef(node: newID, port: "flow")
            if downstream {
                store.connect(from: source, to: newRef, kind: .flow)   // source feeds new
            } else {
                store.connect(from: newRef, to: source, kind: .flow)   // new feeds source
            }
            selectedNodeID = newID
            autoEditNodeID = newID   // the new card opens into editing (see SZPromptNodeView)
        }
    }

    // MARK: - Pan / zoom

    /// Shared per-event feed for every dragging gesture: drive the pan timer and the indicator bands.
    private func feedAutoPan(cursor: CGPoint) {
        // Also drive the grid cursor trail: an active drag (node / wire / edge) suppresses
        // onContinuousHover, so this is the only cursor signal the trail gets mid-drag.
        self.cursor = cursor
        autoPan.update(cursor: cursor, in: viewSize)
        panEdges = SZEdgeAutoPan.intensities(cursor: cursor, in: viewSize)
    }

    private func stopAutoPan() {
        autoPan.stop()
        panEdges = SZEdgeAutoPan.Intensities()
    }

    /// One edge auto-pan timer tick: move the camera by `delta` (screen pt) and re-derive the
    /// in-flight drag from the new offset — the cursor may be stationary while the camera moves.
    private func autoPanTick(_ delta: CGSize) {
        // Safety net for a cancelled gesture whose onEnded never fired (Esc, app switch): no live
        // drag, or the mouse already up → kill the timer instead of panning forever.
        guard drag != nil || wire != nil, NSEvent.pressedMouseButtons != 0 else {
            stopAutoPan()
            return
        }
        camera.pan(by: delta)
        drag?.panAccum.width += delta.width
        drag?.panAccum.height += delta.height
        // The loose wire end tracks the (possibly stationary) cursor's NEW world point, and target
        // snapping re-runs against sockets scrolling under it. Same display graph the gestures see,
        // so hidden split/merge pieces can't become snap targets mid-pan.
        if let w = wire, let graph = project?.graph {
            updateWireDrag(to: camera.worldPoint(screen: w.lastScreen), in: displayGraph(graph))
        }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                dismissContextMenu()   // the menu is panel-space; it must not drift off its world anchor
                if pinchAnchor == nil { pinchAnchor = camera }
                guard let anchor = pinchAnchor else { return }
                camera.applyZoom(anchor.zoom * value, pivot: pivot(), from: anchor)
            }
            .onEnded { _ in pinchAnchor = nil }
    }

    private func handleScroll(_ data: SZScrollWheelData) {
        dismissContextMenu()   // same rule as zoom: the camera moved, the anchor didn't
        guard cursor != nil, editingNodeID == nil else { return }   // only when hovering, not typing
        if data.commandHeld {
            camera.applyZoom(camera.zoom * (1 - data.deltaY * 0.005), pivot: pivot(), from: camera)
        } else {
            camera.pan(by: CGSize(width: data.deltaX, height: data.deltaY))
        }
    }

    private func pivot() -> CGPoint {
        cursor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
    }

    /// Apply a host-raised camera command (the framing math lives on SZCanvasCamera). No-op with no
    /// nodes or an unmeasured viewport. Animated with a snappy reframe.
    private func applyCameraCommand(_ command: SZCameraCommand) {
        guard let bounds = graphWorldBounds(), viewSize.width > 0, viewSize.height > 0 else { return }
        withAnimation(.snappy(duration: command.action == .fit ? 0.28 : 0.22)) {
            switch command.action {
            case .center: camera = .centered(on: bounds, in: viewSize, zoom: camera.zoom)
            case .fit: camera = .fitting(bounds, in: viewSize)
            }
        }
    }

    /// World-space bounding box of every node card. Nil with no graph / no nodes.
    private func graphWorldBounds() -> CGRect? {
        project.flatMap { SZGraphCanvasModel.worldBounds(of: $0.graph) }
    }
}

/// The HUD's whole-graph run button: filled-accent **Build** with a pending-node count badge, flipping
/// to orange **Stop** while a run is in flight (the same run the composer's Stop halts). A gentle white
/// ring pulses while work is pending — the successor to the old chat-toggle beacon.
private struct SZHudBuildButton: View {
    let isRunning: Bool
    let pendingCount: Int
    let pulse: Bool              // pending work, no run → breathe to draw the eye
    let onBuild: () -> Void
    let onStop: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: isRunning ? onStop : onBuild) {
            HStack(spacing: 6) {
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(isRunning ? "Stop" : "Build")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(Capsule().fill(isRunning ? Color.orange : Color.accentColor)
                .brightness(hover ? 0.06 : 0))
            .overlay {
                if pulse, !isRunning {
                    TimelineView(.animation) { context in
                        let phase = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 3)
                        Capsule().stroke(Color.white.opacity(0.15 + 0.4 * phase), lineWidth: 1.5)
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !isRunning, pendingCount > 0 { countBadge }
            }
        }
        .buttonStyle(.plain)
        .trackingHover($hover)
        .help(isRunning ? "Stop the run — nodes already implemented stay"
                        : "Build \(pendingCount) pending node\(pendingCount == 1 ? "" : "s")")
    }

    /// Notification-style count pill poking the top-right corner (white on the accent capsule).
    private var countBadge: some View {
        Text("\(pendingCount)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(.white))
            .overlay(Capsule().stroke(.black.opacity(0.12), lineWidth: 0.5))
            .offset(x: 6, y: -6)
    }
}

/// A HUD capsule-bar icon button (add / delete). Its own hover state so the circle brightens under
/// the cursor, matching the node card + card-pill hover feel.
private struct SZHudIconButton: View {
    let name: String
    let help: String
    var enabled: Bool = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .opacity(enabled ? 1 : 0.4)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(hover && enabled ? 0.14 : 0.06)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .trackingHover($hover)
        .help(help)
    }
}

/// A HUD icon that opens a pull-down `Menu` instead of firing an action — the gear/settings button.
/// Shares `SZHudIconButton`'s 32×32 glass-circle recipe so it sits flush with the icon buttons; the
/// menu content is injected by the caller. `.menuStyle(.button)` + `.menuIndicator(.hidden)` strip
/// the default menu chrome so only the circle shows (mirrors SZProviderGenerationPickerView).
private struct SZHudMenuButton<Content: View>: View {
    let name: String
    let help: String
    @ViewBuilder var content: () -> Content
    @State private var hover = false

    var body: some View {
        Menu { content() } label: {
            Image(systemName: name)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(hover ? 0.14 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .trackingHover($hover)
        .help(help)
    }
}
