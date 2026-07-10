// SPDX-License-Identifier: AGPL-3.0-only
// Panel-layout tree mutations (the model behind the rearrangeable panel system): edge drops split,
// center drops swap, close collapses + remembers, reopen restores, and normalize sanitizes whatever
// a stale/hand-edited app-state.json throws at it.
import Foundation
import Testing
@testable import SZCore

// The default layout: (viewport / nodeEditor) | chat.

@Test func defaultLayoutShowsAllPanelsOnce() {
    let layout = SZPanelLayoutState.default
    #expect(layout.root.leafKinds == [.viewport, .nodeEditor, .chat])
    #expect(layout.presentKinds == Set(SZPanelKind.allCases))
}

@Test(arguments: [SZPanelDropZone.left, .right, .top, .bottom])
func edgeDropSplitsTargetFiftyFifty(zone: SZPanelDropZone) {
    var layout = SZPanelLayoutState.default
    layout.movePanel(.chat, onto: .viewport, zone: zone)

    // Chat left the right dock and now shares the viewport's slot.
    #expect(layout.presentKinds == Set(SZPanelKind.allCases))
    guard case .split(let orientation, let fraction, let leading, let trailing) = layout.root else {
        Issue.record("root should be the collapsed viewport/nodeEditor split"); return
    }
    #expect(orientation == .vertical)   // outer chat split collapsed away
    #expect(trailing == .panel(.nodeEditor))
    guard case .split(let subOrientation, let subFraction, let subLeading, let subTrailing) = leading else {
        Issue.record("viewport slot should have become a split"); return
    }
    #expect(subFraction == 0.5)
    #expect(fraction == 0.6)            // untouched
    switch zone {
    case .left:
        #expect(subOrientation == .horizontal)
        #expect(subLeading == .panel(.chat) && subTrailing == .panel(.viewport))
    case .right:
        #expect(subOrientation == .horizontal)
        #expect(subLeading == .panel(.viewport) && subTrailing == .panel(.chat))
    case .top:
        #expect(subOrientation == .vertical)
        #expect(subLeading == .panel(.chat) && subTrailing == .panel(.viewport))
    case .bottom:
        #expect(subOrientation == .vertical)
        #expect(subLeading == .panel(.viewport) && subTrailing == .panel(.chat))
    case .center:
        Issue.record("not an edge zone")
    }
}

@Test func centerDropSwapsPanelsKeepingTreeShape() {
    var layout = SZPanelLayoutState.default
    layout.movePanel(.chat, onto: .viewport, zone: .center)
    #expect(layout.root.leafKinds == [.chat, .nodeEditor, .viewport])
    layout.movePanel(.chat, onto: .viewport, zone: .center)
    #expect(layout == .default)   // swap twice = identity, fractions untouched
}

@Test func moveOntoSelfOrMissingPanelIsANoOp() {
    var layout = SZPanelLayoutState.default
    layout.movePanel(.chat, onto: .chat, zone: .left)
    #expect(layout == .default)
    layout.removePanel(.chat)
    var removed = layout
    removed.movePanel(.chat, onto: .viewport, zone: .left)     // chat not in tree
    #expect(removed == layout)
    removed.movePanel(.viewport, onto: .chat, zone: .left)     // target not in tree
    #expect(removed == layout)
}

@Test func removeCollapsesParentAndRecordsRestorePosition() {
    var layout = SZPanelLayoutState.default
    layout.removePanel(.chat)

    guard case .split(let orientation, _, let leading, let trailing) = layout.root else {
        Issue.record("root should be the viewport/nodeEditor split"); return
    }
    #expect(orientation == .vertical)
    #expect(leading == .panel(.viewport) && trailing == .panel(.nodeEditor))

    // Chat sat trailing in a horizontal 0.75 split → it owned the RIGHT 25% next to the combo
    // (neighbor = first leaf of the sibling subtree).
    let record = layout.restorePositions[.chat]
    #expect(record == SZPanelRestorePosition(neighbor: .viewport, zone: .right, share: 0.25))
}

