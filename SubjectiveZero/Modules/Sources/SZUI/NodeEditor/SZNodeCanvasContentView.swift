// SPDX-License-Identifier: AGPL-3.0-only
// The pannable canvas CONTENT — everything that lives in world space (edge layer, node cards, socket
// dots). Deliberately independent of the camera: the panel applies `.scaleEffect().offset()` OUTSIDE
// this view and wraps it in `.equatable()`, so a camera tick (scroll pan / pinch zoom, 60–120 events/s)
// skips this whole subtree — no ForEach re-emission, no attribute-graph re-validation, no card layout.
// Profiled before the split: every scroll event re-validated every card/socket/edge attribute inside
// `NSHostingView.layout()`, stalling the main thread for hundreds of ms and starving the Metal
// viewport's main-thread draw.
//
// Same rule for the two drag interactions, which DO change world content per tick:
// - A node drag ghosts its cards here (`ghostedNodeIDs`, opacity 0 — the views must STAY in the tree
//   or their live drag gesture would cancel) and the panel draws the moving ghosts + their incident
//   edges in a small overlay. Content inputs change once at drag start/end, not per tick.
// - A wire drag's preview is drawn by the panel's overlay; here only `hiddenConnectionID` /
//   `connectedSockets` flip once at pickup.
//
// Gestures are ATTACHED here but their logic lives in the panel (closure props, excluded from `==`):
// a skipped body keeps the last render's closures, which is safe because they only route into the
// panel, whose @State reads are live — while everything this view RENDERS is compared in `==`, so any
// visible change re-renders it with fresh closures.
import AppKit
import SwiftUI
import SZCore

struct SZNodeCanvasContentView: View, Equatable {
    // World-space render inputs — every one of these is compared in `==`.
    let graph: SZGraph                        // the display graph (hidden split/merge pieces removed)
    let strokeZoom: CGFloat                   // quantized zoom for edge stroke weights (see panel)
    let space: String                         // the editor's named gesture coordinate space
    let selectedNodeID: SZNodeID?
    let multiSelection: Set<SZNodeID>
    let selectedConnectionID: SZConnectionID?
    let hiddenConnectionID: SZConnectionID?   // a picked-up wire: invisible, the drag preview stands in
    let ghostedNodeIDs: Set<SZNodeID>         // mid-drag cards: invisible here, ghosts drawn by the panel
    /// Render tiers (panel-computed, single source with occlusion hit-testing): the primary selection
    /// rides above the multi-selection, which rides above the rest — missing = 0.
    let raisedTiers: [SZNodeID: Int]
    let connectedSockets: Set<String>
    let connectedInputsByNode: [SZNodeID: Set<String>]
    let nodeAgentState: [SZNodeID: SZNodeAgentState]
    let graphOpStatus: [SZNodeID: String]
    let isRunning: Bool
    let runWorkSet: Set<SZNodeID>     // the run's captured work — members read Coding; a user's mid-run draft isn't in it
    let lockedNodes: Set<SZNodeID>    // ledger-held nodes (host-owned) — the lock affordance's source
    var previewsEnabled: Bool = true  // the global Live Previews gate (mirrors SZNodeLayout.previewsEnabled)
    var zoomedOut: Bool = false       // semantic-zoom tier: cards render as preview-only tiles, socket dots hide

