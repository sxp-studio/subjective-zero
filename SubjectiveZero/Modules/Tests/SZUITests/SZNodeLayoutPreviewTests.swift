// SPDX-License-Identifier: AGPL-3.0-only
// Preview-body geometry: the ONE inset SZNodeLayout adds between header and rows when a card
// effectively previews. Pins the grid invariants (heights stay gridPitch multiples; the inset is an
// EVEN cell count so a toggle can't strand a snapped card's edges mid-cell), the exact row/socket
// shift, the nil-body auto-preview fallback, contract validation of a pinned port, the global gate's
// collapse, and prompt-card immunity — the socket/edge misalignment class of bug, headlessly.
//
// `.serialized`: several tests flip `SZNodeLayout.previewsEnabled`, which is PROCESS-GLOBAL — under
// Swift Testing's default parallel execution the flips would race any test reading preview-dependent
// geometry. Every gate-dependent test therefore lives in this one suite.
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

/// Run `body` with the global previews gate pinned to `enabled`, restoring the prior value after —
/// safe here only because the whole suite is `.serialized`.
private func withPreviewsEnabled<T>(_ enabled: Bool, _ body: () -> T) -> T {
    let prior = SZNodeLayout.previewsEnabled
    SZNodeLayout.previewsEnabled = enabled
    defer { SZNodeLayout.previewsEnabled = prior }
    return body()
}

@Suite(.serialized) struct SZNodeLayoutPreviewTests {

    @Test func autoPreviewFallbackAddsExactlyThePreviewInset() {
        withPreviewsEnabled(true) {
            let plain = scalarNode()
            let previewing = textureNode()   // nil body + texture output → legacy auto-preview
            #expect(previewing.effectiveBodyMode == .preview)
            #expect(previewing.effectivePreviewPort == "texture")
            #expect(plain.effectiveBodyMode == .none)
            #expect(plain.effectivePreviewPort == nil)
            #expect(SZNodeLayout.height(of: previewing)
                 == SZNodeLayout.height(of: plain) + SZNodeLayout.previewHeight)
        }
    }

    @Test func previewHeightsStayOnTheGrid() {
        withPreviewsEnabled(true) {
            let height = SZNodeLayout.height(of: textureNode())
            #expect(height.truncatingRemainder(dividingBy: SZNodeLayout.gridPitch) == 0)
            // EVEN cell count: node.position is the card CENTER, so toggling the inset moves each
            // edge by previewHeight/2 — even cells keep a snapped card's edges on grid lines
            // through the toggle (odd would strand them mid-cell until the next drag re-snapped).
            #expect(SZNodeLayout.previewHeight
                        .truncatingRemainder(dividingBy: 2 * SZNodeLayout.gridPitch) == 0)
        }
    }

    @Test func rowsAndSocketsShiftByExactlyThePreviewInset() {
        withPreviewsEnabled(true) {
            let off = textureNode(body: SZNodeBody(mode: .none))
            let on = textureNode(body: SZNodeBody(mode: .preview, previewPort: "texture"))
            for row in 0..<2 {
                // rowCenterY is CENTER-relative; the card also grows by the inset, so assert in
                // card-TOP space, where rows move by exactly the inset and the header stays put.
                let topOff = SZNodeLayout.rowCenterY(of: off, row: row) + SZNodeLayout.height(of: off) / 2
                let topOn = SZNodeLayout.rowCenterY(of: on, row: row) + SZNodeLayout.height(of: on) / 2
                #expect(topOn - topOff == SZNodeLayout.previewHeight)
            }
            // The data sockets ride their rows: same shift, in card-top space.
            let sockOff = SZNodeLayout.socketOffset(of: off, side: .output, kind: .data, port: "texture")
            let sockOn = SZNodeLayout.socketOffset(of: on, side: .output, kind: .data, port: "texture")
            #expect((sockOn.y + SZNodeLayout.height(of: on) / 2)
                  - (sockOff.y + SZNodeLayout.height(of: off) / 2) == SZNodeLayout.previewHeight)
            // Flow sockets ride the header, which does NOT move in card-top space.
            #expect(SZNodeLayout.flowY(of: on) + SZNodeLayout.height(of: on) / 2
                 == SZNodeLayout.flowY(of: off) + SZNodeLayout.height(of: off) / 2)
        }
    }

    @Test func canvasModelSocketsIncludeThePreviewInset() {
        // One level above raw layout: the canvas model's socket enumeration (what hit-testing and
        // the edge layer consume) must place an auto-previewing node's data sockets previewHeight
        // lower than a pinned-compact twin's — a canvas-model regression that drops the inset would
        // pass every raw-layout test above.
        withPreviewsEnabled(true) {
            let auto = textureNode()                                // nil body → auto-preview
            let compact = textureNode(body: SZNodeBody(mode: .none))
            func outputSocketY(_ node: SZNode) -> CGFloat? {
                SZGraphCanvasModel.sockets(of: node)
                    .first { $0.kind == .data && $0.side == .output }?.point.y
            }
            let autoY = outputSocketY(auto), compactY = outputSocketY(compact)
            #expect(autoY != nil && compactY != nil)
            // Same position (card center), so world-space socket Y shifts by inset/2 relative to
            // the fixed center as the card grows symmetrically.
            #expect(autoY! - compactY! == SZNodeLayout.previewHeight / 2)
        }
    }

    @Test func explicitNoneBeatsTheAutoPreviewFallback() {
        withPreviewsEnabled(true) {
            let pinned = textureNode(body: SZNodeBody(mode: .none))
            #expect(pinned.effectiveBodyMode == .none)
            #expect(SZNodeLayout.previewInset(of: pinned) == 0)
            #expect(SZNodeLayout.height(of: pinned) == SZNodeLayout.height(of: scalarNode()))
        }
    }

    @Test func customBodyRendersCompactUntilCustomCardsLand() {
        withPreviewsEnabled(true) {
            let custom = textureNode(body: SZNodeBody(mode: .custom,
                                                      custom: SZCustomCardRef(artifact: "knob")))
            #expect(custom.effectiveBodyMode == .none)
            #expect(SZNodeLayout.previewInset(of: custom) == 0)
        }
    }

    @Test func staleOrImpossiblePinsDegradeAgainstTheLiveContract() {
        withPreviewsEnabled(true) {
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
            #expect(SZNodeLayout.previewInset(of: impossible) == 0)
        }
    }

    @Test func previewPortResolvesPinThenDisplayMarkThenFirst() {
        withPreviewsEnabled(true) {
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
    }

    @Test func globalGateCollapsesEveryPreviewRegion() {
        withPreviewsEnabled(false) {
            let auto = textureNode()
            let explicit = textureNode(body: SZNodeBody(mode: .preview, previewPort: "texture"))
            #expect(SZNodeLayout.previewInset(of: auto) == 0)
            #expect(SZNodeLayout.previewInset(of: explicit) == 0)
            #expect(SZNodeLayout.height(of: explicit) == SZNodeLayout.height(of: scalarNode()))
            // The MODE survives the gate (it's graph state); only the geometry collapses.
            #expect(explicit.effectiveBodyMode == .preview)
        }
    }

    @Test func promptCardsNeverGrowAPreviewBody() {
        withPreviewsEnabled(true) {
            let prompt = SZNode(kind: .prompt, title: "P", position: SZPoint(x: 0, y: 0),
                                body: SZNodeBody(mode: .preview))
            #expect(prompt.effectiveBodyMode == .none)
            #expect(SZNodeLayout.height(of: prompt) == SZNodeLayout.promptHeight)
        }
    }
}
