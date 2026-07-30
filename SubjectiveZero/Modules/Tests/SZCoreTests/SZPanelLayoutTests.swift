// SPDX-License-Identifier: AGPL-3.0-only
// Panel-layout tree mutations (the model behind the rearrangeable panel system): edge drops split,
// center drops swap, close collapses + remembers, reopen restores, and normalize sanitizes whatever
// a stale/hand-edited app-state.json throws at it.
import Foundation
import Testing
@testable import SZCore

// The default layout: (viewport / nodeEditor) | chat.

@Test func defaultLayoutShowsAllProductionPanelsOnce() {
    let layout = SZPanelLayoutState.default
    #expect(layout.root.leafIDs == [.viewport, .nodeEditor, .chat])
    // The Debug panel is opt-in, never part of the launch layout.
    #expect(layout.presentIDs == Set([.viewport, .nodeEditor, .chat]))
}

@Test func normalizeStripsTheProfilerPanelWhereUnavailable() {
    // A DEBUG build's saved layout lands in a build without the surface (release): the leaf
    // collapses to its sibling and the restore position is forgotten; production panels survive.
    var layout = SZPanelLayoutState.default
    layout.insertPanel(.profiler)
    #expect(layout.contains(.profiler))
    layout.normalize(allowingProfiler: false)
    #expect(!layout.contains(.profiler))
    #expect(layout.restorePositions[.profiler] == nil)
    #expect(layout.presentIDs == Set([.viewport, .nodeEditor, .chat]))
    // Where available, the same layout keeps it.
    var kept = SZPanelLayoutState.default
    kept.insertPanel(.profiler)
    kept.normalize(allowingProfiler: true)
    #expect(kept.contains(.profiler))
}

@Test func normalizeResetsWhenTheProfilerIsTheWholeTree() {
    // A DEBUG session that closed everything but the Profiler saves a single-leaf tree; a
    // release build must land on the default layout, not an unremovable empty tile.
    var layout = SZPanelLayoutState.default
    layout.root = .panel(.profiler)
    layout.normalize(allowingProfiler: false)
    #expect(layout == .default)
}

@Test func legacyDebugRawValueDecodesAsProfiler() throws {
    // The panel shipped one session as "debug" before its rename — saved layouts keep decoding.
    #expect(try JSONDecoder().decode(SZPanelKind.self, from: Data(#""debug""#.utf8)) == .profiler)
    #expect(try JSONDecoder().decode(SZPanelKind.self, from: Data(#""profiler""#.utf8)) == .profiler)
}

