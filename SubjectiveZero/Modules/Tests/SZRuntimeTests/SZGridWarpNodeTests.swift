// SPDX-License-Identifier: AGPL-3.0-only
// The hand-authored `grid-warp` node — corner-pin's sibling: a 4×4 mesh of control points instead of
// four corners, for a surface that is not flat. Its contract decodes (sixteen float2 points, a texture
// in/out and the `card` mount hints), contract and source agree on ports, and on a GPU it does what
// it says: the flat mesh passes the source through, and moving only the interior points bends the
// image while the four corners stay put — the thing corner-pin cannot do.
import Testing
import Foundation
import Metal
@testable import SZRuntime
@testable import SZCore

private var gridWarpDir: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()   // SZRuntimeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // SubjectiveZero (umbrella root)
        .appending(path: "NodeLibrary/grid-warp")
}

private func gridWarpContract() throws -> SZNodeContract {
    try JSONDecoder().decode(
        SZNodeContract.self, from: Data(contentsOf: gridWarpDir.appending(path: "node-contract.json")))
}

/// Row-major `p00`…`p33`, the order the node reads them in.
private let meshPorts = (0..<4).flatMap { r in (0..<4).map { c in "p\(r)\(c)" } }

@Test func gridWarpContractDecodesWithCardHints() throws {
    let contract = try gridWarpContract()
    #expect(contract.title == "Grid Warp")
    #expect(contract.inputs.map(\.name) == ["input"] + meshPorts)
    for point in contract.inputs.dropFirst() {
        #expect(point.type == .float2)
        #expect(point.def != nil, "\(point.name) needs a by-value default — the card and the mesh both read it")
    }
    // The flat mesh is the identity map, so an untouched node is a passthrough.
    for (index, point) in contract.inputs.dropFirst().enumerated() {
        guard case .float2(let v)? = point.def else { Issue.record("\(point.name) is not a float2"); continue }
        #expect(abs(v[0] - Double(index % 4) / 3) < 1e-9, "\(point.name) x is off the flat grid")
        #expect(abs(v[1] - Double(index / 4) / 3) < 1e-9, "\(point.name) y is off the flat grid")
    }
    #expect(contract.outputs.first?.type == .texture)
    #expect(contract.outputs.first?.display == true)
    // The card mount hints: footprint + the output drawn under the points, which the card owns.
    #expect(contract.card == SZCardHints(cols: 10, rows: 8, backdrop: "output", plumbing: meshPorts))
    #expect(FileManager.default.fileExists(atPath: gridWarpDir.appending(path: "Card.swift").path))
}

@Test func gridWarpContractAndSourceDeclareTheSamePorts() throws {
    let source = try String(contentsOf: gridWarpDir.appending(path: "Node.swift"), encoding: .utf8)
    let audit = SZPortBindingAudit.audit(contract: try gridWarpContract(), source: source)
    #expect(audit.errors.isEmpty, "\(audit.errors)")
    #expect(audit.warnings.isEmpty, "\(audit.warnings)")
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func gridWarpBendsTheInteriorWithoutMovingTheCorners() throws {
    let runtime = try requireRuntime(renderSize: (width: 64, height: 64))

    let sourceID = SZNodeID(), warpID = SZNodeID()
    let project = SZProject(
        name: "grid-warp",
        graph: SZGraph(
            nodes: [
                SZNode(id: sourceID, kind: .generated, title: "split",
                       contract: SZNodeContract(title: "split", sfSymbol: "", summary: "",
                                                outputs: [SZPort(name: "output", type: .texture, display: true)]),
                       position: SZPoint(x: 0, y: 0)),
                SZNode(id: warpID, kind: .generated, title: "Grid Warp", contract: try gridWarpContract(),
                       position: SZPoint(x: 1, y: 0)),
            ],
            connections: [
                SZConnection(from: SZPortRef(node: sourceID, port: "output"),
                             to: SZPortRef(node: warpID, port: "input"), kind: .data),
            ],
            renderEndpoint: SZPortRef(node: warpID, port: "output")))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "SZGridWarp-\(UUID().uuidString)").appending(path: "warp.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)
    // A source split red | green down the middle, so where the seam lands says which part of the
    // source a pixel came from. Written from the CPU: the mesh is what is under test, not a shader.
    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            guard let out = ctx.outputTexture("output") else { return }
            let w = out.width, h = out.height
            var bgra = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    bgra[i] = 0
                    bgra[i + 1] = x < w / 2 ? 0 : 255
                    bgra[i + 2] = x < w / 2 ? 255 : 0
                }
            }
            out.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bgra, bytesPerRow: w * 4)
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: sourceID, target: .native), atomically: true, encoding: .utf8)
    try FileManager.default.copyItem(
        at: gridWarpDir.appending(path: "Node.swift"),
        to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: warpID, target: .native))
    try runtime.loadProject(at: dir)

    // The flat mesh is the identity map: the source arrives unmoved, seam still down the middle.
    let flat = try #require(runtime.captureFrame())
    let left = try #require(flat.pixel(x: 16, y: 32))
    let right = try #require(flat.pixel(x: 48, y: 32))
    let inner = try #require(flat.pixel(x: 40, y: 32))
    #expect(left.r > 200 && left.g < 30, "the flat mesh should pass the red half through: \(left)")
    #expect(right.g > 200 && right.r < 30, "the flat mesh should pass the green half through: \(right)")
    #expect(inner.g > 200 && inner.r < 30, "x=40 is in the source's green half: \(inner)")
    // Corners too: nothing is cropped when the mesh is flat.
    let topLeft = try #require(flat.pixel(x: 2, y: 2))
    #expect(topLeft.r > 200 && topLeft.g < 30, "the flat mesh should not crop a frame corner: \(topLeft)")

    // Push the two interior COLUMNS right, leaving all four corners exactly where they were. The
    // source's left third now covers most of the frame, so the seam slides from x=32 to about x=46.
    for row in 0..<4 {
        runtime.setInputValue(node: warpID, port: "p\(row)1", floats: [0.6, Float(row) / 3])
        runtime.setInputValue(node: warpID, port: "p\(row)2", floats: [0.8, Float(row) / 3])
    }
    let bent = try #require(runtime.captureFrame())
    let moved = try #require(bent.pixel(x: 40, y: 32))
    let beyond = try #require(bent.pixel(x: 52, y: 32))
    let stillLeft = try #require(bent.pixel(x: 16, y: 32))
    #expect(moved.r > 200 && moved.g < 30,
            "x=40 was green and must now be red — the interior moved: \(moved)")
    #expect(beyond.g > 200 && beyond.r < 30, "x=52 is still past the seam: \(beyond)")
    #expect(stillLeft.r > 200 && stillLeft.g < 30, "the stretched left half is still red: \(stillLeft)")
    // The corners never moved, so the frame is still filled corner to corner.
    let bentCorner = try #require(bent.pixel(x: 61, y: 61))
    #expect(bentCorner.g > 200 && bentCorner.r < 30,
            "the bottom-right corner point never moved, so the frame stays filled: \(bentCorner)")
}
