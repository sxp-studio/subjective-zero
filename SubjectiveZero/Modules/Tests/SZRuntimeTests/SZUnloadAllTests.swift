// SPDX-License-Identifier: AGPL-3.0-only
// `unloadAll` tears every live node down and leaves the loop holding an empty graph: no module stays
// loaded, and a frame after it renders nothing without throwing.
import Foundation
import Metal
import Testing
@testable import SZRuntime
@testable import SZCore

private let solidSource = """
import Metal
final class Node: SZNode {
    func update(_ ctx: SZFrameContext) {
        guard let out = ctx.outputTexture("color") else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }
}
enum SZNodeMain { static func make() -> SZNode { Node() } }
"""

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func unloadAllDropsEveryNodeAndRendersNothing() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let id = SZNodeID()
    let project = SZProject(
        name: "unload",
        graph: SZGraph(
            nodes: [SZNode(id: id, kind: .generated, title: "Solid",
                           contract: SZNodeContract(title: "Solid", sfSymbol: "", summary: "",
                                                    outputs: [SZPort(name: "color", type: .texture, display: true)]),
                           position: SZPoint(x: 0, y: 0))],
            renderEndpoint: SZPortRef(node: id, port: "color")))
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-unload-\(UUID().uuidString)").appending(path: "g.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)
    let source = SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: id, target: .native)
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try solidSource.write(to: source, atomically: true, encoding: .utf8)

    try runtime.loadProject(at: dir)
    #expect(runtime.isNodeLoaded(id))
    #expect(try #require(runtime.captureFrame()?.pixel(x: 8, y: 8)).r == 255)

    try runtime.unloadAll()
    #expect(!runtime.isNodeLoaded(id))
    runtime.renderFrame()                    // an empty schedule encodes nothing and must not trap
    #expect(runtime.captureFrame() == nil)   // no endpoint, so nothing to read back

    // The runtime is still usable: the same project loads again from scratch.
    try runtime.loadProject(at: dir)
    #expect(runtime.isNodeLoaded(id))
}
