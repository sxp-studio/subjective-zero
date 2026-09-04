// SPDX-License-Identifier: AGPL-3.0-only
// ABI v9: a node saying why it produced nothing (`ctx.reportError`). Two properties matter here and
// neither is provable by reading the code — the message has to survive a real compile, a real dylib
// boundary and a real frame:
//
//  1. it ARRIVES: the string a node writes on the render thread reaches the host after the frame;
//  2. it is a LEVEL, not an event: a node that stops reporting is a node with no fault, and a node
//     that reports every frame is one publish, not sixty a second.
//
// The second is the whole reason the host dedupes instead of asking node authors to gate their calls.
import Testing
import Foundation
import Metal
import Synchronization
@testable import SZRuntime
@testable import SZCore

/// Collects the runtime's published fault sets off the completion thread.
private final class ErrorCollector: @unchecked Sendable {
    private let published = Mutex<[[SZNodeID: String]]>([])
    func append(_ errors: [SZNodeID: String]) { published.withLock { $0.append(errors) } }
    var all: [[SZNodeID: String]] { published.withLock { $0 } }
    /// Generous timeout for the same reason the preview collector's is: this suite runs in parallel
    /// with the GPU-heavy runtime tests and a command buffer completing is at the mercy of that.
    func waitForPublishes(_ n: Int, timeout: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if all.count >= n { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return all.count >= n
    }
}

/// A one-node project whose node reports a fault only while its `mode` input says "fail" — the input
/// is the test's hand on the fault, so reporting and not-reporting are the same node on the same frame
/// loop rather than two different builds.
@MainActor
private func reportingRuntime(_ nodeID: SZNodeID) throws -> (runtime: SZRuntime, project: URL, root: URL) {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let project = SZProject(
        name: "report-error",
        graph: SZGraph(
            nodes: [
                SZNode(id: nodeID, kind: .generated, title: "loader",
                       contract: SZNodeContract(
                        title: "loader", sfSymbol: "", summary: "",
                        inputs: [SZPort(name: "mode", type: .string, def: .string("ok"))],
                        outputs: [SZPort(name: "color", type: .texture, display: true)]),
                       position: SZPoint(x: 0, y: 0)),
            ],
            renderEndpoint: SZPortRef(node: nodeID, port: "color")))
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-report-\(UUID().uuidString)").appending(path: "report.subz")
    try SZProjectIO.save(project, to: dir)
    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            guard let out = ctx.outputTexture("color") else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = out
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            // Reported EVERY frame the fault holds, exactly as the ABI asks of a node author.
            if ctx.inputString("mode") == "fail" {
                ctx.reportError("could not decode cat.tiff: unsupported format")
            }
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: nodeID, target: .native), atomically: true, encoding: .utf8)
    try runtime.loadProject(at: dir)
    return (runtime, dir, dir.deletingLastPathComponent())
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func reportedErrorReachesTheHostAndClearsWhenItStops() async throws {
    let nodeID = SZNodeID()
    let (runtime, project, dir) = try reportingRuntime(nodeID)
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = project
    let collector = ErrorCollector()
    runtime.setNodeErrorCallback { collector.append($0) }

    // A healthy node says nothing: no fault, and no publish to say so.
    runtime.renderFrame()
    #expect(runtime.nodeErrors().isEmpty)
    #expect(collector.all.isEmpty)

    // The fault appears — through a real compile, a real dylib and a real frame.
    runtime.setInputString(node: nodeID, port: "mode", string: "fail")
    runtime.renderFrame()
    #expect(await collector.waitForPublishes(1))
    #expect(runtime.nodeErrors()[nodeID] == "could not decode cat.tiff: unsupported format")
    #expect(collector.all.last?[nodeID] == "could not decode cat.tiff: unsupported format")

    // The input is fixed. The node simply stops saying it, and that absence IS the clear: nothing in
    // the node, the runtime or the host had to remember to erase anything.
    runtime.setInputString(node: nodeID, port: "mode", string: "ok")
    runtime.renderFrame()
    #expect(await collector.waitForPublishes(2))
    #expect(runtime.nodeErrors().isEmpty)
    #expect(collector.all.last?.isEmpty == true)
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func repeatedReportPublishesOnceNotPerFrame() async throws {
    let nodeID = SZNodeID()
    let (runtime, project, dir) = try reportingRuntime(nodeID)
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = project
    let collector = ErrorCollector()
    runtime.setNodeErrorCallback { collector.append($0) }

    runtime.setInputString(node: nodeID, port: "mode", string: "fail")
    for _ in 0..<10 { runtime.renderFrame() }
    #expect(await collector.waitForPublishes(1))

    // Ten frames, ten `reportError` calls, ONE publish — the acceptance criterion this channel would
    // otherwise fail: a node reporting a failed decode at 60 Hz must be one pill and one log line.
    // Settle first, so a late completion handler can't make an over-publish look like a pass.
    try await Task.sleep(for: .milliseconds(200))
    #expect(collector.all.count == 1)
    #expect(runtime.nodeErrors()[nodeID] != nil)
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func reportedErrorIsCappedRatherThanCarryingALog() async throws {
    let nodeID = SZNodeID()
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let project = SZProject(
        name: "report-cap",
        graph: SZGraph(nodes: [
            SZNode(id: nodeID, kind: .generated, title: "shouty",
                   contract: SZNodeContract(title: "shouty", sfSymbol: "", summary: "", inputs: [],
                                            outputs: [SZPort(name: "color", type: .texture, display: true)]),
                   position: SZPoint(x: 0, y: 0)),
        ], renderEndpoint: SZPortRef(node: nodeID, port: "color")))
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-report-cap-\(UUID().uuidString)").appending(path: "cap.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)
    // A node dumping a compiler log into the channel: the reason lands in a pill and in an agent's
    // JSON, and it crosses on every frame, so the host bounds it rather than trusting the node.
    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            ctx.reportError(String(repeating: "x", count: 5000))
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: nodeID, target: .native), atomically: true, encoding: .utf8)
    try runtime.loadProject(at: dir)

    runtime.renderFrame()
    #expect(runtime.nodeErrors()[nodeID]?.utf8.count == SZFrameBindings.maxErrorBytes)
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func unloadingANodeRetiresItsReportedError() async throws {
    let nodeID = SZNodeID()
    let (runtime, project, dir) = try reportingRuntime(nodeID)
    defer { try? FileManager.default.removeItem(at: dir) }
    let collector = ErrorCollector()
    runtime.setNodeErrorCallback { collector.append($0) }

    runtime.setInputString(node: nodeID, port: "mode", string: "fail")
    runtime.renderFrame()
    #expect(await collector.waitForPublishes(1))

    // The node leaves the graph. A fault belongs to the module that reported it, and there may be no
    // further frame in which to notice — an emptied graph has nothing to render — so the retirement
    // publishes on the swap rather than waiting for one.
    try SZProjectIO.save(SZProject(name: "report-error", graph: SZGraph(nodes: [])), to: project)
    try runtime.loadProject(at: project)
    #expect(await collector.waitForPublishes(2))
    #expect(runtime.nodeErrors().isEmpty)
    #expect(collector.all.last?.isEmpty == true)
}

