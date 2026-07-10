// SPDX-License-Identifier: AGPL-3.0-only
// The scheduled 2-node DAG renders end to end. Two complementary checks via the real
// `captureFrame()` readback (behind `agent_view_frame`):
//   - `grayscaleConvertsColorSource` proves the grayscale MATH: a stub source node clears to a known
//     color, the (sample's) grayscale node converts it, and we assert every sampled pixel is R≈G≈B and
//     matches the Rec. 601 luminance of that color. Independent of the camera.
//   - `rendersSampleGrayscaleCameraFromDisk` proves the real on-disk sample (camera → grayscale) loads,
//     compiles, schedules, and renders headless-safe (no camera auth → black, which is trivially R≈G≈B,
//     no crash). The LIVE grayscale-camera assertion runs in the app (SZHost.verifyGrayscale) where a
//     real camera + granted permission exist — a camera can't be a deterministic unit test.
import Testing
import Foundation
import Metal
@testable import SZRuntime
@testable import SZCore

private var sampleURL: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()   // SZRuntimeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // SubjectiveZero (umbrella root)
        .appending(path: "Samples/grayscale-camera.subz")
}

/// A stub source node: clears its output texture to a fixed color (so the grayscale node has a known
/// input). Same shape as the sample's pre-camera stub.
private let stubSourceSource = """
import Metal
final class Node: SZNode {
    func update(_ ctx: SZFrameContext) {
        guard let out = ctx.outputTexture("texture") else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.55, green: 0.40, blue: 0.30, alpha: 1.0)
        pass.colorAttachments[0].storeAction = .store
        ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }
}
enum SZNodeMain { static func make() -> SZNode { Node() } }
"""

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func grayscaleConvertsColorSource() throws {
    let runtime = try requireRuntime(renderSize: (width: 48, height: 48))

    // Reuse the sample's real grayscale node; feed it a stub color source.
    let sample = try SZProjectIO.load(from: sampleURL)
    let grayNode = try #require(sample.graph.nodes.first { $0.title == "Make Grayscale" })
    let grayContract = try #require(grayNode.contract)
    let grayLibrarySource = SZProjectIO.nodeSourceURL(projectURL: sampleURL, nodeID: grayNode.id)

    let sourceID = SZNodeID(), grayID = SZNodeID()
    let project = SZProject(
        name: "grayscale-math",
        graph: SZGraph(
            nodes: [
                SZNode(id: sourceID, kind: .generated, title: "Source",
                       contract: SZNodeContract(title: "Source", sfSymbol: "", summary: "",
                                                outputs: [SZPort(name: "texture", type: .texture)]),
                       position: SZPoint(x: 0, y: 0)),
                SZNode(id: grayID, kind: .generated, title: "Make Grayscale",
                       contract: grayContract, position: SZPoint(x: 1, y: 0)),
            ],
            connections: [SZConnection(from: SZPortRef(node: sourceID, port: "texture"),
                                       to: SZPortRef(node: grayID, port: "input"), kind: .data)],
            renderEndpoint: SZPortRef(node: grayID, port: "output")))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "SZGray-\(UUID().uuidString)").appending(path: "g.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)
    try stubSourceSource.write(
        to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: sourceID), atomically: true, encoding: .utf8)
    try FileManager.default.copyItem(
        at: grayLibrarySource, to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: grayID))

    try runtime.loadProject(at: dir)
    let frame = try #require(runtime.captureFrame())

    // (0.55, 0.40, 0.30) → 0.299·0.55 + 0.587·0.40 + 0.114·0.30 ≈ 0.4335 → ~111/255.
    let expectedByte = Int(((0.299 * 0.55 + 0.587 * 0.40 + 0.114 * 0.30) * 255).rounded())
    for (x, y) in [(4, 4), (24, 24), (43, 43)] {
        let p = try #require(frame.pixel(x: x, y: y))
        #expect(abs(Int(p.r) - Int(p.g)) <= 2, "R≈G at (\(x),\(y)): \(p)")
        #expect(abs(Int(p.g) - Int(p.b)) <= 2, "G≈B at (\(x),\(y)): \(p)")
        #expect(abs(Int(p.r) - expectedByte) <= 3, "luminance at (\(x),\(y)): \(p.r) vs ~\(expectedByte)")
        #expect(p.r < 130, "expected darkened luminance, not source red, at (\(x),\(y)): \(p)")
    }
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func sampleGrayscaleCameraLoadsCompilesAndRendersHeadless() throws {
    let runtime = try requireRuntime(renderSize: (width: 48, height: 48))

    // What this test uniquely proves: the SHIPPED `.subz` still loads, both of its nodes compile against
    // the current ABI, the graph schedules, and a frame comes back at the requested size. The grayscale
    // MATH is proven by grayscaleConvertsColorSource, which feeds the same node a stub color source.
    //
    // It used to assert `R≈G≈B` here. The test process is never camera-authorized, so the camera starts
    // no session and the frame is the specified all-black — and `0≈0≈0` holds for ANY node, grayscale or
    // not. Assert the black itself: it is the camera node's DEFINED headless output (SZCameraNodeTests),
    // so it catches a stale or garbage texture reaching the endpoint, which channel-equality never could.
    try runtime.loadProject(at: sampleURL)
    let frame = try #require(runtime.captureFrame())
    #expect(frame.width == 48 && frame.height == 48)
    for (x, y) in [(4, 4), (24, 24), (43, 43)] {
        let p = try #require(frame.pixel(x: x, y: y))
        #expect(p.r == 0 && p.g == 0 && p.b == 0, "expected the defined headless black at (\(x),\(y)): \(p)")
        #expect(p.a == 255, "opaque at (\(x),\(y)): \(p)")
    }
}
