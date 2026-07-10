// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import Metal
@testable import SZRuntime
@testable import SZCore

/// `floatArray` channel: a node emits a variable-length `[Float]` (audio samples / an FFT spectrum) via
/// `ctx.setOutputFloats`, and a downstream node reads the WHOLE array via `ctx.inputFloatArray` — the
/// connected-value channel reused for arrays (no GPU buffer). This exercises the resolver's full-length
/// return + the accessor's grow-and-retry: the array (5000) exceeds the accessor's 4096 starting capacity,
/// so a correct read must grow and recover the tail. Proven by rendering the array's LAST element back.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func floatArrayFlowsAcrossDataEdgeAndGrowsPastDefaultCapacity() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))

    let source = SZNodeID()
    let sink = SZNodeID()
    let project = SZProject(
        name: "float-array-channel",
        graph: SZGraph(
            nodes: [
                // Upstream: emits a 5000-long array; everything is 0.25 except the LAST element = 0.75.
                SZNode(id: source, kind: .generated, title: "source",
                       contract: SZNodeContract(title: "source", sfSymbol: "", summary: "",
                                                inputs: [],
                                                outputs: [SZPort(name: "samples", type: .floatArray)]),
                       position: SZPoint(x: 0, y: 0)),
                // Downstream: reads the full array and clears to gray = its LAST element. A truncated read
                // (capped at 4096) would see 0.25 at index 4095 → gray 64; the correct full read sees the
                // real tail 0.75 → gray 191.
                SZNode(id: sink, kind: .generated, title: "sink",
                       contract: SZNodeContract(title: "sink", sfSymbol: "", summary: "",
                                                inputs: [SZPort(name: "samples", type: .floatArray)],
                                                outputs: [SZPort(name: "color", type: .texture, display: true)]),
                       position: SZPoint(x: 1, y: 0)),
            ],
            connections: [
                SZConnection(from: SZPortRef(node: source, port: "samples"),
                             to: SZPortRef(node: sink, port: "samples"), kind: .data),
            ],
            renderEndpoint: SZPortRef(node: sink, port: "color")))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-floatarray-\(UUID().uuidString)").appending(path: "fa.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)

    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            var a = [Float](repeating: 0.25, count: 5000)
            a[a.count - 1] = 0.75
            ctx.setOutputFloats("samples", a)
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: source), atomically: true, encoding: .utf8)

    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            guard let out = ctx.outputTexture("color") else { return }
            let arr = ctx.inputFloatArray("samples") ?? []
            let v = Double(arr.last ?? 0)
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

    // Last element 0.75 crossed the full 5000-length array → gray ≈ 191 (not 64, which a 4096-cap read gives).
    let pixel = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(abs(Int(pixel.r) - 191) <= 2)
}