@Test(arguments: [SZPanelDropZone.left, .right, .top, .bottom])
func edgeDropSplitsTargetFiftyFifty(zone: SZPanelDropZone) {
    var layout = SZPanelLayoutState.default
    layout.movePanel(.chat, onto: .viewport, zone: zone)

    // Chat left the right dock and now shares the viewport's slot.
    #expect(layout.presentIDs == Set([.viewport, .nodeEditor, .chat]))
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
    #expect(layout.root.leafIDs == [.chat, .nodeEditor, .viewport])
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
    #expect(leading.leafIDs == [.viewport, .nodeEditor])
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

// MARK: - Instance identity (SZPanelID)

@Test func panelIDTokenRoundTripAndRejects() {
    // Primary ↔ bare kind string; clones ↔ display-ordinal suffix ("viewport:2" = "Viewport 2").
    #expect(SZPanelID(token: "viewport") == SZPanelID(.viewport, instance: 0))
    #expect(SZPanelID(token: "viewport:2") == SZPanelID(.viewport, instance: 1))
    #expect(SZPanelID(token: "viewport:8") == SZPanelID(.viewport, instance: 7))
    #expect(SZPanelID(token: "chat:3") == SZPanelID(.chat, instance: 2))   // lenient: cap is normalize()'s job
    #expect(SZPanelID(token: "debug") == .profiler)                        // legacy alias survives the parser
    #expect(SZPanelID(.viewport, instance: 1).token == "viewport:2")
    #expect(SZPanelID(.viewport, instance: 1).displayName == "Viewport 2")
    #expect(SZPanelID.viewport.token == "viewport")
    #expect(SZPanelID.viewport.displayName == "Viewport")
    // No second spelling of the primary, no non-canonical ordinals, no junk.
    #expect(SZPanelID(token: "viewport:0") == nil)
    #expect(SZPanelID(token: "viewport:1") == nil)
    #expect(SZPanelID(token: "viewport:x") == nil)
    #expect(SZPanelID(token: "viewport:+2") == nil)
    #expect(SZPanelID(token: "viewport:02") == nil)
    #expect(SZPanelID(token: "viewport:2:3") == nil)
    #expect(SZPanelID(token: "bogus") == nil)
    #expect(SZPanelID(token: "") == nil)
}

@Test func legacyKindKeyedStateDecodesToInstanceZero() throws {
    // The exact bytes a pre-instance build wrote: leaves as {"panel":{"_0":"<kind>"}} and
    // restorePositions as the alternating flat array (SZPanelKind was not CodingKeyRepresentable).
    // These must decode unchanged, every leaf landing on instance 0.
    let legacy = """
    {"root":{"split":{"orientation":"horizontal","fraction":0.75,
      "leading":{"split":{"orientation":"vertical","fraction":0.6,
        "leading":{"panel":{"_0":"viewport"}},"trailing":{"panel":{"_0":"nodeEditor"}}}},
      "trailing":{"panel":{"_0":"chat"}}}},
     "restorePositions":["profiler",{"neighbor":"chat","zone":"bottom","share":0.4}]}
    """
    let decoded = try JSONDecoder().decode(SZPanelLayoutState.self, from: Data(legacy.utf8))
    #expect(decoded.root == SZPanelLayoutState.default.root)
    #expect(decoded.root.leafIDs.allSatisfy { $0.instance == 0 })
    #expect(decoded.restorePositions[.profiler]
            == SZPanelRestorePosition(neighbor: .chat, zone: .bottom, share: 0.4))
}

@Test func primaryOnlyStateReencodesInLegacyShape() throws {
    // Forward-compat guard: as long as no clone exists, the encoded bytes must look exactly like
    // the kind-keyed era (bare kind strings, no ":" tokens) so OLD builds keep decoding new files.
    var layout = SZPanelLayoutState.default
    layout.removePanel(.chat)   // populate restorePositions too
    let data = try JSONEncoder().encode(layout)
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains(#""_0":"viewport""#))
    #expect(!json.contains(":2"))
    // And the alternating-array dictionary encoding survived (a string key, not a keyed object).
    #expect(json.contains(#""restorePositions":["chat""#))
}

@Test func codableRoundTripPreservesCloneLayout() throws {
    var layout = SZPanelLayoutState.default
    layout.clonePanel(.viewport)
    let data = try JSONEncoder().encode(layout)
    #expect(String(decoding: data, as: UTF8.self).contains(#""viewport:2""#))
    #expect(try JSONDecoder().decode(SZPanelLayoutState.self, from: data) == layout)
}

@Test func clonePanelAllocatesLowestFreeInstanceAndSplitsFiftyFifty() {
    var layout = SZPanelLayoutState.default
    let first = layout.clonePanel(.viewport)
    #expect(first == SZPanelID(.viewport, instance: 1))
    // The source slot became a horizontal 50/50 [viewport | viewport:2].
    guard case .split(_, _, let leading, _) = layout.root,
          case .split(_, _, let viewportSlot, _) = leading,
          case .split(let orientation, let fraction, let subLeading, let subTrailing) = viewportSlot else {
        Issue.record("viewport slot should have become a split"); return
    }
    #expect(orientation == .horizontal)
    #expect(fraction == 0.5)
    #expect(subLeading == .panel(.viewport) && subTrailing == .panel(SZPanelID(.viewport, instance: 1)))

    let second = layout.clonePanel(.viewport)
    #expect(second == SZPanelID(.viewport, instance: 2))
    // Closing a clone frees its number; the next clone fills the hole (lowest free wins).
    layout.removePanel(SZPanelID(.viewport, instance: 1))
    #expect(layout.clonePanel(.viewport) == SZPanelID(.viewport, instance: 1))
}

@Test func clonePanelRefusesAtCapAbsenceAndSingleInstanceKinds() {
    var layout = SZPanelLayoutState.default
    for _ in 1..<SZPanelKind.viewport.maxInstances {
        #expect(layout.clonePanel(.viewport) != nil)
    }
    #expect(layout.clonePanel(.viewport) == nil)             // all instances placed
    #expect(layout.clonePanel(.chat) == nil)                 // maxInstances 1 — same rule, no special case
    layout = SZPanelLayoutState.default
    layout.removePanel(.chat)
    #expect(layout.clonePanel(.chat) == nil)                 // source absent
}

@Test func clonePanelHonorsExcludedInstances() {
    // A popped-out clone lives outside the tree but keeps its identity — the caller passes it as
    // excluded so a new clone never reuses the number of a live window.
    var layout = SZPanelLayoutState.default
    #expect(layout.clonePanel(.viewport, excluding: [SZPanelID(.viewport, instance: 1)])
            == SZPanelID(.viewport, instance: 2))
}

