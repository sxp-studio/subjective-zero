// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import Metal
@testable import SZRuntime
@testable import SZCore

/// ABI v4: a node reads a string/enum input value at runtime via `ctx.inputString`. The value
/// seeds from the contract's `default`, and `setInputString` overrides it live (no recompile) — proven by
/// reading the rendered pixels back through the real capture path.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func stringInputSeedsFromDefaultAndOverridesLive() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))

    let nodeID = SZNodeID()
    let project = SZProject(
        name: "string",
        graph: SZGraph(
            nodes: [SZNode(id: nodeID, kind: .generated, title: "string",
                           contract: SZNodeContract(title: "string", sfSymbol: "", summary: "",
                                                    inputs: [SZPort(name: "mode", type: .enumeration,
                                                                    ui: SZPortUI(kind: .dropdown), def: .enumeration("white"))],
                                                    outputs: [SZPort(name: "color", type: .texture, display: true)]),
                           position: SZPoint(x: 0, y: 0))],
            connections: [],
            renderEndpoint: SZPortRef(node: nodeID, port: "color")))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-string-\(UUID().uuidString)").appending(path: "string.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)

    // Clears the output to white when `mode == "white"`, else black (read via the v4 string ABI channel).
    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            guard let out = ctx.outputTexture("color") else { return }
            let v = (ctx.inputString("mode") == "white") ? 1.0 : 0.0
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

    // Seeded from the contract default "white" → white (≈ 255).
    let seeded = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(Int(seeded.r) >= 250)

    // Live override "black" → black (≈ 0), with no recompile/reload.
    runtime.setInputString(node: nodeID, port: "mode", string: "black")
    let overridden = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(Int(overridden.r) <= 5)
}
