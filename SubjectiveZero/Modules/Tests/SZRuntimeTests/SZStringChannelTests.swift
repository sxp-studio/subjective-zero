// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import Metal
@testable import SZRuntime
@testable import SZCore

/// ABI v8: a node's `string`/`enum` OUTPUT flows across a `.data` edge into a downstream node's string
/// input, and is host-readable (`readOutputString`). Same shape as the v5 float-channel test: the
/// upstream emits with `ctx.setOutputString`, the downstream reads `ctx.inputString` and renders it.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable), arguments: [SZPortType.string, .enumeration])
func outputStringFlowsAcrossDataEdgeToDownstreamInput(portType: SZPortType) throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))

    let source = SZNodeID()
    let sink = SZNodeID()
    let sinkDefault: SZPortValue = portType == .string ? .string("cold") : .enumeration("cold")
    let project = SZProject(
        name: "string-channel",
        graph: SZGraph(
            nodes: [
                SZNode(id: source, kind: .generated, title: "source",
                       contract: SZNodeContract(title: "source", sfSymbol: "", summary: "",
                                                inputs: [],
                                                outputs: [SZPort(name: "mode", type: portType)]),
                       position: SZPoint(x: 0, y: 0)),
                // Downstream: reads `mode` (fed from upstream) and clears to red only when it says "warm".
                SZNode(id: sink, kind: .generated, title: "sink",
                       contract: SZNodeContract(title: "sink", sfSymbol: "", summary: "",
                                                inputs: [SZPort(name: "mode", type: portType, def: sinkDefault)],
                                                outputs: [SZPort(name: "color", type: .texture, display: true)]),
                       position: SZPoint(x: 1, y: 0)),
            ],
            connections: [
                SZConnection(from: SZPortRef(node: source, port: "mode"),
                             to: SZPortRef(node: sink, port: "mode"), kind: .data),
            ],
            renderEndpoint: SZPortRef(node: sink, port: "color")))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-string-\(UUID().uuidString)").appending(path: "string.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)

    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            ctx.setOutputString("mode", "warm")
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: source, target: .native), atomically: true, encoding: .utf8)

    // Red iff the string crossed the edge (its own default is "cold" → black).
    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            guard let out = ctx.outputTexture("color") else { return }
            let warm = ctx.inputString("mode") == "warm"
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = out
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: warm ? 1 : 0, green: 0, blue: 0, alpha: 1.0)
            pass.colorAttachments[0].storeAction = .store
            ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: sink, target: .native), atomically: true, encoding: .utf8)

    try runtime.loadProject(at: dir)
    #expect(runtime.readOutputString(node: source, port: "mode") == nil)   // nothing encoded yet

    let pixel = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(pixel.r >= 250 && pixel.g <= 2)

    // Host-side read of the same channel; float reads of a string port and unknown ports stay nil.
    #expect(runtime.readOutputString(node: source, port: "mode") == "warm")
    #expect(runtime.readOutputFloats(node: source, port: "mode") == nil)
    #expect(runtime.readOutputString(node: source, port: "missing") == nil)
}