@Test func removeRefusesTheLastPanel() {
    var layout = SZPanelLayoutState(root: .panel(.viewport))
    layout.removePanel(.viewport)
    #expect(layout.root == .panel(.viewport))
}

@Test func insertRestoresRememberedSpot() {
    var layout = SZPanelLayoutState.default
    layout.removePanel(.chat)
    layout.insertPanel(.chat)
    // Chat's remembered neighbor is the viewport, so it re-splits THAT leaf (which, after the outer
    // chat split collapsed, sits directly under the root) — the remembered side and share survive.
    guard case .split(_, _, let viewportSlot, _) = layout.root,
          case .split(let orientation, let fraction, let subLeading, let subTrailing) = viewportSlot else {
        Issue.record("viewport slot should have become viewport|chat"); return
    }
    #expect(orientation == .horizontal)
    #expect(subLeading == .panel(.viewport) && subTrailing == .panel(.chat))
    #expect(abs(fraction - 0.75) < 1e-9)   // chat's share was 0.25, on the right
}

@Test func insertFallsBackToWindowEdgeWhenNeighborIsGone() {
    var layout = SZPanelLayoutState(root: .split(orientation: .vertical, fraction: 0.6,
                                                 leading: .panel(.viewport), trailing: .panel(.nodeEditor)))
    layout.restorePositions[.chat] = SZPanelRestorePosition(neighbor: .chat, zone: .right, share: 0.25)
    // Degenerate remembered neighbor (itself — not in the tree) → split the whole window right.
    layout.insertPanel(.chat)
    guard case .split(let orientation, let fraction, let leading, let trailing) = layout.root else {
        Issue.record("root should be a fresh horizontal split"); return
    }
    #expect(orientation == .horizontal)
    #expect(trailing == .panel(.chat))
    #expect(abs(fraction - 0.75) < 1e-9)
    #expect(leading.leafKinds == [.viewport, .nodeEditor])
}

@Test func insertIsIdempotent() {
    var layout = SZPanelLayoutState.default
    layout.insertPanel(.chat)
    #expect(layout == .default)
}

@Test func setFractionFollowsPath() {
    var layout = SZPanelLayoutState.default
    layout.setFraction(0.3, at: [])                 // root split
    layout.setFraction(0.8, at: [.leading])         // viewport/nodeEditor split
    guard case .split(_, let rootFraction, let leading, _) = layout.root,
          case .split(_, let innerFraction, _, _) = leading else {
        Issue.record("tree shape changed unexpectedly"); return
    }
    #expect(rootFraction == 0.3)
    #expect(innerFraction == 0.8)
}

@Test func normalizeClampsFractions() {
    var layout = SZPanelLayoutState.default
    layout.setFraction(0.01, at: [])
    layout.setFraction(0.99, at: [.leading])
    layout.normalize()
    guard case .split(_, let rootFraction, let leading, _) = layout.root,
          case .split(_, let innerFraction, _, _) = leading else {
        Issue.record("tree shape changed unexpectedly"); return
    }
    #expect(rootFraction == 0.1)
    #expect(innerFraction == 0.9)
}

@Test func normalizeResetsMalformedTreeWithDuplicateLeaves() {
    var layout = SZPanelLayoutState(root: .split(orientation: .horizontal, fraction: 0.5,
                                                 leading: .panel(.chat), trailing: .panel(.chat)))
    layout.normalize()
    #expect(layout == .default)
}

@Test func codableRoundTripPreservesLayout() throws {
    var layout = SZPanelLayoutState.default
    layout.movePanel(.chat, onto: .nodeEditor, zone: .bottom)
    layout.removePanel(.viewport)
    let data = try JSONEncoder().encode(layout)
    let decoded = try JSONDecoder().decode(SZPanelLayoutState.self, from: data)
    #expect(decoded == layout)
}
