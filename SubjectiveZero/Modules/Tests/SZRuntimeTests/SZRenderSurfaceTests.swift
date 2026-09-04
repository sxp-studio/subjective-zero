// SPDX-License-Identifier: AGPL-3.0-only
// The render loop's fan-out THROUGH the real engine, one `tick()` at a time (no display link):
// the DRIVER surface defines renderSize, mirrors present at their own size without touching it or
// the timeline, paused ticks hold the frame byte-identical (a paused driver resize letterboxes the
// held frame instead of reallocating-and-destroying it), detach stops presents, and the loop
// interleaves safely with off-loop encodes (`renderFrame`). Uses the frameIndex ramp node
// (red = frameIndex%5 / 4) so every assertion is a known literal, not an inequality.
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
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: nodeID, target: .native), atomically: true, encoding: .utf8)
    try runtime.loadProject(at: dir)
    return dir
}

/// A headless surface layer, the shape SZViewportView gives the runtime (framebufferOnly false so
/// the blit/MPS present can write the drawable). Windowless layers still vend drawables.
@MainActor
private func makeSurfaceLayer(device: any MTLDevice, width: Int, height: Int) -> CAMetalLayer {
    let layer = CAMetalLayer()
    layer.device = device
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false
    layer.drawableSize = CGSize(width: width, height: height)
    return layer
}

/// The surface object the runtime holds for `layer` (nil once detached).
private func surface(of runtime: SZRuntime, _ layer: CAMetalLayer) -> SZRenderSurface? {
    runtime.attachedSurfaceForTests(layer)
}

/// Poll a surface's completed-present count (mirror presents complete asynchronously).
private func waitForPresents(_ surface: SZRenderSurface, atLeast n: Int, timeout: TimeInterval = 8) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if surface.presentCount.load(ordering: .relaxed) >= n { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return surface.presentCount.load(ordering: .relaxed) >= n
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func mirrorsFollowTheDriverAndLeaveRenderSizeAlone() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let dir = try loadRampProject(into: runtime)
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    // A 16×16 driver and a 64×64 mirror: three ticks advance the timeline by exactly three, the
    // capture that follows is frame 3 (red ~191) at the DRIVER's 16×16 — a renderSize write from
    // the 64×64 mirror would show up right here — and both surfaces got their presents.
    let driver = makeSurfaceLayer(device: runtime.device, width: 16, height: 16)
    let mirror = makeSurfaceLayer(device: runtime.device, width: 64, height: 64)
    runtime.attach(driver)
    runtime.attach(mirror)
    runtime.setDriver(driver)
    for _ in 0..<3 { runtime.tick() }

    let after = try #require(runtime.captureFrame())
    #expect(abs(Int(try #require(after.pixel(x: 8, y: 8)).r) - 191) <= 2)
    #expect(after.width == 16 && after.height == 16)
    #expect(try #require(surface(of: runtime, driver)).presentCount.load(ordering: .relaxed) == 3)   // synchronous
    #expect(waitForPresents(try #require(surface(of: runtime, mirror)), atLeast: 1))               // queued, drop-if-busy
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func detachStopsPresentsAndDropsTheSurface() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let dir = try loadRampProject(into: runtime)
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    let layer = makeSurfaceLayer(device: runtime.device, width: 16, height: 16)
    runtime.attach(layer)
    runtime.setDriver(layer)
    runtime.tick()
    let held = try #require(surface(of: runtime, layer))
    #expect(held.presentCount.load(ordering: .relaxed) == 1)

    runtime.detach(layer)
    #expect(surface(of: runtime, layer) == nil)
    runtime.tick()   // still advances the schedule (paced), presents to nobody
    #expect(held.presentCount.load(ordering: .relaxed) == 1)
    #expect(runtime.renderSize.width == 16)   // the stale driver key just keeps the last size
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
    // texture (uninitialized garbage); the held frame must come through byte-identical instead —
    // and the paused ticks still re-present it (the freeze survives occlusion/resize).
    let mirror = makeSurfaceLayer(device: runtime.device, width: 64, height: 64)
    runtime.attach(mirror)
    for _ in 0..<3 { runtime.tick() }
    let after = try #require(runtime.captureFrame())
    #expect(after == held)
    #expect(after.width == 16 && after.height == 16)
    #expect(waitForPresents(try #require(surface(of: runtime, mirror)), atLeast: 1))
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

    let driver = makeSurfaceLayer(device: runtime.device, width: 16, height: 16)
    runtime.attach(driver)
    runtime.setDriver(driver)
    driver.drawableSize = CGSize(width: 32, height: 32)   // the driver's layer grew while paused
    runtime.tick()
    #expect(runtime.renderSize.width == 32 && runtime.renderSize.height == 32)   // size followed…

    let held = try #require(runtime.captureFrame())
    #expect(abs(Int(try #require(held.pixel(x: 8, y: 8)).r) - 64) <= 2)
    #expect(held.width == 16 && held.height == 16)
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func tickWithoutAProjectDoesNotCrash() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let layer = makeSurfaceLayer(device: runtime.device, width: 32, height: 32)
    runtime.attach(layer)
    runtime.setDriver(layer)
    runtime.tick()   // no scheduler, no endpoint → clear path, and the in-flight slot is given back
    runtime.tick()
    runtime.tick()   // a third tick would hang if the semaphore leaked on the no-encode path
    #expect(try #require(surface(of: runtime, layer)).presentCount.load(ordering: .relaxed) == 3)
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func loopTicksInterleaveWithOffLoopEncodes() throws {
    // Bounded interplay smoke over the engine lock + present scaler mutex + frames-in-flight bound:
    // one thread ticks the loop (driver + a foreign-size mirror attached) while another encodes
    // off-loop frames (`renderFrame`, the capture/reset path). Pass = no crash, no hang, and the
    // timeline advanced by exactly the sum.
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let dir = try loadRampProject(into: runtime)
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    let driver = makeSurfaceLayer(device: runtime.device, width: 16, height: 16)
    let mirror = makeSurfaceLayer(device: runtime.device, width: 64, height: 64)
    runtime.attach(driver)
    runtime.attach(mirror)
    runtime.setDriver(driver)

    let iterations = 200
    let group = DispatchGroup()
    DispatchQueue.global().async(group: group) {
        for _ in 0..<iterations { runtime.renderFrame() }
    }
    DispatchQueue.global().async(group: group) {
        for _ in 0..<iterations { runtime.tick() }
    }
    #expect(group.wait(timeout: .now() + 60) == .success)

    // 400 frames → frameIndex 400 next; red = (400 % 5)/4 = 0.
    let after = try #require(runtime.captureFrame())
    #expect(try #require(after.pixel(x: 8, y: 8)).r == 0)
    #expect(try #require(surface(of: runtime, driver)).presentCount.load(ordering: .relaxed) == iterations)
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
