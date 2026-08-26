// SPDX-License-Identifier: AGPL-3.0-only
// Preview-body geometry: the one inset SZNodeLayout adds between header and rows when a card
// effectively previews. Pins the grid invariants (heights stay gridPitch multiples; the inset is an
// even cell count so a toggle can't strand a snapped card's edges mid-cell), the exact row/socket
// shift, the nil-body auto-preview fallback, contract validation of a pinned port, the gate's
// collapse, and prompt-card immunity — the socket/edge misalignment class of bug, headlessly.
//
// The Live Previews gate is the subject here, so every call states it literally rather than going
// through SZLayoutProbe: each assertion names the setting it is about.
import CoreGraphics
import Testing
@testable import SZUI
import SZCore

/// A generated node with one float input and one texture output — the smallest previewable card.
private func textureNode(body: SZNodeBody? = nil) -> SZNode {
    SZNode(kind: .generated, title: "Tex",
           contract: SZNodeContract(
               title: "Tex", sfSymbol: "circle", summary: "s",
               inputs: [SZPort(name: "amount", type: .float)],
               outputs: [SZPort(name: "texture", type: .texture, display: true)]),
           position: SZPoint(x: 0, y: 0), body: body)
}

/// Same shape, no texture output — never previews.
private func scalarNode(body: SZNodeBody? = nil) -> SZNode {
    SZNode(kind: .generated, title: "Num",
           contract: SZNodeContract(
               title: "Num", sfSymbol: "circle", summary: "s",
               inputs: [SZPort(name: "amount", type: .float)],
               outputs: [SZPort(name: "value", type: .float)]),
           position: SZPoint(x: 0, y: 0), body: body)
}

@Suite struct SZNodeLayoutPreviewTests {