    // Interaction plumbing — closures excluded from `==` (see header). `previewFrames` rides with
    // them: a stable registry ref whose per-node boxes are observed only by the thumb leaves.
    var previewFrames: SZNodePreviewFrames? = nil
    var onSelectNode: (SZNodeID, _ additive: Bool) -> Void = { _, _ in }
    var onSelectConnection: (SZConnectionID) -> Void = { _ in }
    var onNodeDragChanged: (SZNodeID, _ translation: CGSize, _ location: CGPoint) -> Void = { _, _, _ in }
    var onNodeDragEnded: () -> Void = {}
    var onSocketDragChanged: (SZSocket, _ location: CGPoint) -> Void = { _, _ in }
    var onSocketDragEnded: () -> Void = {}
    var onEdgeDragChanged: (SZConnection, CGPoint) -> Void = { _, _ in }
    var onEdgeDragEnded: () -> Void = {}
    var autoEditNodeID: SZNodeID? = nil                   // a just-added prompt node → open its field for typing
    var onOpenNodeMenu: (SZNodeID) -> Void = { _ in }     // a card's "⋯" → open that node's context menu
    var onOpenNodeChat: (SZNodeID) -> Void = { _ in }     // a card's speech button → the node's Coding Agent chat
    var onOpenNodeSource: (SZNodeID) -> Void = { _ in }   // a card's file button → the node's Node.swift
    var onFixNode: (SZNodeID) -> Void = { _ in }          // Outdated/Error pill → compose a rebuild request
    var onSetInputDefault: (SZNodeID, String, SZPortValue, Bool) -> Void = { _, _, _, _ in }
    var onToggleDisplay: (SZNodeID, String) -> Void = { _, _ in }
    var onTogglePreview: (SZNodeID, String) -> Void = { _, _ in }
    var optionsFor: (SZNodeID, String) -> [SZEnumOption] = { _, _ in [] }
    var onCommitPrompt: (SZNodeID, String) -> Void = { _, _ in }
    var onPromptEditingChanged: (SZNodeID, Bool) -> Void = { _, _ in }
    var onLivePrompt: (SZNodeID, String) -> Void = { _, _ in }   // live keystrokes → host pending edit (no persist)

