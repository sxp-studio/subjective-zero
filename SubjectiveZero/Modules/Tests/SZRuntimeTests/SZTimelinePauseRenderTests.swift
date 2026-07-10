// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import Metal
@testable import SZRuntime
@testable import SZCore

/// End-to-end coverage of the HUD pause/reset controls THROUGH the real render engine: a 1-node graph
/// whose output color is a pure function of `ctx.frameIndex`, so each rendered frame is distinct. We then
/// drive `setPaused`/`resetTimeline` and read back real pixels to prove the runtime freezes and rewinds.
/// (Uses `frameIndex`, not wall-time, so the assertions are deterministic — captures happen microseconds
/// apart, which wouldn't move a seconds clock.)
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func pauseFreezesAndResetRewindsThroughTheEngine() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))

    let nodeID = SZNodeID()
    let project = SZProject(
        name: "ramp",
        graph: SZGraph(
            nodes: [SZNode(id: nodeID, kind: .generated, title: "ramp",
                           contract: SZNodeContract(title: "ramp", sfSymbol: "", summary: "",
                                                    outputs: [SZPort(name: "color", type: .texture, display: true)]),
                           position: SZPoint(x: 0, y: 0))],
            connections: [],
            renderEndpoint: SZPortRef(node: nodeID, port: "color")))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-ramp-\(UUID().uuidString)").appending(path: "ramp.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)

    // red = (frameIndex % 5) / 4 → a distinct value each frame while running, frozen while paused, and
    // back to the frame-0 value after a reset.
    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            guard let out = ctx.outputTexture("color") else { return }
            let v = Double(ctx.frameIndex % 5) / 4.0
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = out
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: v, green: 0, blue: 0, alpha: 1.0)
            pass.colorAttachments[0].storeAction = .store
            ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: nodeID), atomically: true, encoding: .utf8)

    try runtime.loadProject(at: dir)

    func redAtCenter() throws -> UInt8 {
        let frame = try #require(runtime.captureFrame())
        return try #require(frame.pixel(x: 8, y: 8)).r
    }

    // Running: the frame index advances, and the ramp maps it to a KNOWN red. Assert the exact values,
    // not merely `a != b` — an inequality is also satisfied by an engine that skipped to frame 3, or ran
    // the ramp backwards. Only the literals pin the direction and the rate of the advance.
    let a = try redAtCenter()   // frameIndex 0 → 0/4 → red 0
    let b = try redAtCenter()   // frameIndex 1 → 1/4 → red ~64
    #expect(a == 0)
    #expect(abs(Int(b) - 64) <= 2)

    // Paused: the frame freezes — repeated captures are byte-identical AND hold the last running value
    // (frameIndex stays at 1). `p1 == p2` alone would also hold for a pause that rewound to 0 or jumped
    // ahead, so long as it then stopped; `p1 == b` is what says it froze *where it was*.
    runtime.setPaused(true)
    let p1 = try redAtCenter()
    let p2 = try redAtCenter()
    #expect(p1 == p2)
    #expect(p1 == b)

    // Reset while playing rewinds to the start: the frame-0 value returns.
    runtime.setPaused(false)
    runtime.resetTimeline()
    let r = try redAtCenter()   // frameIndex 0 again → red 0
    #expect(r == a)
    #expect(r == 0)
}
