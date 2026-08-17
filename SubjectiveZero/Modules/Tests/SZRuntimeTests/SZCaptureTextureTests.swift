// SPDX-License-Identifier: AGPL-3.0-only
// `captureTexture(node:port:)` — the per-node readback behind `agent_view_frame {node}`: a look at any
// rendered port off the asset pool that leaves the render endpoint where it is.
import Testing
import Foundation
import Metal
@testable import SZRuntime
@testable import SZCore

/// A node source that clears its "output" texture to a solid color.
private func solidSource(r: Double, g: Double, b: Double) -> String {
    """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            guard let out = ctx.outputTexture("output") else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = out
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: \(r), green: \(g), blue: \(b), alpha: 1.0)
            pass.colorAttachments[0].storeAction = .store
            ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """
}

private func contract(_ title: String, inputs: [SZPort] = []) -> SZNodeContract {
    SZNodeContract(title: title, sfSymbol: "", summary: "", inputs: inputs,
                   outputs: [SZPort(name: "output", type: .texture)])
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func capturesAnyRenderedNodeWithoutMovingTheEndpoint() throws {
    let runtime = try requireRuntime(renderSize: (width: 24, height: 24))

    // B (blue) feeds A (red, displayed). C is a prompt node: unwired, unimplemented, never rendered.
    let aID = SZNodeID(), bID = SZNodeID(), cID = SZNodeID()
    let project = SZProject(
        name: "capture-texture",
        graph: SZGraph(
            nodes: [
                SZNode(id: bID, kind: .generated, title: "B", contract: contract("B"), position: SZPoint(x: 0, y: 0)),
                SZNode(id: aID, kind: .generated, title: "A",
                       contract: contract("A", inputs: [SZPort(name: "input", type: .texture)]),
                       position: SZPoint(x: 1, y: 0)),
                SZNode(id: cID, kind: .prompt, title: "C", contract: contract("C"), position: SZPoint(x: 2, y: 0)),
            ],
            connections: [SZConnection(from: SZPortRef(node: bID, port: "output"),
                                       to: SZPortRef(node: aID, port: "input"), kind: .data)],
            renderEndpoint: SZPortRef(node: aID, port: "output")))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "SZCaptureTexture-\(UUID().uuidString)").appending(path: "c.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)
    try solidSource(r: 1, g: 0, b: 0).write(
        to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: aID), atomically: true, encoding: .utf8)
    try solidSource(r: 0, g: 0, b: 1).write(
        to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: bID), atomically: true, encoding: .utf8)
    try runtime.loadProject(at: dir)

    // Nothing has rendered yet: no fabricated blank.
    #expect(runtime.captureTexture(node: bID, port: "output") == nil)

    // One frame through the schedule; the endpoint (A) is red.
    let endpoint = try #require(runtime.captureFrame())
    let red = try #require(endpoint.pixel(x: 12, y: 12))
    #expect(red.r == 255 && red.g == 0 && red.b == 0)

    // B's texture off the pool: blue, and a different image than the endpoint's.
    let b = try #require(runtime.captureTexture(node: bID, port: "output"))
    #expect(b.width == 24 && b.height == 24)
    let blue = try #require(b.pixel(x: 12, y: 12))
    #expect(blue.r == 0 && blue.g == 0 && blue.b == 255 && blue.a == 255)
    #expect(b != endpoint)

    // A's own port reads the same as the endpoint capture.
    #expect(runtime.captureTexture(node: aID, port: "output") == endpoint)

    // Never rendered (unimplemented) or an unknown port → nil.
    #expect(runtime.captureTexture(node: cID, port: "output") == nil)
    #expect(runtime.captureTexture(node: bID, port: "nope") == nil)

    // The endpoint is untouched by the per-node looks: still A, still red.
    let again = try #require(runtime.captureFrame()?.pixel(x: 4, y: 4))
    #expect(again.r == 255 && again.g == 0 && again.b == 0)
}