    nonisolated static func == (lhs: SZNodeCanvasContentView, rhs: SZNodeCanvasContentView) -> Bool {
        lhs.graph == rhs.graph
            && lhs.strokeZoom == rhs.strokeZoom
            && lhs.space == rhs.space
            && lhs.selectedNodeID == rhs.selectedNodeID
            && lhs.multiSelection == rhs.multiSelection
            && lhs.selectedConnectionID == rhs.selectedConnectionID
            && lhs.hiddenConnectionID == rhs.hiddenConnectionID
            && lhs.ghostedNodeIDs == rhs.ghostedNodeIDs
            && lhs.raisedTiers == rhs.raisedTiers
            && lhs.connectedSockets == rhs.connectedSockets
            && lhs.connectedInputsByNode == rhs.connectedInputsByNode
            && lhs.nodeAgentState == rhs.nodeAgentState
            && lhs.graphOpStatus == rhs.graphOpStatus
            && lhs.isRunning == rhs.isRunning
            && lhs.runWorkSet == rhs.runWorkSet
            && lhs.lockedNodes == rhs.lockedNodes
            && lhs.previewsEnabled == rhs.previewsEnabled
            && lhs.zoomedOut == rhs.zoomedOut
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SZConnectionLayer(graph: graph, zoom: strokeZoom, selectedID: selectedConnectionID,
                              hiddenID: hiddenConnectionID, hiddenNodeIDs: ghostedNodeIDs, space: space,
                              onSelect: { onSelectConnection($0) },
                              onDragChanged: { onEdgeDragChanged($0, $1) },
                              onDragEnded: { onEdgeDragEnded() })
            // Card first, then ITS OWN sockets, per node — so a later card covers an earlier node's
            // dots instead of every dot painting above every card. The selected node jumps the stack
            // via its tier, dots riding along at the same z (declaration order keeps them on top of
            // their card), so the card being inspected is fully readable under overlap — and a dot
            // buried under a higher card is correctly un-grabbable (what you see is what you can hit).
            ForEach(graph.nodes) { node in
                let z = Double(raisedTiers[node.id] ?? 0)
                nodeCard(node)
                    .position(x: node.position.x, y: node.position.y)
                    .opacity(ghostedNodeIDs.contains(node.id) ? 0 : 1)
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(space))
                        .onChanged { onNodeDragChanged(node.id, $0.translation, $0.location) }
                        .onEnded { _ in onNodeDragEnded() })
                    .zIndex(z)
                socketLayer(for: node)
                    .zIndex(z)
            }
        }
    }

    // One node's interactive sockets (interleaved above its card in `body`): each socket is a drag
    // source for wiring.
    private func socketLayer(for node: SZNode) -> some View {
        ForEach(SZGraphCanvasModel.sockets(of: node)) { socket in
            SZPortSocket(kind: socket.kind, isConnected: connectedSockets.contains(socket.id))
                .frame(width: 22, height: 22)            // forgiving hit target around the 12pt dot
                .contentShape(Circle())
                .position(socket.point)
                // Zoomed out, dots hide with the rest of the card chrome — and their hit areas go
                // INERT: an invisible 22pt drag target over a preview tile would turn "drag the
                // tile" into a wire drag the user never saw. Ghosting keeps hit-testing (opacity
                // only): the live drag gesture owning those sockets must not cancel mid-drag.
                .opacity(ghostedNodeIDs.contains(socket.nodeID) || zoomedOut ? 0 : 1)
                .allowsHitTesting(!zoomedOut)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { onSocketDragChanged(socket, $0.location) }
                    .onEnded { _ in onSocketDragEnded() })
        }
    }

    @ViewBuilder
    private func nodeCard(_ node: SZNode) -> some View {
        Self.card(
            for: node,
            status: Self.pillStatus(for: node, agentState: nodeAgentState, ops: graphOpStatus,
                                    isRunning: isRunning, workSet: runWorkSet),
            isSelected: selectedNodeID == node.id || multiSelection.contains(node.id),
            locked: Self.isLocked(node.id, ops: graphOpStatus, lockedNodes: lockedNodes),
            isRunning: isRunning,
            errorDetail: nodeAgentState[node.id]?.errorDetail,
            renderEndpoint: graph.renderEndpoint,
            connectedInputs: connectedInputsByNode[node.id] ?? [],
            previewsEnabled: previewsEnabled,
            zoomedOut: zoomedOut,
            previewFrame: previewFrames?.frame(for: node.id),
            onOpenSource: { onOpenNodeSource(node.id) },
            onOpenChat: { onOpenNodeChat(node.id) },
            onOpenMenu: { onOpenNodeMenu(node.id) },
            onSetInput: { port, value, persist in onSetInputDefault(node.id, port, value, persist) },
            onToggleDisplay: { port in onToggleDisplay(node.id, port) },
            onTogglePreview: { port in onTogglePreview(node.id, port) },
            optionsFor: { port in optionsFor(node.id, port) },
            onCommitPrompt: { onCommitPrompt(node.id, $0) },
            onPromptEditingChanged: { onPromptEditingChanged(node.id, $0) },
            onLivePrompt: { onLivePrompt(node.id, $0) },
            // Offered only where there is something to repair, so the pill stays inert elsewhere.
            onFix: node.needsRebuild ? { onFixNode(node.id) } : nil,
            autoFocus: node.id == autoEditNodeID)
            // simultaneousGesture (not onTapGesture): an ancestor onTapGesture swallows taps meant
            // for the card's inner "⋯" Button — this lets both fire (the button opens its menu, the
            // card still selects).
            .simultaneousGesture(TapGesture().onEnded { onSelectNode(node.id, Self.shiftHeld) })
            // No .contextMenu here — right-click is captured by the panel's SZCanvasRightClickCatcher
            // (the message-suggestion menu; Split/Merge live on as drafted @project messages).
    }

    /// The ONE card constructor — used by this content layer (interactive) and the panel's drag-ghost
    /// overlay (passive visual copy), so a dragged card can never render differently from itself at
    /// rest. Gestures/menus are the caller's business; closures default to no-ops for passive copies.
    @ViewBuilder
    static func card(
        for node: SZNode, status: SZNodeStatus, isSelected: Bool, locked: Bool, isRunning: Bool,
        errorDetail: String?, renderEndpoint: SZPortRef?, connectedInputs: Set<String>,
        previewsEnabled: Bool = true,
        zoomedOut: Bool = false,
        previewFrame: SZNodePreviewFrame? = nil,
        onOpenSource: (() -> Void)? = nil,
        onOpenChat: (() -> Void)? = nil,
        onOpenMenu: (() -> Void)? = nil,
        onSetInput: @escaping (String, SZPortValue, Bool) -> Void = { _, _, _ in },
        onToggleDisplay: @escaping (String) -> Void = { _ in },
        onTogglePreview: @escaping (String) -> Void = { _ in },
        optionsFor: @escaping (String) -> [SZEnumOption] = { _ in [] },
        onCommitPrompt: @escaping (String) -> Void = { _ in },
        onPromptEditingChanged: @escaping (Bool) -> Void = { _ in },
        onLivePrompt: @escaping (String) -> Void = { _ in },
        onFix: (() -> Void)? = nil,
        autoFocus: Bool = false
    ) -> some View {
        switch node.kind {
        case .prompt:
            SZPromptNodeView(
                node: node, status: status, isSelected: isSelected, locked: locked,
                showPill: showPill(status, isRunning: isRunning), errorDetail: errorDetail,
                autoFocus: autoFocus,
                onCommit: onCommitPrompt, onEditingChanged: onPromptEditingChanged,
                onLiveEdit: onLivePrompt)
                .equatable()
        case .generated:
            SZNodeView(node: node, status: status, isSelected: isSelected, locked: locked,
                       showPill: showPill(status, isRunning: isRunning), errorDetail: errorDetail,
                       renderEndpoint: renderEndpoint,
                       previewsEnabled: previewsEnabled,
                       zoomedOut: zoomedOut,
                       connectedInputs: connectedInputs,
                       previewFrame: previewFrame,
                       onOpenSource: onOpenSource,
                       onOpenChat: onOpenChat,
                       onOpenMenu: onOpenMenu,
                       onSetInput: onSetInput,
                       onToggleDisplay: onToggleDisplay,
                       onTogglePreview: onTogglePreview,
                       optionsFor: optionsFor,
                       onFix: onFix)
                .equatable()
        }
    }

    /// Show the status pill only when it's informative: any non-ready state, or any state while the run
    /// is live. A settled generated node (run finished) shows no pill.
    static func showPill(_ status: SZNodeStatus, isRunning: Bool) -> Bool {
        isRunning || status != .ready
    }

    /// Whether the Shift key is down right now (for additive click-select; SwiftUI tap gestures don't
    /// carry modifiers, so we read the live event flags).
    private static var shiftHeld: Bool {
        #if canImport(AppKit)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }

    // MARK: - Shared status/lock rules (single source for this view, the panel's gesture guards,
    // and the panel's drag-ghost overlay)

    /// The pill state for a node: live agent status (error / needs-input / coding / queued) wins, then a built
    /// node is Ready (or Rebuild, if its contract moved since that build), then a prompt node being worked on
    /// is Coding, else Draft.
    static func pillStatus(for node: SZNode, agentState: [SZNodeID: SZNodeAgentState],
                           ops: [SZNodeID: String], isRunning: Bool,
                           workSet: Set<SZNodeID> = []) -> SZNodeStatus {
        // An original node being split/merged wears that label (not "Ready"/"Coding") until the swap.
        if let op = ops[node.id] { return op == "Merging" ? .merging : .splitting }
        let state = agentState[node.id] ?? SZNodeAgentState()
        switch state.phase {
        case .error: return .error
        case .needsInput: return .needsInput
        case .reloading: return .reloading            // hand-edited Node.swift is recompiling
        default: break
        }
        if state.isChatting { return .building }        // its Coding Agent is mid-chat-edit
        if node.kind == .generated {
            // It has a build and still renders — but if its contract's ports moved, that build no longer honours
            // them, so "Ready" would be a lie. Which pill depends on HOW it fails to honour them: code that
            // names ports the contract dropped reads nil every frame (a fault, red), while a contract that
            // declares ports the code hasn't written yet is merely unfinished (amber).
            switch node.rebuildReason {
            case nil: return .ready
            case .some(let reason) where !(isRunning && workSet.contains(node.id)):
                return reason == .sourceMismatch ? .error : .outdated
            default: break                              // being rebuilt right now → fall through to Building
            }
        }
        switch state.phase {
        case .coding: return .building
        case .queued, .planning: return .planning
        default:
            // A prompt node in the run's captured WORK SET reads Coding while it waits for its agent to
            // report; a prompt node NOT in the set during a run (e.g. one the user dropped on the canvas
            // mid-run) isn't the fleet's work, so it stays Draft.
            return (isRunning && workSet.contains(node.id)) ? .building : .draft
        }
    }

    /// A node is locked only while an agent owns it — `lockedNodes` is the host's LEDGER-backed
    /// view (SZHost.lockedNodes: a chat turn's claim, or the run's claim on still-in-flight
    /// `.prompt` work; a promoted node unlocks the moment it flips to `.generated`, and a draft the
    /// user added mid-run was never claimed), and `ops` flags the originals of an in-flight
    /// split/merge. The affordance and the mutation fence read the same source, so what the UI dims
    /// and what the host refuses can't drift.
    /// A locked node can't be edited/deleted/wired — but it CAN still be repositioned (drag-move
    /// stays allowed), so the user can tidy the canvas mid-run without fighting the agents on the
    /// parts that matter (contracts/wiring/values).
    static func isLocked(_ id: SZNodeID, ops: [SZNodeID: String],
                         lockedNodes: Set<SZNodeID>) -> Bool {
        ops[id] != nil || lockedNodes.contains(id)
    }
}
