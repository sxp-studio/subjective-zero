// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import Metal
@testable import SZRuntime
@testable import SZCore

/// The end-to-end verify hook, through the graph engine: a trivial 1-node project clears its output to
/// a known solid color, `captureFrame()` does a REAL framebuffer readback, and we assert the pixels.
/// This is the actual readback behind `agent_view_frame` — the whole app is verified through it.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func capturesSolidColorFrame() throws {
    let runtime = try requireRuntime(renderSize: (width: 32, height: 32))

    // A 1-node project whose only output "color" is the render endpoint.
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
        .appending(path: "szruntime-solid-\(UUID().uuidString)").appending(path: "solid.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)

    // Clears the output to (r:1.0, g:0.5, b:0.25) via a render-pass load action — no pipeline needed.
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

    let frame = try #require(runtime.captureFrame())
    #expect(frame.width == 32 && frame.height == 32)

    let center = try #require(frame.pixel(x: 16, y: 16))
    // .bgra8Unorm linear unorm: float * 255, ±2 tolerance for rounding.
    #expect(isNear(center.r, 255)) // 1.0
    #expect(isNear(center.g, 128)) // 0.5
    #expect(isNear(center.b, 64))  // 0.25
    #expect(center.a == 255)
}

private func isNear(_ value: UInt8, _ target: Int, tolerance: Int = 2) -> Bool {
    abs(Int(value) - target) <= tolerance
}