@Test func cloneCloseRecordsRestoreAndInsertPutsItBack() {
    // Clones close/reopen exactly like primaries — the uniform restore record is what dock-back
    // (pop-out → insertPanel) rides on.
    var layout = SZPanelLayoutState.default
    guard let clone = layout.clonePanel(.viewport) else { Issue.record("clone failed"); return }
    let cloned = layout
    layout.removePanel(clone)
    #expect(!layout.contains(clone))
    #expect(layout.restorePositions[clone]
            == SZPanelRestorePosition(neighbor: .viewport, zone: .right, share: 0.5))
    layout.insertPanel(clone)
    #expect(layout.root == cloned.root)
}

@Test(arguments: [SZPanelDropZone.left, .right, .top, .bottom])
func insertOntoDocksDetachedPanelAtExplicitSpot(zone: SZPanelDropZone) {
    // The drag-to-dock commit: a panel that is NOT in the tree lands beside an explicit target,
    // ignoring any remembered restore position.
    var layout = SZPanelLayoutState.default
    layout.removePanel(.chat)   // root collapses to the viewport/nodeEditor split
    layout.insertPanel(.chat, onto: .nodeEditor, zone: zone, share: 0.3)
    guard case .split(_, _, _, let editorSlot) = layout.root,
          case .split(let orientation, let fraction, let subLeading, let subTrailing) = editorSlot else {
        Issue.record("node editor slot should have become a split"); return
    }
    switch zone {
    case .left, .top:
        #expect(subLeading == .panel(.chat) && subTrailing == .panel(.nodeEditor))
        #expect(abs(fraction - 0.3) < 1e-9)
    case .right, .bottom:
        #expect(subLeading == .panel(.nodeEditor) && subTrailing == .panel(.chat))
        #expect(abs(fraction - 0.7) < 1e-9)
    case .center:
        Issue.record("not an edge zone")
    }
    #expect(orientation == (zone == .left || zone == .right ? .horizontal : .vertical))
}

@Test func insertOntoRefusesPresentPanelOrMissingTarget() {
    var layout = SZPanelLayoutState.default
    var copy = layout
    copy.insertPanel(.chat, onto: .viewport, zone: .left)        // chat already in the tree
    #expect(copy == layout)
    layout.removePanel(.chat)
    copy = layout
    copy.insertPanel(.chat, onto: .profiler, zone: .left)        // target not in the tree
    #expect(copy == layout)
}

@Test func normalizeStripsOutOfRangeInstancesAndPrunesRestoreRecords() {
    // A hand-edited or stale app-state.json can carry instances beyond a kind's cap: the leaf
    // degrades (collapses to its sibling), the rest of the layout survives.
    var layout = SZPanelLayoutState.default
    layout.clonePanel(.viewport)
    guard case .split(let orientation, let fraction, let leading, _) = layout.root else {
        Issue.record("unexpected tree shape"); return
    }
    layout.root = .split(orientation: orientation, fraction: fraction,
                         leading: leading, trailing: .panel(SZPanelID(.chat, instance: 1)))
    layout.restorePositions[SZPanelID(.viewport, instance: 9)] =
        SZPanelRestorePosition(neighbor: .viewport, zone: .right, share: 0.5)
    layout.normalize()
    #expect(!layout.contains(SZPanelID(.chat, instance: 1)))
    #expect(layout.restorePositions[SZPanelID(.viewport, instance: 9)] == nil)
    // The legal clone survived — a gap-free sequence is NOT required, identity is stable.
    #expect(layout.contains(SZPanelID(.viewport, instance: 1)))
    #expect(layout.contains(.viewport) && layout.contains(.nodeEditor))
}

