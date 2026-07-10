// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import Metal
@testable import SZRuntime

/// A trivial `Node.swift` compiles via swiftc into a signed dylib, dlopens, and its
/// setup/update/teardown lifecycle runs without crashing — with the host ABI version matching.
/// (Actual offscreen rendering + pixel readback are covered by SZGraphRenderTests.)
@Test(.enabled(if: SZGPU.isAvailable)) func compilesLoadsAndRunsLifecycle() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())

    let work = FileManager.default.temporaryDirectory.appending(path: "szruntime-step2-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: work) }
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    // A node that does nothing — Step 2 only proves the lifecycle wiring, not rendering.
    let nodeSource = work.appending(path: "Node.swift")
    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {}
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: nodeSource, atomically: true, encoding: .utf8)

    let dylib = try SZToolchain().compile(nodeSource: nodeSource, into: work.appending(path: "build"))
    #expect(FileManager.default.fileExists(atPath: dylib.path))

    let loader = SZLoader()
    defer { loader.unload() }

    let commandBuffer = try #require(queue.makeCommandBuffer())
    var ctx = SZRuntimeContextRaw()
    ctx.device = Unmanaged.passUnretained(device as AnyObject).toOpaque()
    ctx.commandBuffer = Unmanaged.passUnretained(commandBuffer as AnyObject).toOpaque()

    try withUnsafeMutablePointer(to: &ctx) { pointer in
        let raw = UnsafeMutableRawPointer(pointer)
        try loader.load(
            dylib: dylib,
            runtimeLoadsDir: work.appending(path: "runtime-loads"),
            setupContext: raw
        )
        #expect(loader.isLoaded)
        // update() succeeds (status 0) even with no output texture bound.
        #expect(loader.renderFrame(context: raw) == 0)
        // Reload the same dylib: teardown-then-swap must not crash and stays loaded.
        try loader.load(
            dylib: dylib,
            runtimeLoadsDir: work.appending(path: "runtime-loads"),
            setupContext: raw
        )
        #expect(loader.renderFrame(context: raw) == 0)
    }
}

/// Ordering guard: `open` must NOT run `setup()`, and `activate` must run it. With this split the
/// runtime can tear an OLD node (releasing an exclusive device like the camera's `AVCaptureSession`)
/// down BEFORE the new node's `setup()` runs — otherwise the two sessions contend and the new feed
/// freezes. We drive the exact `loadGraph` sequence on two loaders and assert the lifecycle order:
/// `setupA → teardownA → setupB` (without the split it would be `setupA → setupB → teardownA`).
@Test(.enabled(if: SZGPU.isAvailable)) func openDefersSetupUntilActivateSoOldNodeTearsDownFirst() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())

    let work = FileManager.default.temporaryDirectory.appending(path: "szruntime-order-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: work) }
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

    // A probe node that appends "setup<TAG>" / "teardown<TAG>" to the file named by $SZ_ORDER_LOG.
    func probeNode(tag: String, at url: URL) throws {
        try """
        import Metal
        import Foundation
        final class Node: SZNode {
            func setup(_ ctx: SZSetupContext) { Node.log("setup\(tag)") }
            func update(_ ctx: SZFrameContext) {}
            func teardown() { Node.log("teardown\(tag)") }
            static func log(_ s: String) {
                guard let p = ProcessInfo.processInfo.environment["SZ_ORDER_LOG"],
                      let h = FileHandle(forWritingAtPath: p) else { return }
                defer { try? h.close() }
                h.seekToEndOfFile()
                h.write((s + "\\n").data(using: .utf8)!)
            }
        }
        enum SZNodeMain { static func make() -> SZNode { Node() } }
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    let log = work.appending(path: "order.log")
    FileManager.default.createFile(atPath: log.path, contents: Data())
    setenv("SZ_ORDER_LOG", log.path, 1)
    defer { unsetenv("SZ_ORDER_LOG") }

    let srcA = work.appending(path: "A/Node.swift"), srcB = work.appending(path: "B/Node.swift")
    try FileManager.default.createDirectory(at: srcA.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: srcB.deletingLastPathComponent(), withIntermediateDirectories: true)
    try probeNode(tag: "A", at: srcA)
    try probeNode(tag: "B", at: srcB)
    let dylibA = try SZToolchain().compile(nodeSource: srcA, into: work.appending(path: "buildA"))
    let dylibB = try SZToolchain().compile(nodeSource: srcB, into: work.appending(path: "buildB"))

    var ctx = SZRuntimeContextRaw()
    ctx.device = Unmanaged.passUnretained(device as AnyObject).toOpaque()
    try withUnsafeMutablePointer(to: &ctx) { pointer in
        let raw = UnsafeMutableRawPointer(pointer)
        // Live graph = A.
        let loaderA = SZLoader()
        try loaderA.load(dylib: dylibA, runtimeLoadsDir: work.appending(path: "rlA"), setupContext: raw)

        // Reload to graph = B, the loadGraph way: open B (no setup) → unload A → activate B.
        let loaderB = SZLoader()
        try loaderB.open(dylib: dylibB, runtimeLoadsDir: work.appending(path: "rlB"))
        loaderA.unload()
        loaderB.activate(setupContext: raw)
        loaderB.unload()
    }

    let order = (try String(contentsOf: log, encoding: .utf8))
        .split(separator: "\n").map(String.init)
    // A is set up, then (crucially) torn down BEFORE B is set up.
    #expect(order == ["setupA", "teardownA", "setupB", "teardownB"])
}
