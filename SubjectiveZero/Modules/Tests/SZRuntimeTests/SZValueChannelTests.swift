// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import Metal
@testable import SZRuntime
@testable import SZCore

/// ABI v5: a node's non-texture OUTPUT value flows across a `.data` edge into a downstream node's
/// input. An upstream node emits a `float` with `ctx.setOutputFloats`; a downstream node reads it as a
/// scalar input and renders it — proven by reading the rendered pixels back through the real capture path.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func outputValueFlowsAcrossDataEdgeToDownstreamInput() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))

    let source = SZNodeID()
    let sink = SZNodeID()
    let project = SZProject(
        name: "value-channel",
        graph: SZGraph(
            nodes: [
                // Upstream: emits a float OUTPUT (no texture output needed).
                SZNode(id: source, kind: .generated, title: "source",
                       contract: SZNodeContract(title: "source", sfSymbol: "", summary: "",
                                                inputs: [],
                                                outputs: [SZPort(name: "level", type: .float)]),
                       position: SZPoint(x: 0, y: 0)),
                // Downstream: reads `gain` (fed from upstream `level`) and clears to that gray.
                SZNode(id: sink, kind: .generated, title: "sink",
                       contract: SZNodeContract(title: "sink", sfSymbol: "", summary: "",
                                                inputs: [SZPort(name: "gain", type: .float, def: .float(0))],
                                                outputs: [SZPort(name: "color", type: .texture, display: true)]),
                       position: SZPoint(x: 1, y: 0)),
            ],
            connections: [
                SZConnection(from: SZPortRef(node: source, port: "level"),
                             to: SZPortRef(node: sink, port: "gain"), kind: .data),
            ],
            renderEndpoint: SZPortRef(node: sink, port: "color")))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-value-\(UUID().uuidString)").appending(path: "value.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)

    // Upstream emits 0.75 on its `level` output every frame.
    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            ctx.setOutputFloats("level", [0.75])
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: source), atomically: true, encoding: .utf8)

    // Downstream clears the output to gray = its `gain` input — which it receives ONLY via the data edge
    // from upstream (its own default is 0). A non-zero gray proves the value crossed the edge.
    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            guard let out = ctx.outputTexture("color") else { return }
            let v = Double(ctx.inputFloat("gain") ?? 0)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = out
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: v, green: v, blue: v, alpha: 1.0)
            pass.colorAttachments[0].storeAction = .store
            ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: sink), atomically: true, encoding: .utf8)

    try runtime.loadProject(at: dir)

    // 0.75 emitted upstream → received as `gain` downstream → gray ≈ 191.
    let pixel = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(abs(Int(pixel.r) - 191) <= 2)
}
