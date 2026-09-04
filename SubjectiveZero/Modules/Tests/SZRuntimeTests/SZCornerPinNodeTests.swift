// SPDX-License-Identifier: AGPL-3.0-only
// The hand-authored `corner-pin` library node — the projection-mapping reference and the first
// built-in node that ships a custom card. Its contract decodes (four float2 corners, a texture
// in/out, and the `card` mount hints), contract and source agree on ports, and on a GPU the warp
// does what it says: identity corners pass the source through; a shrunk quad leaves the frame's
// corners black while the middle still shows the source.
import Testing
import Foundation
import Metal
@testable import SZRuntime
@testable import SZCore

private var libraryCornerPinDir: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()   // SZRuntimeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // SubjectiveZero (umbrella root)
        .appending(path: "NodeLibrary/corner-pin")
}

private func libraryCornerPinContract() throws -> SZNodeContract {
    try JSONDecoder().decode(
        SZNodeContract.self, from: Data(contentsOf: libraryCornerPinDir.appending(path: "node-contract.json")))
}

@Test func cornerPinContractDecodesWithCardHints() throws {
    let contract = try libraryCornerPinContract()
    #expect(contract.title == "Corner Pin")
    #expect(contract.inputs.map(\.name) == ["input", "tl", "tr", "br", "bl"])
    for corner in contract.inputs.dropFirst() {
        #expect(corner.type == .float2)
        #expect(corner.def != nil, "\(corner.name) needs a by-value default — the card and the warp both read it")
    }
    #expect(contract.outputs.first?.type == .texture)
    #expect(contract.outputs.first?.display == true)
    // The card mount hints: footprint + the output drawn under the handles.
    #expect(contract.card == SZCardHints(cols: 10, rows: 8, backdrop: "output", plumbing: ["tl", "tr", "br", "bl"]))
    // The card ships beside the node.
    #expect(FileManager.default.fileExists(atPath: libraryCornerPinDir.appending(path: "Card.swift").path))
}

@Test func cornerPinContractAndSourceDeclareTheSamePorts() throws {
    let source = try String(contentsOf: libraryCornerPinDir.appending(path: "Node.swift"), encoding: .utf8)
    let audit = SZPortBindingAudit.audit(contract: try libraryCornerPinContract(), source: source)
    #expect(audit.errors.isEmpty, "\(audit.errors)")
    #expect(audit.warnings.isEmpty, "\(audit.warnings)")
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func cornerPinWarpsTheSourceOntoTheQuad() throws {
    let runtime = try requireRuntime(renderSize: (width: 64, height: 64))

    let sourceID = SZNodeID(), pinID = SZNodeID()
    let project = SZProject(
        name: "corner-pin",
        graph: SZGraph(
            nodes: [
                SZNode(id: sourceID, kind: .generated, title: "red",
                       contract: SZNodeContract(title: "red", sfSymbol: "", summary: "",
                                                outputs: [SZPort(name: "output", type: .texture, display: true)]),
                       position: SZPoint(x: 0, y: 0)),
                SZNode(id: pinID, kind: .generated, title: "Corner Pin", contract: try libraryCornerPinContract(),
                       position: SZPoint(x: 1, y: 0)),
            ],
            connections: [
                SZConnection(from: SZPortRef(node: sourceID, port: "output"),
                             to: SZPortRef(node: pinID, port: "input"), kind: .data),
            ],
            renderEndpoint: SZPortRef(node: pinID, port: "output")))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "SZCornerPin-\(UUID().uuidString)").appending(path: "pin.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)
    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            guard let out = ctx.outputTexture("output") else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = out
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: sourceID, target: .native), atomically: true, encoding: .utf8)
    try FileManager.default.copyItem(
        at: libraryCornerPinDir.appending(path: "Node.swift"),
        to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: pinID, target: .native))
    try runtime.loadProject(at: dir)

    // Identity corners: the source passes through — red at the center AND at a frame corner.
    let identity = try #require(runtime.captureFrame())
    let center = try #require(identity.pixel(x: 32, y: 32))
    let corner = try #require(identity.pixel(x: 2, y: 2))
    #expect(center.r > 200 && center.g < 30, "identity center should be the red source: \(center)")
    #expect(corner.r > 200 && corner.g < 30, "identity corner should be the red source: \(corner)")

    // Shrink the quad to the middle half: the frame corners fall outside (black), the center stays red.
    runtime.setInputValue(node: pinID, port: "tl", floats: [0.25, 0.25])
    runtime.setInputValue(node: pinID, port: "tr", floats: [0.75, 0.25])
    runtime.setInputValue(node: pinID, port: "br", floats: [0.75, 0.75])
    runtime.setInputValue(node: pinID, port: "bl", floats: [0.25, 0.75])
    let shrunk = try #require(runtime.captureFrame())
    let center2 = try #require(shrunk.pixel(x: 32, y: 32))
    let corner2 = try #require(shrunk.pixel(x: 2, y: 2))
    #expect(center2.r > 200 && center2.g < 30, "shrunk quad center should still be red: \(center2)")
    #expect(corner2.r < 30 && corner2.g < 30 && corner2.b < 30, "outside the quad must be black: \(corner2)")
    #expect(corner2.a == 255)
}
