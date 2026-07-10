// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import Metal
@testable import SZRuntime
@testable import SZCore

/// ABI v3: a node reads a scalar input value at runtime. The value seeds from the contract's
/// `default`, and `setInputValue` overrides it live (no recompile) — proven by reading the rendered
/// pixels back through the real capture path.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func scalarInputSeedsFromDefaultAndOverridesLive() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))

    let nodeID = SZNodeID()
    let project = SZProject(
        name: "scalar",
        graph: SZGraph(
            nodes: [SZNode(id: nodeID, kind: .generated, title: "scalar",
                           contract: SZNodeContract(title: "scalar", sfSymbol: "", summary: "",
                                                    inputs: [SZPort(name: "level", type: .float, def: .float(0.25))],
                                                    outputs: [SZPort(name: "color", type: .texture, display: true)]),
                           position: SZPoint(x: 0, y: 0))],
            connections: [],
            renderEndpoint: SZPortRef(node: nodeID, port: "color")))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-scalar-\(UUID().uuidString)").appending(path: "scalar.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)

    // Clears the output to a gray = the `level` scalar input (read via the v3 ABI channel).
    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            guard let out = ctx.outputTexture("color") else { return }
            let v = Double(ctx.inputFloat("level") ?? 0)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = out
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: v, green: v, blue: v, alpha: 1.0)
            pass.colorAttachments[0].storeAction = .store
            ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: nodeID), atomically: true, encoding: .utf8)

    try runtime.loadProject(at: dir)

    // Seeded from the contract default 0.25 → gray ≈ 64.
    let seeded = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(abs(Int(seeded.r) - 64) <= 2)

    // Live override 0.75 → gray ≈ 191, with no recompile/reload.
    runtime.setInputValue(node: nodeID, port: "level", floats: [0.75])
    let overridden = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(abs(Int(overridden.r) - 191) <= 2)
}
