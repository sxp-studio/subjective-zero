// SPDX-License-Identifier: AGPL-3.0-only
// The mirror present path (`presentCurrentFrame`) THROUGH the real engine: mirrors re-present the
// current endpoint without advancing the timeline, without writing renderSize, and without touching
// the texture pool — plus the paused-resize fix that rides the same non-allocating lookup (a resize
// while paused must letterbox the held frame, not reallocate-and-destroy it). Uses the frameIndex
// ramp node (red = frameIndex%5 / 4) so every assertion is a known literal, not an inequality.
import Testing
import Foundation
import Metal
import QuartzCore
@testable import SZRuntime
@testable import SZCore

/// A loaded 1-node ramp project (red = (frameIndex % 5) / 4). Caller owns the returned directory.
@MainActor
private func loadRampProject(into runtime: SZRuntime) throws -> URL {
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
        .appending(path: "szruntime-mirror-\(UUID().uuidString)").appending(path: "ramp.subz")
    try SZProjectIO.save(project, to: dir)
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
    return dir
}

/// A headless mirror layer, the shape SZViewportView gives the runtime (framebufferOnly false so
/// the blit/MPS present can write the drawable).
@MainActor
private func makeMirrorLayer(device: any MTLDevice, width: Int, height: Int) -> CAMetalLayer {
    let layer = CAMetalLayer()
    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false
    layer.drawableSize = CGSize(width: width, height: height)
    return layer
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func mirrorPresentsAdvanceNothingAndLeaveRenderSizeAlone() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let dir = try loadRampProject(into: runtime)
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    // Drive one frame (frameIndex 0 → red 0), then hammer the mirror path at a DIFFERENT size.
    let first = try #require(runtime.captureFrame())
    #expect(try #require(first.pixel(x: 8, y: 8)).r == 0)

    let mirror = makeMirrorLayer(device: runtime.device, width: 64, height: 64)
    for _ in 0..<3 { runtime.presentCurrentFrame(into: mirror) }

    // One assertion proves both claims: the next driven frame is EXACTLY frameIndex 1 (red ~64 —
    // three advancing mirrors would have landed on frame 4, red 255), and it still renders at
    // 16×16 (a renderSize write from the 64×64 mirror would show up right here).
    let second = try #require(runtime.captureFrame())
    #expect(abs(Int(try #require(second.pixel(x: 8, y: 8)).r) - 64) <= 2)
    #expect(second.width == 16 && second.height == 16)
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func mirrorPresentsPreserveTheHeldFrameWhilePaused() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let dir = try loadRampProject(into: runtime)
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    runtime.renderFrame()   // frame 0
    runtime.renderFrame()   // frame 1 → red ~64
    runtime.setPaused(true)
    let held = try #require(runtime.captureFrame())
    #expect(abs(Int(try #require(held.pixel(x: 8, y: 8)).r) - 64) <= 2)

    // A mirror at a foreign size while paused: an allocating read would reallocate the pool
    // texture (uninitialized garbage); the held frame must come through byte-identical instead.
    let mirror = makeMirrorLayer(device: runtime.device, width: 64, height: 64)
    for _ in 0..<3 { runtime.presentCurrentFrame(into: mirror) }
    let after = try #require(runtime.captureFrame())
    #expect(after == held)
    #expect(after.width == 16 && after.height == 16)
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func pausedResizeKeepsTheHeldFrame() throws {
    // The folded-in fix: pause, then RESIZE the (driving) viewport. The paused branch used to ask
    // the pool at the new size, reallocating — i.e. destroying — the held frame; it now presents
    // the held texture aspect-fitted, and captures report the held texture's own dimensions.
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let dir = try loadRampProject(into: runtime)
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    runtime.renderFrame()   // frame 0
    runtime.renderFrame()   // frame 1 → red ~64
    runtime.setPaused(true)

    let resized = makeMirrorLayer(device: runtime.device, width: 32, height: 32)
    runtime.drawLive(into: resized)   // the driver's layer grew while paused

    let held = try #require(runtime.captureFrame())
    #expect(abs(Int(try #require(held.pixel(x: 8, y: 8)).r) - 64) <= 2)
    #expect(held.width == 16 && held.height == 16)
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func mirrorPresentWithoutAProjectDoesNotCrash() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let mirror = makeMirrorLayer(device: runtime.device, width: 32, height: 32)
    runtime.presentCurrentFrame(into: mirror)   // no scheduler, no endpoint → clear path
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func driverAndMirrorRunConcurrently() throws {
    // Bounded interplay smoke over the engine lock + present scaler mutex: one thread drives the
    // schedule while another mirrors at a foreign size. Pass = no crash, no hang, and the timeline
    // advanced by exactly the driven count.
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let dir = try loadRampProject(into: runtime)
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    let iterations = 200
    let group = DispatchGroup()
    DispatchQueue.global().async(group: group) {
        for _ in 0..<iterations { runtime.renderFrame() }
    }
    DispatchQueue.global().async(group: group) {
        // The mirror thread owns its layer end to end (CAMetalLayer isn't Sendable; created here).
        let mirror = CAMetalLayer()
        mirror.device = runtime.device
        mirror.pixelFormat = .bgra8Unorm
        mirror.framebufferOnly = false
        mirror.drawableSize = CGSize(width: 64, height: 64)
        for _ in 0..<iterations { runtime.presentCurrentFrame(into: mirror) }
    }
    #expect(group.wait(timeout: .now() + 60) == .success)

    // 200 driven frames → frameIndex 200 next; red = (200 % 5)/4 = 0.
    let after = try #require(runtime.captureFrame())
    #expect(try #require(after.pixel(x: 8, y: 8)).r == 0)
}

// MARK: - aspectFit (pure math, no GPU gate)

@Test func aspectFitEqualSizesIsIdentity() {
    let fit = SZRuntime.aspectFit(source: (width: 100, height: 50), dest: (width: 100, height: 50))
    #expect(fit.scale == 1 && fit.translateX == 0 && fit.translateY == 0)
}

@Test func aspectFitWideIntoTallPillarboxesVertically() {
    // 200×100 into 100×100: scale 0.5 → 100×50 centered → bars top/bottom (ty > 0, tx == 0).
    let fit = SZRuntime.aspectFit(source: (width: 200, height: 100), dest: (width: 100, height: 100))
    #expect(fit.scale == 0.5)
    #expect(fit.translateX == 0)
    #expect(fit.translateY == 25)
}

@Test func aspectFitTallIntoWideLetterboxesHorizontally() {
    // 100×200 into 200×200 → scale 1? No: 100×200 into 200×100: scale 0.5 → 50×100 → bars left/right.
    let fit = SZRuntime.aspectFit(source: (width: 100, height: 200), dest: (width: 200, height: 100))
    #expect(fit.scale == 0.5)
    #expect(fit.translateX == 75)
    #expect(fit.translateY == 0)
}

@Test func aspectFitUpscalesSmallSources() {
    // A 16×16 endpoint on a 64×32 mirror: scale 2 (height-bound), centered horizontally.
    let fit = SZRuntime.aspectFit(source: (width: 16, height: 16), dest: (width: 64, height: 32))
    #expect(fit.scale == 2)
    #expect(fit.translateX == 16)
    #expect(fit.translateY == 0)
}
