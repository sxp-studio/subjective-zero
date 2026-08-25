// SPDX-License-Identifier: AGPL-3.0-only
// Folding a card's plugs: the rows go, the body stays, and the card keeps its TOP edge. The
// invariants that matter are (1) the fold removes a whole number of grid cells, so a snapped card
// stays snapped through it, (2) width never moves, so no wire shifts sideways, and (3) the tier is
// render-only — geometry never reads zoom. `previewsEnabled` is process-global, so this whole suite is
// `.serialized` and pins it: the reads and the one flip must not interleave.
import CoreGraphics
import Testing
@testable import SZUI
import SZCore

private func previewNode(inputs: Int = 3, outputs: Int = 1) -> SZNode {
    SZNode(kind: .generated, title: "Blur",
           contract: SZNodeContract(title: "Blur", sfSymbol: "s", summary: "",
                                    inputs: (0..<inputs).map { SZPort(name: "in\($0)", type: .float) },
                                    outputs: (0..<outputs).map { SZPort(name: "out\($0)", type: .texture) }),
           position: SZPoint(x: 0, y: 0),
           body: SZNodeBody(mode: .preview, previewPort: "out0"))
}

private func folded(_ node: SZNode) -> SZNode {
    var copy = node
    copy.body?.plugs = false
    return copy
}

/// A node with no body region at all: no texture output, no card.
private func bodylessNode() -> SZNode {
    SZNode(kind: .generated, title: "Add",
           contract: SZNodeContract(title: "Add", sfSymbol: "s", summary: "",
                                    inputs: [SZPort(name: "a", type: .float), SZPort(name: "b", type: .float)],
                                    outputs: [SZPort(name: "sum", type: .float)]),
           position: SZPoint(x: 0, y: 0))
}

/// A knob card: a custom card with NO backdrop, so it has no preview of its own.
private func knobCardNode() -> SZNode {
    SZNode(kind: .generated, title: "Knob",
           contract: SZNodeContract(title: "Knob", sfSymbol: "s", summary: "",
                                    inputs: [SZPort(name: "value", type: .float)],
                                    outputs: [SZPort(name: "out", type: .float)],
                                    card: SZCardHints(cols: 6, rows: 4)),
           position: SZPoint(x: 0, y: 0),
           body: SZNodeBody(mode: .custom, custom: SZCustomCardRef(rows: 4)))
}

@Suite(.serialized) struct SZNodeLayoutFoldTests {
    init() { SZNodeLayout.previewsEnabled = true }

    // MARK: - Height and the grid

    @Test func foldingDropsExactlyTheRowBand() {
        let node = previewNode()                       // 3 in + 1 out, 144pt preview
        #expect(SZNodeLayout.height(of: node) == 288)  // 40 + 144 + 4 + 4*24 + 4
        #expect(SZNodeLayout.height(of: folded(node)) == 192)   // 40 + 4 + 144 + 4
        #expect(SZNodeLayout.foldDelta(of: node) == 96)
        #expect(SZNodeLayout.foldDelta(of: folded(node)) == 96) // same both ways, so the toggle reverses
    }

