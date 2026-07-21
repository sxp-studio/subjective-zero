// SPDX-License-Identifier: AGPL-3.0-only
// The Equatable fast-path contract. SZNodeView / SZPromptNodeView / SZNodeCanvasContentView skip body
// re-evaluation via hand-written `==` over their render-affecting value props (closures excluded,
// node position excluded — it's applied externally). Nothing in the language enforces that a NEWLY
// ADDED stored property also gets a line in `==`; forgetting one silently freezes that prop's updates
// on every equatable-skipped path (camera pans, node drags — precisely the hot paths).
//
// TWO halves, and they catch different mistakes — neither is sufficient alone:
//
//  1. `…StoredPropertiesMatchItsEquatableContract` pins each view's stored-property SET. It fires when
//     a property is ADDED or RENAMED, forcing a decision about `==`.
//  2. `…EqualityComparesEveryPropItClaimsTo` drives `==` itself, one property at a time. The set check
//     alone never reads the `==` body: deleting `&& lhs.connectedInputs == rhs.connectedInputs` from
//     SZNodeView leaves the property set identical, so half 1 stays green while `connectedInputs`
//     silently stops invalidating the card — exactly the bug this file exists to prevent. Half 2 is
//     what actually fails on that edit.
//
// Excluded props are asserted too (differ in one → still `==`), so an exclusion stays a deliberate
// choice rather than an omission nobody noticed.
import CoreGraphics
import Testing
@testable import SZUI
import SZCore

private let node = SZNode(kind: .generated, title: "T", position: SZPoint(x: 0, y: 0))

/// Stored-property names, as a SET (declaration order is not part of the contract) and with
/// property-wrapper backing prefixes stripped (`_text` → `text` — the `_` spelling is a SwiftUI
/// internal we don't want to pin).
private func storedProperties(of subject: Any) -> Set<String> {
    Set(Mirror(reflecting: subject).children.compactMap { label in
        label.label.map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }
    })
}

@Test func nodeViewStoredPropertiesMatchItsEquatableContract() {
    let view = SZNodeView(node: node, status: .ready, renderEndpoint: nil)
    #expect(storedProperties(of: view) == [
        // compared in ==
        "node", "status", "isSelected", "locked", "showPill", "errorDetail", "renderEndpoint",
        "connectedInputs", "previewsEnabled", "zoomedOut",
        // closures — deliberately excluded from == (capture only stable refs). The card's
        // bottom-left buttons: file (onOpenSource), speech (onOpenChat), and "⋯" (onOpenMenu).
        "onOpenSource", "onOpenChat", "onOpenMenu",
        "onSetInput", "onToggleDisplay", "onTogglePreview", "optionsFor",
        // the Outdated/Error pill's one-click repair request
        "onFix",
        // the live-preview box — a stable per-node ref like the closures; only the thumb leaf
        // reads its contents, so identity must not invalidate the card
        "previewFrame",
        // view-local state (excluded from ==): the card hover lift
        "cardHover",
    ])
}

@Test func promptNodeViewStoredPropertiesMatchItsEquatableContract() {
    let view = SZPromptNodeView(node: node, status: .draft, onCommit: { _ in }, onEditingChanged: { _ in })
    #expect(storedProperties(of: view) == [
        // compared in ==
        "node", "status", "isSelected", "locked", "showPill", "errorDetail",
        // value input excluded from == (a one-shot on insertion; see SZPromptNodeView)
        "autoFocus",
        // closures — deliberately excluded from ==
        "onCommit", "onEditingChanged", "onLiveEdit",
        // view-local state — SwiftUI re-renders on its own changes regardless of ==
        "text", "editing", "focused", "cardHover",
    ])
}

@Test func canvasContentViewStoredPropertiesMatchItsEquatableContract() {
    let view = SZNodeCanvasContentView(
        graph: SZGraph(), strokeZoom: 1, space: "s", selectedNodeID: nil, multiSelection: [],
        selectedConnectionID: nil, hiddenConnectionID: nil, ghostedNodeIDs: [], raisedTiers: [:],
        connectedSockets: [], connectedInputsByNode: [:], nodeAgentState: [:], graphOpStatus: [:],
        isRunning: false, runWorkSet: [], lockedNodes: [])
    #expect(storedProperties(of: view) == [
        // compared in ==
        "graph", "strokeZoom", "space", "selectedNodeID", "multiSelection", "selectedConnectionID",
        "hiddenConnectionID", "ghostedNodeIDs", "raisedTiers", "connectedSockets", "connectedInputsByNode",
        "nodeAgentState", "graphOpStatus", "isRunning", "runWorkSet", "lockedNodes", "previewsEnabled", "zoomedOut",
        // closures — deliberately excluded from == (routed to the panel's live handlers).
        // Split/Merge/chat-open/source-open moved to the panel's right-click menu, so their
        // closures left too.
        "onSelectNode", "onSelectConnection", "onNodeDragChanged", "onNodeDragEnded",
        "onSocketDragChanged", "onSocketDragEnded", "onEdgeDragChanged", "onEdgeDragEnded",
        "autoEditNodeID",
        "onOpenNodeMenu", "onOpenNodeChat", "onOpenNodeSource", "onFixNode", "onSetInputDefault",
        "onToggleDisplay", "onTogglePreview", "optionsFor", "onCommitPrompt", "onPromptEditingChanged",
        "onLivePrompt",
        // the preview-box registry — stable host-owned ref; per-node boxes are observed by the
        // thumb leaves, never compared here
        "previewFrames",
    ])
}

