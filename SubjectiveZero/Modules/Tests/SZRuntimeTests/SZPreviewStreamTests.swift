// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import IOSurface
import Synchronization
@testable import SZRuntime
@testable import SZCore

/// The zero-copy preview stream: watching a port makes each encoded frame publish a fitted,
/// double-buffered IOSurface (real pixels, alternating identity); the throttle coalesces frames;
/// unwatching stops publishes; a paused timeline publishes nothing except the one-shot fill a
/// watch change performs from the held pool.

/// Collects publishes from the completion-thread callback; tests poll with a deadline (completion
/// handlers aren't ordered against `waitUntilCompleted`, so batches may land a beat later).
private final class FrameCollector: @unchecked Sendable {
    private let batches = Mutex<[[SZNodePreviewSurface]]>([])
    func append(_ frames: [SZNodePreviewSurface]) { batches.withLock { $0.append(frames) } }
    var all: [[SZNodePreviewSurface]] { batches.withLock { $0 } }
    // Generous timeout: the suite runs in parallel with the GPU-heavy runtime tests, and a thumb
    // pass completing is at the mercy of queue contention there.
    func waitForBatches(_ n: Int, timeout: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if all.count >= n { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return all.count >= n
    }
}

/// BGRA pixel read straight out of a published IOSurface.
private func pixel(of surface: IOSurface, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
    surface.lock(options: [.readOnly], seed: nil)
    defer { surface.unlock(options: [.readOnly], seed: nil) }
    let row = surface.baseAddress.advanced(by: y * surface.bytesPerRow + x * 4)
        .assumingMemoryBound(to: UInt8.self)
    return (row[0], row[1], row[2], row[3])
}

private func isNear(_ value: UInt8, _ target: Int, tolerance: Int = 2) -> Bool {
    abs(Int(value) - target) <= tolerance
}

/// A loaded 1-node solid-color runtime (r 1.0, g 0.5, b 0.25 on texture output "color") + its
/// node id — the SZCaptureNodeOutputsTests scaffold.
@MainActor
private func solidRuntime(renderSize: (width: Int, height: Int)) throws -> (SZRuntime, SZNodeID, URL) {
    let runtime = try requireRuntime(renderSize: renderSize)
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
        .appending(path: "szruntime-stream-\(UUID().uuidString)").appending(path: "solid.subz")
    try SZProjectIO.save(project, to: dir)
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
    return (runtime, nodeID, dir.deletingLastPathComponent())
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func watchedPortPublishesFittedSurfaceWithRealPixels() async throws {
    let (runtime, nodeID, dir) = try solidRuntime(renderSize: (width: 64, height: 32))
    defer { try? FileManager.default.removeItem(at: dir) }
    let collector = FrameCollector()
    runtime.setPreviewFrameCallback { collector.append($0) }
    runtime.setPreviewThrottleForTests(0)
    runtime.setWatchedPreviews([(node: nodeID, port: "color")], maxDimension: 16)

    runtime.renderFrame()
    #expect(await collector.waitForBatches(1))
    let frame = try #require(collector.all.first?.first)
    #expect(frame.node == nodeID && frame.port == "color")
    #expect(frame.surface.width == 16 && frame.surface.height == 8)   // 64×32 long-edge → 16, aspect kept
    let center = pixel(of: frame.surface, x: 8, y: 4)
    #expect(isNear(center.r, 255) && isNear(center.g, 128) && isNear(center.b, 64) && center.a == 255)
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func surfacesAlternatePerPass() async throws {
    let (runtime, nodeID, dir) = try solidRuntime(renderSize: (width: 32, height: 32))
    defer { try? FileManager.default.removeItem(at: dir) }
    let collector = FrameCollector()
    runtime.setPreviewFrameCallback { collector.append($0) }
    runtime.setPreviewThrottleForTests(0)
    runtime.setWatchedPreviews([(node: nodeID, port: "color")], maxDimension: 16)

    runtime.renderFrame()
    #expect(await collector.waitForBatches(1))
    runtime.renderFrame()
    #expect(await collector.waitForBatches(2))
    let batches = collector.all
    let first = try #require(batches[0].first?.surface)
    let second = try #require(batches[1].first?.surface)
    #expect(first !== second)   // double buffer: identity alternates, so CA always recomposites
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func throttleCoalescesBackToBackFrames() async throws {
    let (runtime, nodeID, dir) = try solidRuntime(renderSize: (width: 32, height: 32))
    defer { try? FileManager.default.removeItem(at: dir) }
    runtime.renderFrame()   // populate the pool first — the watch call below one-shot-fills from it
    let collector = FrameCollector()
    runtime.setPreviewFrameCallback { collector.append($0) }
    // An UN-CLEARABLE window (not merely "huge"): under a starved parallel-test executor this task
    // can park many seconds between lines, and a finite window would legitimately elapse. The fill
    // below bypasses the throttle by design and stamps lastPass, after which no render can pass.
    runtime.setPreviewThrottleForTests(.greatestFiniteMagnitude)
    runtime.setWatchedPreviews([(node: nodeID, port: "color")], maxDimension: 16)
    #expect(await collector.waitForBatches(1))
    runtime.renderFrame()
    runtime.renderFrame()
    try? await Task.sleep(for: .milliseconds(150))
    #expect(collector.all.count == 1)   // renders inside the window → coalesced away
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func unwatchStopsPublishing() async throws {
    let (runtime, nodeID, dir) = try solidRuntime(renderSize: (width: 32, height: 32))
    defer { try? FileManager.default.removeItem(at: dir) }
    let collector = FrameCollector()
    runtime.setPreviewFrameCallback { collector.append($0) }
    runtime.setPreviewThrottleForTests(0)
    runtime.setWatchedPreviews([(node: nodeID, port: "color")], maxDimension: 16)
    runtime.renderFrame()
    #expect(await collector.waitForBatches(1))

    runtime.setWatchedPreviews([], maxDimension: 16)
    let count = collector.all.count
    runtime.renderFrame()
    try? await Task.sleep(for: .milliseconds(150))
    #expect(collector.all.count == count)
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func pausedFramesPublishNothing() async throws {
    let (runtime, nodeID, dir) = try solidRuntime(renderSize: (width: 32, height: 32))
    defer { try? FileManager.default.removeItem(at: dir) }
    let collector = FrameCollector()
    runtime.setPreviewFrameCallback { collector.append($0) }
    runtime.setPreviewThrottleForTests(0)
    runtime.setWatchedPreviews([(node: nodeID, port: "color")], maxDimension: 16)
    runtime.renderFrame()
    #expect(await collector.waitForBatches(1))

    runtime.setPaused(true)
    let count = collector.all.count
    _ = runtime.captureFrame()   // the paused held-frame path: must not encode a schedule pass
    try? await Task.sleep(for: .milliseconds(150))
    #expect(collector.all.count == count)
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func watchingWhilePausedFillsOnceFromTheHeldPool() async throws {
    let (runtime, nodeID, dir) = try solidRuntime(renderSize: (width: 32, height: 32))
    defer { try? FileManager.default.removeItem(at: dir) }
    runtime.renderFrame()          // populate the pool
    runtime.setPaused(true)

    let collector = FrameCollector()
    runtime.setPreviewFrameCallback { collector.append($0) }
    runtime.setWatchedPreviews([(node: nodeID, port: "color")], maxDimension: 16)   // paused one-shot
    #expect(await collector.waitForBatches(1))
    let frame = try #require(collector.all.first?.first)
    #expect(isNear(pixel(of: frame.surface, x: 8, y: 8).r, 255))
    try? await Task.sleep(for: .milliseconds(150))
    #expect(collector.all.count == 1)   // one fill, no stream while paused
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func neverWrittenPortPublishesNothing() async throws {
    let (runtime, nodeID, dir) = try solidRuntime(renderSize: (width: 32, height: 32))
    defer { try? FileManager.default.removeItem(at: dir) }
    let collector = FrameCollector()
    runtime.setPreviewFrameCallback { collector.append($0) }
    runtime.setPreviewThrottleForTests(0)
    runtime.setWatchedPreviews([(node: nodeID, port: "ghost")], maxDimension: 16)
    runtime.renderFrame()
    try? await Task.sleep(for: .milliseconds(150))
    #expect(collector.all.isEmpty)   // absence, not a fabricated blank
}