    /// The top-anchor invariant: holding the top edge and moving the centre by foldDelta/2 leaves all
    /// four edges on grid for ANY row count — odd included, which a centre anchor could not do.
    @Test func topAnchoredFoldKeepsEveryEdgeOnGrid() {
        for count in 1...12 {
            let node = previewNode(inputs: count)            // + 1 texture output, so rows = count + 1
            #expect(SZNodeLayout.canFoldPlugs(node))
            let delta = SZNodeLayout.foldDelta(of: node)
            #expect(delta == CGFloat(count + 1) * SZNodeLayout.rowHeight)
            #expect(delta.truncatingRemainder(dividingBy: SZNodeLayout.gridPitch) == 0,
                    "fold must remove whole cells (count \(count))")

            // Snap the expanded card, then fold it holding the top edge.
            let snapped = SZNodeLayout.snappedCenter(CGPoint(x: 13, y: 7),
                                                     size: SZNodeLayout.size(of: node))
            var open = node
            open.position = SZPoint(x: snapped.x, y: snapped.y)
            var shut = folded(open)
            shut.position = SZPoint(x: snapped.x, y: snapped.y - delta / 2)

            let a = SZNodeLayout.cardRect(of: open), b = SZNodeLayout.cardRect(of: shut)
            #expect(a.minY == b.minY, "top edge must not move (count \(count))")
            for edge in [b.minX, b.maxX, b.minY, b.maxY] {
                #expect(edge.truncatingRemainder(dividingBy: SZNodeLayout.gridPitch) == 0,
                        "folded edge \(edge) off grid (count \(count))")
            }
        }
    }

    @Test func widthNeverMoves() {
        let node = previewNode()
        #expect(!SZNodeLayout.showsPlugs(of: folded(node)))   // guard: the fixture really folds
        #expect(SZNodeLayout.width(of: folded(node)) == SZNodeLayout.width(of: node))
    }

    // MARK: - Where the sockets go

    @Test func foldedSocketsStackInPortOrderAtRowPitch() {
        let node = folded(previewNode())               // card spans y ∈ [-96, +96]
        let ys = (0..<3).map { SZNodeLayout.socketOffset(of: node, side: .input, kind: .data, port: "in\($0)").y }
        #expect(ys == [-4, 20, 44])                    // centred in the 152pt region below the header
        #expect(zip(ys, ys.dropFirst()).allSatisfy { $1 - $0 == SZNodeLayout.rowHeight })
        // The single output centres on the same region.
        #expect(SZNodeLayout.socketOffset(of: node, side: .output, kind: .data, port: "out0").y == 20)
        // Every dot stays inside the card.
        let rect = SZNodeLayout.cardRect(of: node)
        for y in ys { #expect(y > rect.minY && y < rect.maxY) }
    }

    @Test func aCrowdedCardSqueezesRatherThanSpills() {
        let node = folded(previewNode(inputs: 12))
        let rect = SZNodeLayout.cardRect(of: node)
        let ys = (0..<12).map { SZNodeLayout.socketOffset(of: node, side: .input, kind: .data, port: "in\($0)").y }
        for y in ys { #expect(y >= rect.minY && y <= rect.maxY) }
        #expect(ys == ys.sorted(), "port order must survive the fold")
    }

    @Test func flowSocketsAndSidesAreUnaffected() {
        let node = folded(previewNode())
        // Flow rides the header, which the fold never touches.
        #expect(SZNodeLayout.socketOffset(of: node, side: .input, kind: .flow, port: "").y
                    == SZNodeLayout.flowY(of: node))
        #expect(SZNodeLayout.socketOffset(of: node, side: .input, kind: .data, port: "in0").x
                    == -SZNodeLayout.width(of: node) / 2)
        #expect(SZNodeLayout.socketOffset(of: node, side: .output, kind: .data, port: "out0").x
                    == SZNodeLayout.width(of: node) / 2)
    }

    /// Hiding is paint, not model: the connectable and drawn sets are untouched, so snapping,
    /// occlusion and validity keep working on a folded card.
    @Test func theSocketSetIsUnchangedByTheFold() {
        let node = previewNode()
        #expect(SZGraphCanvasModel.sockets(of: folded(node)).count == SZGraphCanvasModel.sockets(of: node).count)
        #expect(SZGraphCanvasModel.connectableSockets(of: folded(node)).count
                    == SZGraphCanvasModel.connectableSockets(of: node).count)
    }

    // MARK: - When a fold is offered

    @Test func aCardWithNothingToShowCannotFold() {
        let bare = bodylessNode()
        #expect(!SZNodeLayout.canFoldPlugs(bare))
        // Even with the flag set, it keeps its rows rather than becoming a title chip.
        var pinned = bare
        pinned.body = SZNodeBody(mode: .none, plugs: false)
        #expect(SZNodeLayout.showsPlugs(of: pinned))
        #expect(SZNodeLayout.height(of: pinned) == SZNodeLayout.height(of: bare))
        #expect(SZNodeLayout.foldDelta(of: pinned) == 0)
    }

    @Test func aCustomCardWithNoBackdropStillFolds() {
        let knob = knobCardNode()
        #expect(SZNodeLayout.canFoldPlugs(knob))          // the card IS the body, no preview needed
        #expect(knob.effectivePreviewPort == nil)
        // 40 + 4 + 96 (4 rows of card) + 4
        #expect(SZNodeLayout.height(of: folded(knob)) == 144)
    }

    // MARK: - The tier

    @Test func tierResolvesDistanceBeforeIntent() {
        let open = previewNode(), shut = folded(open)
        #expect(SZNodeLayout.tier(of: open, zoomedOut: false) == .full)
        #expect(SZNodeLayout.tier(of: shut, zoomedOut: false) == .picture)
        // From orbit a folded card and an expanded one render the same way.
        #expect(SZNodeLayout.tier(of: open, zoomedOut: true) == .tile)
        #expect(SZNodeLayout.tier(of: shut, zoomedOut: true) == .tile)
    }

    /// With previews off a `.preview` card has no rendered body, so it must come back to its rows
    /// rather than collapse to a bare title chip. Keyed on the RENDERED height, not the mode.
    @Test func previewsOffTakesTheFoldAway() {
        let node = folded(previewNode())
        #expect(!SZNodeLayout.showsPlugs(of: node))
        SZNodeLayout.previewsEnabled = false
        defer { SZNodeLayout.previewsEnabled = true }
        #expect(node.effectiveBodyMode == .preview)      // the mode is unchanged...
        #expect(!SZNodeLayout.canFoldPlugs(node))        // ...but there is nothing to fold to
        #expect(SZNodeLayout.showsPlugs(of: node))
        let expanded: CGFloat = 144   // 40 header + 4 pad + 4 rows * 24 + 4 pad
        #expect(SZNodeLayout.height(of: node) == expanded)
    }
}
