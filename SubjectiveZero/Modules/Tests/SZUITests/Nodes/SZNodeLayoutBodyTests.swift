// SPDX-License-Identifier: AGPL-3.0-only
// Custom-card body geometry: the card is a REGION between header and rows (like the preview); the
// generated port rows stay, minus the plumbing inputs the card owns; the region's footprint comes
// from the committed cols/rows (else the contract's `card` hints); a backdrop card's rows are
// what `backdropRows` computes for the render aspect (the host commits them through auto-size).
// `previewsEnabled` is process-global, so these run `.serialized` and pin it per test.
import CoreGraphics
import Testing
@testable import SZUI
import SZCore

private func customNode(rows: Int? = nil, cols: Int? = nil, pinned: Bool? = nil,
                        inputs: [SZPort] = [SZPort(name: "value", type: .float)],
                        outputs: [SZPort] = [SZPort(name: "out", type: .float)],
                        hints: SZCardHints? = nil) -> SZNode {
    SZNode(kind: .generated, title: "T",
           contract: SZNodeContract(title: "T", sfSymbol: "s", summary: "", inputs: inputs, outputs: outputs,
                                    card: hints),
           position: SZPoint(x: 0, y: 0),
           body: SZNodeBody(mode: .custom, custom: SZCustomCardRef(cols: cols, rows: rows, pinned: pinned)))
}

/// corner-pin's shape: a texture in/out with a backdrop, four card-owned corners.
private func cornerPinNode(pinned: Bool? = nil, rows: Int? = nil) -> SZNode {
    customNode(rows: rows, pinned: pinned,
               inputs: [SZPort(name: "input", type: .texture)] + ["tl", "tr", "br", "bl"].map { SZPort(name: $0, type: .float2) },
               outputs: [SZPort(name: "output", type: .texture, display: true)],
               hints: SZCardHints(cols: 12, rows: 8, backdrop: "output", plumbing: ["tl", "tr", "br", "bl"]))
}

@Suite(.serialized) struct SZNodeLayoutCustomBodyTests {
    init() { SZNodeLayout.previewsEnabled = true }

    @Test func customCardIsARegionAboveTheGeneratedRows() {
        // 8-row region → header 40 + region 192 + top pad 4 + 2 rows (value, out) 48 + bottom pad 4 = 288.
        let node = customNode()
        #expect(SZNodeLayout.customInset(of: node) == 192)
        #expect(SZNodeLayout.height(of: node) == 288)
        // Rows still count: more ports, taller card (the region doesn't swallow them).
        var many = customNode()
        many.contract?.inputs += (0..<2).map { SZPort(name: "p\($0)", type: .float) }
        #expect(SZNodeLayout.height(of: many) == CGFloat(288 + 48))
        // Grid invariant: height is a multiple of the pitch.
        #expect(SZNodeLayout.height(of: node).truncatingRemainder(dividingBy: SZNodeLayout.gridPitch) == 0)
        // Rows sit BELOW the region: first row center = top + header + region + pad + 12.
        #expect(SZNodeLayout.rowCenterY(of: node, row: 0) == CGFloat(-144 + 40 + 192 + 4 + 12))
    }

    @Test func customRowsClampToTheSharedBounds() {
        #expect(SZNodeLayout.customRows(of: customNode(rows: 5)) == 5)
        #expect(SZNodeLayout.customRows(of: customNode(rows: 1)) == 2)     // floor
        #expect(SZNodeLayout.customRows(of: customNode(rows: 99)) == 24)   // ceiling
        // A non-custom node has no custom rows.
        var plain = customNode(); plain.body = nil
        #expect(SZNodeLayout.customRows(of: plain) == nil)
    }

    @Test func customWidthIsAtLeastTheDeclaredColsAndStillFitsTheRows() {
        #expect(SZNodeLayout.width(of: customNode()) == CGFloat(9 * 24))            // default 9 cells
        #expect(SZNodeLayout.width(of: customNode(cols: 10)) == 240)
        #expect(SZNodeLayout.width(of: customNode(cols: 2)) == CGFloat(9 * 24))     // floor 6, but the base width wins
        #expect(SZNodeLayout.width(of: customNode(cols: 20)) == CGFloat(20 * 24))   // beyond the content cap
        #expect(SZNodeLayout.width(of: customNode(cols: 99)) == CGFloat(24 * 24))   // ceiling
    }

    @Test func contractHintsSeedTheFootprintUntilTheBodyCommitsOne() {
        let hinted = customNode(hints: SZCardHints(cols: 12, rows: 6))
        #expect(SZNodeLayout.width(of: hinted) == CGFloat(12 * 24))
        #expect(SZNodeLayout.customRows(of: hinted) == 6)
        let committed = customNode(rows: 10, cols: 8, hints: SZCardHints(cols: 12, rows: 6))
        #expect(SZNodeLayout.width(of: committed) == CGFloat(9 * 24))   // 8 < base 9 cells
        #expect(SZNodeLayout.customRows(of: committed) == 10)
        #expect(SZNodeLayout.customRows(of: customNode(hints: SZCardHints(rows: 99))) == 24)
    }