@Test func normalizeKeepsLegalInstanceGaps() {
    // {viewport, viewport:3} with no viewport:2 is a fine layout — closes leave holes, the clone
    // allocator fills them later.
    var layout = SZPanelLayoutState(
        root: .split(orientation: .horizontal, fraction: 0.5,
                     leading: .panel(.viewport), trailing: .panel(SZPanelID(.viewport, instance: 2))))
    layout.normalize()
    #expect(layout.root.leafIDs == [.viewport, SZPanelID(.viewport, instance: 2)])
}

@Test func normalizeResetsOnDuplicateIDsButKeepsDistinctInstances() {
    var duplicated = SZPanelLayoutState(
        root: .split(orientation: .horizontal, fraction: 0.5,
                     leading: .panel(SZPanelID(.viewport, instance: 1)),
                     trailing: .panel(SZPanelID(.viewport, instance: 1))))
    duplicated.normalize()
    #expect(duplicated == .default)
    var distinct = SZPanelLayoutState(
        root: .split(orientation: .horizontal, fraction: 0.5,
                     leading: .panel(.viewport), trailing: .panel(SZPanelID(.viewport, instance: 1))))
    distinct.normalize()
    #expect(distinct.root.leafIDs.count == 2)   // two viewport tiles are legal, not duplicates
}

@Test func normalizeResetsWhenAnOutOfRangeInstanceIsTheWholeTree() {
    var layout = SZPanelLayoutState(root: .panel(SZPanelID(.viewport, instance: 9)))
    layout.normalize()
    #expect(layout == .default)
}

@Test func displayTitlesArePositionalAndDense() {
    // The visible numbering rule (Clem's spec): alone → "Viewport"; in company → dense 1..n by
    // instance ORDER, whatever identity gaps exist. Closing a middle instance renumbers the
    // survivors' labels; identities/tokens never change underneath.
    let one = SZPanelID.displayTitles(for: [SZPanelID.viewport, .nodeEditor, .chat])
    #expect(one[.viewport] == "Viewport")
    #expect(one[.nodeEditor] == "Node Editor")

    let three = SZPanelID.displayTitles(for: [SZPanelID.viewport,
                                              SZPanelID(.viewport, instance: 1),
                                              SZPanelID(.viewport, instance: 2), .chat])
    #expect(three[.viewport] == "Viewport 1")
    #expect(three[SZPanelID(.viewport, instance: 1)] == "Viewport 2")
    #expect(three[SZPanelID(.viewport, instance: 2)] == "Viewport 3")
    #expect(three[.chat] == "Chat")

    // Remove the middle one: the identity gap {0, 2} still displays as a dense "1", "2".
    let gapped = SZPanelID.displayTitles(for: [SZPanelID.viewport, SZPanelID(.viewport, instance: 2)])
    #expect(gapped[.viewport] == "Viewport 1")
    #expect(gapped[SZPanelID(.viewport, instance: 2)] == "Viewport 2")

    // Down to one again: back to the bare name.
    #expect(SZPanelID.displayTitles(for: [SZPanelID(.viewport, instance: 2)])[SZPanelID(.viewport, instance: 2)]
            == "Viewport")
}

@Test func panelIDOrderingIsKindThenInstance() {
    // The container's ForEach sorts by this — kind blocks in allCases order, instances within.
    let ids: [SZPanelID] = [SZPanelID(.viewport, instance: 1), .chat, .viewport, .nodeEditor]
    #expect(ids.sorted() == [.viewport, SZPanelID(.viewport, instance: 1), .nodeEditor, .chat])
}
