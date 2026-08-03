// SPDX-License-Identifier: AGPL-3.0-only
// ABI v7 — the runtime tells a node when it pauses / resumes (`setPaused`), the one transport event
// `update()` can't carry: pause means no more frames. Driven through a REAL compiled node, because the
// callback is declared in `SZRuntimeSupport.source` — the ABI injected into every node build, which no
// host-side unit test compiles.
//
// The node under test owns an `AVPlayer` (no item needed — `rate` is the observable, and it's exactly what
// video-file owns) and reports its own state back through the output color, the same trick
// SZScalarInputTests uses, since the host holds no registry to inspect:
//   red   = setPaused call count / 10    → 2 calls ⇒ ~51
//   green = 1 when the last call said "not paused"
//   blue  = the player's live rate        → 0.5 ⇒ ~128
import Testing
import Foundation
import AVFoundation
import Metal
@testable import SZRuntime
@testable import SZCore

private let clockNodeSource = """
import Metal
import AVFoundation

final class Node: SZNode {
    private var player: AVPlayer?
    private var calls = 0
    private var lastRunning = false

    func setup(_ ctx: SZSetupContext) {
        let created = AVPlayer()
        created.rate = 0.5          // a NON-default rate: resuming at a blanket 1.0 would show up as blue=255
        player = created
    }

    func setPaused(_ paused: Bool) {
        calls += 1
        lastRunning = !paused
        if paused { player?.pause() } else { player?.rate = 0.5 }
    }

    func update(_ ctx: SZFrameContext) {
        guard let out = ctx.outputTexture("color") else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(calls) / 10.0,
            green: lastRunning ? 1.0 : 0.0,
            blue: Double(player?.rate ?? -1),
            alpha: 1.0)
        pass.colorAttachments[0].storeAction = .store
        ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }
}
enum SZNodeMain { static func make() -> SZNode { Node() } }
"""

@MainActor
private func clockRuntime() throws -> (SZRuntime, URL) {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let nodeID = SZNodeID()
    let project = SZProject(
        name: "clock",
        graph: SZGraph(
            nodes: [SZNode(id: nodeID, kind: .generated, title: "clock",
                           contract: SZNodeContract(title: "clock", sfSymbol: "", summary: "",
                                                    inputs: [],
                                                    outputs: [SZPort(name: "color", type: .texture, display: true)]),
                           position: SZPoint(x: 0, y: 0))],
            connections: [],
            renderEndpoint: SZPortRef(node: nodeID, port: "color")))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-clock-\(UUID().uuidString)").appending(path: "clock.subz")
    try SZProjectIO.save(project, to: dir)
    try clockNodeSource.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: nodeID),
                              atomically: true, encoding: .utf8)
    return (runtime, dir)
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func pauseStopsThePlayerAndPlayRestoresItsRate() throws {
    let (runtime, dir) = try clockRuntime()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try runtime.loadProject(at: dir)

    // Loaded while running: nothing called yet, and the player is at the rate setup gave it.
    let initial = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(initial.r == 0, "the callback should not fire on a normal load")
    #expect(abs(Int(initial.b) - 128) <= 2)

    // Pause: the node must hear about it even though no frame will encode again...
    runtime.setPaused(true)
    runtime.setPaused(false)
    // ...and resume must put the player back at ITS rate, not a blanket 1.0.
    let resumed = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(abs(Int(resumed.r) - 51) <= 2, "expected exactly 2 calls (paused, resumed), got r=\(resumed.r)")
    #expect(resumed.g == 255, "the last call must have said 'not paused'")
    #expect(abs(Int(resumed.b) - 128) <= 2, "resume must restore rate 0.5, got b=\(resumed.b)")
}

/// A node set up while the runtime is already paused must not come up running — the drop-a-clip-onto-a-
/// paused-graph case. The runtime asserts it right after `activate()`, so no node has to remember it.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func aNodeSetUpWhilePausedIsStoppedImmediately() throws {
    let (runtime, dir) = try clockRuntime()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    runtime.setPaused(true)
    try runtime.loadProject(at: dir)      // setup() runs while paused
    runtime.setPaused(false)

    // 2 calls = the pause asserted at activate + this resume. Only 1 would mean the load-while-paused
    // assertion never happened and the clip would have been audible from the moment it appeared.
    let frame = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(abs(Int(frame.r) - 51) <= 2, "expected a pause at activate plus this resume, got r=\(frame.r)")
    #expect(frame.g == 255)
    #expect(abs(Int(frame.b) - 128) <= 2)
}