// MARK: - `==` itself: one property at a time
//
// Each `differs` case changes exactly ONE property from the baseline and asserts the views compare
// UNEQUAL — i.e. that `==` actually reads it. Each `ignores` case changes exactly one deliberately
// excluded property and asserts they still compare EQUAL. Delete any `&&` clause from a view's `==`
// and the matching `differs` case goes red.

private let otherNode = SZNode(kind: .generated, title: "OTHER", position: SZPoint(x: 0, y: 0))
private let portRef = SZPortRef(node: node.id, port: "output")

@MainActor
private func nodeView(
    node n: SZNode = node, status: SZNodeStatus = .ready, isSelected: Bool = false, locked: Bool = false,
    showPill: Bool = true, errorDetail: String? = nil, renderEndpoint: SZPortRef? = nil,
    previewsEnabled: Bool = true, zoomedOut: Bool = false,
    connectedInputs: Set<String> = [], previewFrame: SZNodePreviewFrame? = nil
) -> SZNodeView {
    SZNodeView(node: n, status: status, isSelected: isSelected, locked: locked, showPill: showPill,
               errorDetail: errorDetail, renderEndpoint: renderEndpoint,
               previewsEnabled: previewsEnabled, zoomedOut: zoomedOut,
               connectedInputs: connectedInputs, previewFrame: previewFrame)
}

@MainActor
@Test func nodeViewEqualityComparesEveryPropItClaimsTo() {
    #expect(nodeView() == nodeView())                                          // baseline: reflexive

    var renamed = node; renamed.title = "RENAMED"
    #expect(nodeView(node: renamed) != nodeView())
    #expect(nodeView(status: .building) != nodeView())
    #expect(nodeView(isSelected: true) != nodeView())
    #expect(nodeView(locked: true) != nodeView())
    #expect(nodeView(showPill: false) != nodeView())
    #expect(nodeView(errorDetail: "boom") != nodeView())
    #expect(nodeView(renderEndpoint: portRef) != nodeView())
    #expect(nodeView(previewsEnabled: false) != nodeView())                    // gate flip must reflow the card
    #expect(nodeView(zoomedOut: true) != nodeView())                           // LOD crossing re-renders once
    #expect(nodeView(connectedInputs: ["input"]) != nodeView())                // the clause at SZNodeView.swift:46
    var previewing = node; previewing.body = SZNodeBody(mode: .preview)        // body rides node ==
    #expect(nodeView(node: previewing) != nodeView())
}

@MainActor
@Test func nodeViewEqualityIgnoresPositionAndClosures() {
    // Position is normalized away inside `==` (SZNodeView.swift:37-38) — the card is placed by the
    // canvas, so a pan must not invalidate every card's body.
    var moved = node; moved.position = SZPoint(x: 999, y: -999)
    #expect(nodeView(node: moved) == nodeView())

    // The preview box is a stable per-node ref written at ~15 Hz — its identity (and contents)
    // must not invalidate the card; only the thumb leaf observes it.
    #expect(nodeView(previewFrame: SZNodePreviewFrame()) == nodeView())

    // Closures capture only stable refs; a fresh closure identity each render must not invalidate.
    let withClosures = SZNodeView(
        node: node, status: .ready, renderEndpoint: nil,
        onOpenSource: {}, onOpenChat: {}, onOpenMenu: {},
        onSetInput: { _, _, _ in }, onToggleDisplay: { _ in }, onTogglePreview: { _ in },
        optionsFor: { _ in [] })
    #expect(withClosures == nodeView())
}

@MainActor
private func promptView(
    node n: SZNode = node, status: SZNodeStatus = .draft, isSelected: Bool = false, locked: Bool = false,
    showPill: Bool = true, errorDetail: String? = nil, autoFocus: Bool = false
) -> SZPromptNodeView {
    SZPromptNodeView(node: n, status: status, isSelected: isSelected, locked: locked, showPill: showPill,
                     errorDetail: errorDetail, autoFocus: autoFocus,
                     onCommit: { _ in }, onEditingChanged: { _ in })
}

