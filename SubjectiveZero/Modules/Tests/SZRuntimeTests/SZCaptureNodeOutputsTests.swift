// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import Metal
@testable import SZRuntime
@testable import SZCore

/// The node-preview capture half (`captureNodeOutputs`): after a frame has encoded, a node's pooled
/// output reads back as a DOWNSCALED snapshot (long edge ≤ maxDimension, aspect preserved, real
/// pixels), and a port nothing ever wrote reads back as nil — absence, not a fabricated blank.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func capturesDownscaledNodeOutputAndNilForUnwritten() throws {
    let runtime = try requireRuntime(renderSize: (width: 64, height: 32))

    let nodeID = SZNodeID()
    let project = SZProject(
        name: "solid",
        graph: SZGraph(
            nodes: [SZNode(id: nodeID, kind: .generated, title: "solid",
                           contract: SZNodeContract(title: "solid", sfSymbol: "", summary: "",
                                                    outputs: [SZPort(name: "color", type: .texture, display: true)]),
                           position: SZPoint(x: 0, y: 0))],
            connections: [],
            renderEndpoint: SZPortRef(node: nodeID, port: "color")))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-thumbs-\(UUID().uuidString)").appending(path: "solid.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)

    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            guard let out = ctx.outputTexture("color") else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = out
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 1.0, green: 0.5, blue: 0.25, alpha: 1.0)
            pass.colorAttachments[0].storeAction = .store
            ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: nodeID), atomically: true, encoding: .utf8)

    try runtime.loadProject(at: dir)
    _ = try #require(runtime.captureFrame())   // encode a frame so the pool holds the node's output

    let thumbs = runtime.captureNodeOutputs(
        [(node: nodeID, port: "color"), (node: nodeID, port: "ghost")], maxDimension: 16)
    #expect(thumbs.count == 2)

    let thumb = try #require(thumbs[0])
    #expect(thumb.width == 16)    // 64×32 → long edge capped at 16…
    #expect(thumb.height == 8)    // …aspect preserved
    let center = try #require(thumb.pixel(x: 8, y: 4))
    #expect(isNear(center.r, 255)) // 1.0
    #expect(isNear(center.g, 128)) // 0.5
    #expect(isNear(center.b, 64))  // 0.25

    #expect(thumbs[1] == nil)      // never-written port: absent, not a blank
}

/// A dimension the source already fits inside never upscales (scale clamps at 1).
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func captureNeverUpscales() throws {
    let runtime = try requireRuntime(renderSize: (width: 8, height: 8))

    let nodeID = SZNodeID()
    let project = SZProject(
        name: "tiny",
        graph: SZGraph(
            nodes: [SZNode(id: nodeID, kind: .generated, title: "tiny",
                           contract: SZNodeContract(title: "tiny", sfSymbol: "", summary: "",
                                                    outputs: [SZPort(name: "color", type: .texture, display: true)]),
                           position: SZPoint(x: 0, y: 0))],
            connections: [],
            renderEndpoint: SZPortRef(node: nodeID, port: "color")))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-thumbs-\(UUID().uuidString)").appending(path: "tiny.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)

    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            guard let out = ctx.outputTexture("color") else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = out
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 1, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: nodeID), atomically: true, encoding: .utf8)

    try runtime.loadProject(at: dir)
    _ = try #require(runtime.captureFrame())

    let thumb = try #require(runtime.captureNodeOutputs([(node: nodeID, port: "color")], maxDimension: 160)[0])
    #expect(thumb.width == 8 && thumb.height == 8)
    #expect(isNear(try #require(thumb.pixel(x: 4, y: 4)).g, 255))
}

private func isNear(_ value: UInt8, _ target: Int, tolerance: Int = 2) -> Bool {
    abs(Int(value) - target) <= tolerance
}