    @Test func plumbingInputsHaveNoRowAndNoSocketWhileTheCardShows() {
        let node = cornerPinNode()
        #expect(SZNodeLayout.isPlumbing(node, port: "tl"))
        #expect(!SZNodeLayout.isPlumbing(node, port: "input"))
        #expect(SZNodeLayout.rowInputs(of: node).map(\.name) == ["input"])
        // Sockets: flow in/out + `input` + `output` only.
        let data = SZGraphCanvasModel.sockets(of: node).filter { $0.kind == .data }
        #expect(data.map(\.port) == ["input", "output"])
        // The `input` row is the first (and only) input row; `output` follows it.
        #expect(SZNodeLayout.socketOffset(of: node, side: .input, kind: .data, port: "input").y
                == SZNodeLayout.rowCenterY(of: node, row: 0))
        #expect(SZNodeLayout.socketOffset(of: node, side: .output, kind: .data, port: "output").y
                == SZNodeLayout.rowCenterY(of: node, row: 1))
        // A stray edge to a plumbing port lands on the region's edge, mid-height (never the flow dot).
        let stray = SZNodeLayout.socketOffset(of: node, side: .input, kind: .data, port: "br")
        #expect(stray.y == -SZNodeLayout.height(of: node) / 2 + 40 + SZNodeLayout.customInset(of: node) / 2)
        // Rows shown again (body none) → nothing is plumbing; every port has its row + dot.
        var rows = node; rows.body = SZNodeBody(mode: .none)
        #expect(!SZNodeLayout.isPlumbing(rows, port: "tl"))
        #expect(SZGraphCanvasModel.sockets(of: rows).filter { $0.kind == .data && $0.side == .input }.count == 5)
    }

    @Test func backdropRowsFollowTheRenderAspect() {
        // Declared 12 cols: the 272-wide image at 16:10 is 170 tall → 170 + 42 chrome = 212 → 9 rows
        // (nearest); the card keeps its 12-cell width. Until the host commits those rows the region
        // is the hint's 8.
        let node = cornerPinNode()
        #expect(SZNodeLayout.customRows(of: node) == 8)
        #expect(SZNodeLayout.backdropRows(of: node, renderAspect: 1.6) == 9)
        #expect(SZNodeLayout.width(of: node) == CGFloat(12 * 24))
        let body = CGSize(width: 288, height: 9 * SZNodeLayout.gridPitch)
        let rect = SZNodeLayout.customBackdropRect(body: body, render: CGSize(width: 1600, height: 1000))!
        #expect(rect == CGRect(x: 8, y: 8, width: 272, height: 170))
        // A wide render shrinks the region (no letterbox band); a tall one grows it (clamped at 24).
        #expect(SZNodeLayout.backdropRows(of: node, renderAspect: 3.5) == 5)   // 78 tall → 120 → 5 rows
        let wide = SZNodeLayout.customBackdropRect(body: CGSize(width: 288, height: 120), render: CGSize(width: 3500, height: 1000))!
        #expect(wide == CGRect(x: 8, y: 8, width: 272, height: 77))
        #expect(SZNodeLayout.backdropRows(of: node, renderAspect: 0.5) == 24)  // 544 tall → clamped
        // Committed rows win over the hint (what the host's auto-size lands).
        #expect(SZNodeLayout.customRows(of: cornerPinNode(rows: 5)) == 5)
    }

    @Test func backdropRectSitsOnTheTopMarginWithTheFooterBelow() {
        // 288×216 body (9 rows), 8pt margins + 8pt gap + 20pt footer + 6pt bottom → 272×174 for the
        // image; 16:10 fits width-first: 272×170 at (8, 8); the footer band sits at the bottom.
        let rect = SZNodeLayout.customBackdropRect(body: CGSize(width: 288, height: 216),
                                                   render: CGSize(width: 1280, height: 800))
        #expect(rect == CGRect(x: 8, y: 8, width: 272, height: 170))
        #expect(rect!.maxY + SZNodeLayout.backdropChrome - SZNodeLayout.backdropMargin <= 216)
        // A tall render fits height-first and centers horizontally.
        let tall = SZNodeLayout.customBackdropRect(body: CGSize(width: 288, height: 216),
                                                   render: CGSize(width: 800, height: 1600))
        #expect(tall == CGRect(x: 101, y: 8, width: 87, height: 174))
        // Degenerate sizes yield no backdrop instead of a zero/negative rect.
        #expect(SZNodeLayout.customBackdropRect(body: CGSize(width: 10, height: 10), render: CGSize(width: 1, height: 1)) == nil)
        #expect(SZNodeLayout.customBackdropRect(body: CGSize(width: 288, height: 192), render: .zero) == nil)
    }

    @Test func flowSocketsKeepRidingTheHeader() {
        let node = customNode(rows: 8)
        let flow = SZNodeLayout.socketOffset(of: node, side: .input, kind: .flow, port: "in")
        #expect(flow.y == -SZNodeLayout.height(of: node) / 2 + SZNodeLayout.headerHeight / 2)
    }

    @Test func effectiveCustomIsTheModeAloneAndNeedsNoTexture() {
        var node = customNode()
        #expect(node.effectiveBodyMode == .custom)
        node.body = SZNodeBody(mode: .custom)          // no committed footprint → still custom (defaults)
        #expect(node.effectiveBodyMode == .custom)
        // Custom does NOT require a texture output (a knob card drives a float).
        #expect(customNode().contract?.outputs.contains { $0.type == .texture } == false)
    }

    @Test func customBackdropPortComesFromTheContractHint() {
        let outputs = [SZPort(name: "output", type: .texture, display: true), SZPort(name: "level", type: .float)]
        // No hint → no thumb streams for a custom body, even with a texture output.
        #expect(customNode(outputs: outputs).effectivePreviewPort == nil)
        // A hint naming a texture output → that port streams under the card.
        #expect(customNode(outputs: outputs, hints: SZCardHints(backdrop: "output")).effectivePreviewPort == "output")
        // A hint naming a non-texture (or vanished) port degrades to none — never a blank region.
        #expect(customNode(outputs: outputs, hints: SZCardHints(backdrop: "level")).effectivePreviewPort == nil)
        #expect(customNode(outputs: outputs, hints: SZCardHints(backdrop: "ghost")).effectivePreviewPort == nil)
    }
}