    @Test func autoPreviewFallbackAddsExactlyThePreviewInset() {
        let plain = scalarNode()
        let previewing = textureNode()   // nil body + texture output → legacy auto-preview
        #expect(previewing.effectiveBodyMode == .preview)
        #expect(previewing.effectivePreviewPort == "texture")
        #expect(plain.effectiveBodyMode == .none)
        #expect(plain.effectivePreviewPort == nil)
        #expect(SZNodeLayout.height(of: previewing, previewsEnabled: true)
             == SZNodeLayout.height(of: plain, previewsEnabled: true) + SZNodeLayout.previewHeight)
    }

    @Test func previewHeightsStayOnTheGrid() {
        let height = SZNodeLayout.height(of: textureNode(), previewsEnabled: true)
        #expect(height.truncatingRemainder(dividingBy: SZNodeLayout.gridPitch) == 0)
        // Even cell count: node.position is the card CENTER, so toggling the inset moves each
        // edge by previewHeight/2 — even cells keep a snapped card's edges on grid lines
        // through the toggle (odd would strand them mid-cell until the next drag re-snapped).
        #expect(SZNodeLayout.previewHeight
                    .truncatingRemainder(dividingBy: 2 * SZNodeLayout.gridPitch) == 0)
    }

    @Test func rowsAndSocketsShiftByExactlyThePreviewInset() {
        let compact = textureNode(body: SZNodeBody(mode: .none))
        let previewing = textureNode(body: SZNodeBody(mode: .preview, previewPort: "texture"))
        func height(_ n: SZNode) -> CGFloat { SZNodeLayout.height(of: n, previewsEnabled: true) }
        for row in 0..<2 {
            // rowCenterY is CENTER-relative; the card also grows by the inset, so assert in
            // card-TOP space, where rows move by exactly the inset and the header stays put.
            let topCompact = SZNodeLayout.rowCenterY(of: compact, row: row, previewsEnabled: true)
                + height(compact) / 2
            let topPreviewing = SZNodeLayout.rowCenterY(of: previewing, row: row, previewsEnabled: true)
                + height(previewing) / 2
            #expect(topPreviewing - topCompact == SZNodeLayout.previewHeight)
        }
        // The data sockets ride their rows: same shift, in card-top space.
        let sockCompact = SZNodeLayout.socketOffset(of: compact, side: .output, kind: .data,
                                                    port: "texture", previewsEnabled: true)
        let sockPreviewing = SZNodeLayout.socketOffset(of: previewing, side: .output, kind: .data,
                                                       port: "texture", previewsEnabled: true)
        #expect((sockPreviewing.y + height(previewing) / 2)
              - (sockCompact.y + height(compact) / 2) == SZNodeLayout.previewHeight)
        // Flow sockets ride the header, which does NOT move in card-top space.
        #expect(SZNodeLayout.flowY(of: previewing, previewsEnabled: true) + height(previewing) / 2
             == SZNodeLayout.flowY(of: compact, previewsEnabled: true) + height(compact) / 2)
    }

    @Test func canvasModelSocketsIncludeThePreviewInset() {
        // One level above raw layout: the canvas model's socket enumeration (what hit-testing and
        // the edge layer consume) must place an auto-previewing node's data sockets previewHeight
        // lower than a pinned-compact twin's — a canvas-model regression that drops the inset would
        // pass every raw-layout test above.
        let auto = textureNode()                                // nil body → auto-preview
        let compact = textureNode(body: SZNodeBody(mode: .none))
        func outputSocketY(_ node: SZNode) -> CGFloat? {
            SZGraphCanvasModel.sockets(of: node, previewsEnabled: true)
                .first { $0.kind == .data && $0.side == .output }?.point.y
        }
        let autoY = outputSocketY(auto), compactY = outputSocketY(compact)
        #expect(autoY != nil && compactY != nil)
        // Same position (card center), so world-space socket Y shifts by inset/2 relative to
        // the fixed center as the card grows symmetrically.
        #expect(autoY! - compactY! == SZNodeLayout.previewHeight / 2)
    }

    /// With the gate off a preview card is compact, so its edges must meet the sockets on the
    /// SHORTER card — the alignment a mis-threaded call site breaks, and which no suite could
    /// safely assert while the gate was process state.
    @Test func edgesMeetTheirSocketsWithTheGateOff() {
        let source = textureNode(body: SZNodeBody(mode: .preview, previewPort: "texture"))
        var sink = scalarNode()
        sink.position = SZPoint(x: 500, y: 0)
        let graph = SZGraph(nodes: [source, sink],
                            connections: [SZConnection(from: SZPortRef(node: source.id, port: "texture"),
                                                       to: SZPortRef(node: sink.id, port: "amount"),
                                                       kind: .data)])
        for gate in [true, false] {
            let sockets = SZGraphCanvasModel.sockets(in: graph, previewsEnabled: gate)
            let out = sockets.first { $0.nodeID == source.id && $0.kind == .data && $0.side == .output }
            let ends = SZGraphCanvasModel.endpoints(of: graph.connections[0], in: graph,
                                                    previewsEnabled: gate)
            #expect(out != nil && ends != nil)
            #expect(ends?.from == out?.point)
        }
        // And the gate genuinely moves that socket, so the check above is not vacuous.
        let hot = SZGraphCanvasModel.sockets(in: graph, previewsEnabled: true)
            .first { $0.nodeID == source.id && $0.kind == .data && $0.side == .output }?.point.y
        let cold = SZGraphCanvasModel.sockets(in: graph, previewsEnabled: false)
            .first { $0.nodeID == source.id && $0.kind == .data && $0.side == .output }?.point.y
        #expect(hot != cold)
    }

    @Test func explicitNoneBeatsTheAutoPreviewFallback() {
        let pinned = textureNode(body: SZNodeBody(mode: .none))
        #expect(pinned.effectiveBodyMode == .none)
        #expect(SZNodeLayout.previewInset(of: pinned, previewsEnabled: true) == 0)
        #expect(SZNodeLayout.height(of: pinned, previewsEnabled: true)
             == SZNodeLayout.height(of: scalarNode(), previewsEnabled: true))
    }

    @Test func customBodyOwnsItsRegionAndSuppressesThePreview() {
        let custom = textureNode(body: SZNodeBody(mode: .custom, custom: SZCustomCardRef()))
        #expect(custom.effectiveBodyMode == .custom)
        // One body slot: the custom card fills it, so the preview inset is 0 and only the
        // custom inset contributes (default 8 rows).
        #expect(SZNodeLayout.previewInset(of: custom, previewsEnabled: true) == 0)
        #expect(SZNodeLayout.customInset(of: custom) == 8 * SZNodeLayout.gridPitch)
        // A custom body streams no thumb unless the contract asks for a backdrop.
        #expect(custom.effectivePreviewPort == nil)
    }

    @Test func staleOrImpossiblePinsDegradeAgainstTheLiveContract() {
        // A pinned port the contract no longer has (rebuild renamed it) falls back to the
        // preferred texture output — never a permanently blank region for a dead name.
        let stale = textureNode(body: SZNodeBody(mode: .preview, previewPort: "ghost"))
        #expect(stale.effectiveBodyMode == .preview)
        #expect(stale.effectivePreviewPort == "texture")
        // An explicit `.preview` on a node with NO texture outputs degrades to compact: no
        // inset, no watch-set entry (nil port), no GPU passes for an unfillable region.
        let impossible = scalarNode(body: SZNodeBody(mode: .preview, previewPort: "value"))
        #expect(impossible.effectiveBodyMode == .none)
        #expect(impossible.effectivePreviewPort == nil)
        #expect(SZNodeLayout.previewInset(of: impossible, previewsEnabled: true) == 0)
    }

    @Test func previewPortResolvesPinThenDisplayMarkThenFirst() {
        var node = textureNode()
        node.contract?.outputs = [
            SZPort(name: "a", type: .texture),
            SZPort(name: "b", type: .texture, display: true),
        ]
        #expect(node.effectivePreviewPort == "b")          // display-marked wins
        node.contract?.outputs[1].display = nil
        #expect(node.effectivePreviewPort == "a")          // else the first texture output
        node.body = SZNodeBody(mode: .preview, previewPort: "b")
        #expect(node.effectivePreviewPort == "b")          // a valid explicit pin beats both
    }

    @Test func theGateCollapsesEveryPreviewRegion() {
        let auto = textureNode()
        let explicit = textureNode(body: SZNodeBody(mode: .preview, previewPort: "texture"))
        #expect(SZNodeLayout.previewInset(of: auto, previewsEnabled: false) == 0)
        #expect(SZNodeLayout.previewInset(of: explicit, previewsEnabled: false) == 0)
        #expect(SZNodeLayout.height(of: explicit, previewsEnabled: false)
             == SZNodeLayout.height(of: scalarNode(), previewsEnabled: false))
        // The mode survives the gate (it's graph state); only the geometry collapses.
        #expect(explicit.effectiveBodyMode == .preview)
    }

    @Test func promptCardsNeverGrowAPreviewBody() {
        let prompt = SZNode(kind: .prompt, title: "P", position: SZPoint(x: 0, y: 0),
                            body: SZNodeBody(mode: .preview))
        #expect(prompt.effectiveBodyMode == .none)
        #expect(SZNodeLayout.height(of: prompt, previewsEnabled: true) == SZNodeLayout.promptHeight)
    }
}