/// The cost argument for pushing on change instead of polling: the normal case is that nothing is
/// wrong, and the normal case must cost nothing. An implementation that publishes the map every frame
/// and lets the host diff it passes every other test here and fails only this one.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func aHealthyGraphPublishesNothingAtAll() async throws {
    let nodeID = SZNodeID()
    let (runtime, _, dir) = try reportingRuntime(nodeID)
    defer { try? FileManager.default.removeItem(at: dir) }
    let collector = ErrorCollector()
    runtime.setNodeErrorCallback { collector.append($0) }

    for _ in 0..<100 { runtime.renderFrame() }
    try await Task.sleep(for: .milliseconds(200))
    #expect(collector.all.isEmpty)
}

/// Every distinct message is published: the runtime does not coalesce, deliberately. What it must never
/// do is publish a set it already sent — the host relies on that to keep `store.mutate` off the frame
/// path, and the host's own delay (`SZHost.scheduleNodeErrorApply`) does the coalescing on its own clock.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func everyDistinctMessageIsPublishedAndNoRepeatIs() async throws {
    let nodeID = SZNodeID()
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let project = SZProject(
        name: "report-vary",
        graph: SZGraph(nodes: [
            SZNode(id: nodeID, kind: .generated, title: "chatty",
                   contract: SZNodeContract(title: "chatty", sfSymbol: "", summary: "", inputs: [],
                                            outputs: [SZPort(name: "color", type: .texture, display: true)]),
                   position: SZPoint(x: 0, y: 0)),
        ], renderEndpoint: SZPortRef(node: nodeID, port: "color")))
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-report-vary-\(UUID().uuidString)").appending(path: "vary.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)
    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            ctx.reportError("decode failed at frame \\(ctx.frameIndex)")
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: nodeID, target: .native), atomically: true, encoding: .utf8)
    try runtime.loadProject(at: dir)

    let collector = ErrorCollector()
    runtime.setNodeErrorCallback { collector.append($0) }
    for _ in 0..<5 { runtime.renderFrame() }
    #expect(await collector.waitForPublishes(5))
    #expect(collector.all.count == 5)
    #expect(Set(collector.all.map { $0[nodeID] }).count == 5)   // five distinct messages, five publishes
}

/// The engine lock is not reentrant, so a sink that re-enters a lock-taking API would DEADLOCK rather
/// than fail — a fine outcome for a test, a terrible one in production. This turns the class header's
/// prose rule ("the engine lock never calls into the loop or a surface queue") into an executable one.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func theSinkNeverRunsUnderTheEngineLock() async throws {
    let nodeID = SZNodeID()
    let (runtime, _, dir) = try reportingRuntime(nodeID)
    defer { try? FileManager.default.removeItem(at: dir) }
    let reentered = Mutex(false)
    runtime.setNodeErrorCallback { [weak runtime] _ in
        _ = runtime?.isPaused          // takes the engine lock; deadlocks if we are still holding it
        reentered.withLock { $0 = true }
    }

    runtime.setInputString(node: nodeID, port: "mode", string: "fail")
    runtime.renderFrame()
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline, !reentered.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(reentered.withLock { $0 })
}