@MainActor
@Test func promptNodeViewEqualityComparesEveryPropItClaimsTo() {
    #expect(promptView() == promptView())

    var renamed = node; renamed.title = "RENAMED"
    #expect(promptView(node: renamed) != promptView())
    #expect(promptView(status: .building) != promptView())
    #expect(promptView(isSelected: true) != promptView())
    #expect(promptView(locked: true) != promptView())
    #expect(promptView(showPill: false) != promptView())
    #expect(promptView(errorDetail: "boom") != promptView())
}

@MainActor
@Test func promptNodeViewEqualityIgnoresPositionAutoFocusAndClosures() {
    var moved = node; moved.position = SZPoint(x: 999, y: -999)
    #expect(promptView(node: moved) == promptView())
    #expect(promptView(autoFocus: true) == promptView())   // one-shot on insertion, not render-affecting
}

@MainActor
private func canvasView(
    graph: SZGraph = SZGraph(), strokeZoom: CGFloat = 1, space: String = "s",
    selectedNodeID: SZNodeID? = nil, multiSelection: Set<SZNodeID> = [],
    selectedConnectionID: SZConnectionID? = nil, hiddenConnectionID: SZConnectionID? = nil,
    ghostedNodeIDs: Set<SZNodeID> = [], raisedTiers: [SZNodeID: Int] = [:],
    connectedSockets: Set<String> = [], connectedInputsByNode: [SZNodeID: Set<String>] = [:],
    nodeAgentState: [SZNodeID: SZNodeAgentState] = [:], graphOpStatus: [SZNodeID: String] = [:],
    isRunning: Bool = false, runWorkSet: Set<SZNodeID> = [], lockedNodes: Set<SZNodeID> = [],
    autoEditNodeID: SZNodeID? = nil,
    previewsEnabled: Bool = true, zoomedOut: Bool = false, previewFrames: SZNodePreviewFrames? = nil
) -> SZNodeCanvasContentView {
    var v = SZNodeCanvasContentView(
        graph: graph, strokeZoom: strokeZoom, space: space, selectedNodeID: selectedNodeID,
        multiSelection: multiSelection, selectedConnectionID: selectedConnectionID,
        hiddenConnectionID: hiddenConnectionID, ghostedNodeIDs: ghostedNodeIDs, raisedTiers: raisedTiers,
        connectedSockets: connectedSockets, connectedInputsByNode: connectedInputsByNode,
        nodeAgentState: nodeAgentState, graphOpStatus: graphOpStatus, isRunning: isRunning,
        runWorkSet: runWorkSet, lockedNodes: lockedNodes, previewsEnabled: previewsEnabled, zoomedOut: zoomedOut,
        previewFrames: previewFrames)
    v.autoEditNodeID = autoEditNodeID
    return v
}

@MainActor
@Test func canvasContentViewEqualityComparesEveryPropItClaimsTo() {
    #expect(canvasView() == canvasView())

    let id = node.id, cid = SZConnectionID()
    #expect(canvasView(graph: SZGraph(nodes: [otherNode])) != canvasView())
    #expect(canvasView(strokeZoom: 2) != canvasView())
    #expect(canvasView(space: "other") != canvasView())
    #expect(canvasView(selectedNodeID: id) != canvasView())
    #expect(canvasView(multiSelection: [id]) != canvasView())
    #expect(canvasView(selectedConnectionID: cid) != canvasView())
    #expect(canvasView(hiddenConnectionID: cid) != canvasView())
    #expect(canvasView(ghostedNodeIDs: [id]) != canvasView())
    #expect(canvasView(raisedTiers: [id: 1]) != canvasView())
    #expect(canvasView(connectedSockets: ["s"]) != canvasView())
    #expect(canvasView(connectedInputsByNode: [id: ["input"]]) != canvasView())
    #expect(canvasView(nodeAgentState: [id: SZNodeAgentState(phase: .coding)]) != canvasView())
    #expect(canvasView(graphOpStatus: [id: "splitting"]) != canvasView())
    #expect(canvasView(isRunning: true) != canvasView())
    #expect(canvasView(runWorkSet: [id]) != canvasView())
    #expect(canvasView(previewsEnabled: false) != canvasView())
    #expect(canvasView(zoomedOut: true) != canvasView())
}

@MainActor
@Test func canvasContentViewEqualityIgnoresAutoEditAndClosures() {
    // `autoEditNodeID` is a one-shot focus hint consumed on insertion, deliberately out of `==`.
    #expect(canvasView(autoEditNodeID: node.id) == canvasView())

    // The preview registry is a stable host-owned ref — identity must not invalidate the canvas.
    #expect(canvasView(previewFrames: SZNodePreviewFrames()) == canvasView())

    var withClosures = canvasView()
    withClosures.onSelectNode = { _, _ in }
    withClosures.onNodeDragEnded = {}
    withClosures.onToggleDisplay = { _, _ in }
    withClosures.onTogglePreview = { _, _ in }
    #expect(withClosures == canvasView())
}
