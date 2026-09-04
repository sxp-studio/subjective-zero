// SPDX-License-Identifier: AGPL-3.0-only
// Node modules are content-addressed, so reopening a project is a lookup rather than a swiftc run per
// node. What must hold: an unchanged source never rebuilds, an edited one does, one artifact per node
// survives, a no-op save doesn't reload, and steps/cards stay UNcached.
import Testing
import Foundation
@testable import SZRuntime
@testable import SZCore

private let paintSource = """
import Metal
final class Node: SZNode {
    func update(_ ctx: SZFrameContext) {
        guard let out = ctx.outputTexture("color") else { return }
        let v = Double(ctx.inputFloat("level") ?? 0)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: v, green: v, blue: v, alpha: 1.0)
        pass.colorAttachments[0].storeAction = .store
        ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }
}
enum SZNodeMain { static func make() -> SZNode { Node() } }
"""

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "szbuildcache-\(UUID().uuidString)")
}

/// Same bytes in, same artifact out, no second compile. The modification date would move on a rebuild.
@Test(.enabled(if: SZGPU.isAvailable)) func anUnchangedSourceIsNotCompiledTwice() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appending(path: "Node.swift")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try paintSource.write(to: source, atomically: true, encoding: .utf8)

    let toolchain = SZToolchain()
    let buildDir = dir.appending(path: "build")
    let first = try toolchain.compile(nodeSource: source, into: buildDir)
    let built = try #require(FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date)

    let second = try toolchain.compile(nodeSource: source, into: buildDir)
    #expect(second == first)
    let after = try #require(FileManager.default.attributesOfItem(atPath: second.path)[.modificationDate] as? Date)
    #expect(after == built, "the artifact was rebuilt instead of reused")
}

/// An edit must land somewhere new, and the superseded artifact must not accumulate.
@Test(.enabled(if: SZGPU.isAvailable)) func anEditedSourceRebuildsAndSweepsTheOldArtifact() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = dir.appending(path: "Node.swift")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try paintSource.write(to: source, atomically: true, encoding: .utf8)

    let toolchain = SZToolchain()
    let buildDir = dir.appending(path: "build")
    let first = try toolchain.compile(nodeSource: source, into: buildDir)

    try paintSource.replacingOccurrences(of: "?? 0", with: "?? 1")
        .write(to: source, atomically: true, encoding: .utf8)
    let second = try toolchain.compile(nodeSource: source, into: buildDir)

    #expect(second != first)
    #expect(!FileManager.default.fileExists(atPath: first.path), "the superseded artifact was kept")
    let entries = try FileManager.default.contentsOfDirectory(at: buildDir, includingPropertiesForKeys: nil)
    #expect(entries.count == 1, "one live artifact per node, found \(entries.count)")
}

private func paintNode(_ id: SZNodeID, def: Double) -> SZNode {
    SZNode(id: id, kind: .generated, title: "paint",
           contract: SZNodeContract(title: "paint", sfSymbol: "", summary: "",
                                    inputs: [SZPort(name: "level", type: .float, def: .float(def))],
                                    outputs: [SZPort(name: "color", type: .texture, display: true)]),
           position: SZPoint(x: 0, y: 0))
}

private func writeProject(_ project: SZProject, ids: [SZNodeID]) throws -> URL {
    let dir = scratch().appending(path: "g.subz")
    try SZProjectIO.save(project, to: dir)
    for id in ids {
        let url = SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: id, target: .native)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try paintSource.write(to: url, atomically: true, encoding: .utf8)
    }
    return dir
}

/// The cold-open path must land exactly where the synchronous load does: same modules, same pixel.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func aPreparedLoadCommitsToTheSameGraphAsASynchronousOne() async throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let id = SZNodeID()
    let project = SZProject(name: "prepared",
                            graph: SZGraph(nodes: [paintNode(id, def: 0.5)], connections: [],
                                           renderEndpoint: SZPortRef(node: id, port: "color")))
    let dir = try writeProject(project, ids: [id])
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    try runtime.commit(await runtime.prepareProject(project, at: dir))

    #expect(Set(runtime.loaderIdentities().keys) == [id])
    #expect(abs(Int(try #require(runtime.captureFrame()?.pixel(x: 8, y: 8)).r) - 128) <= 2)
}

/// A no-op save resolves to the live artifact. Reloading would map a second copy of the same module
/// and re-run `setup()`, restarting whatever device the node holds.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func reloadingAnUnchangedSourceLeavesTheLiveModuleAlone() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let id = SZNodeID()
    let project = SZProject(name: "noop",
                            graph: SZGraph(nodes: [paintNode(id, def: 0.25)], connections: [],
                                           renderEndpoint: SZPortRef(node: id, port: "color")))
    let dir = try writeProject(project, ids: [id])
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    try runtime.loadProject(at: dir)
    let before = runtime.loaderIdentities()

    let source = SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: id, target: .native)
    try paintSource.write(to: source, atomically: true, encoding: .utf8)   // same bytes, new mtime
    try runtime.reloadNode(id: id, source: source)
    #expect(runtime.loaderIdentities() == before)

    // An actual edit still reloads — the guard is about content, not about refusing work.
    try paintSource.replacingOccurrences(of: "?? 0", with: "?? 0.75")
        .write(to: source, atomically: true, encoding: .utf8)
    try runtime.reloadNode(id: id, source: source)
    #expect(abs(Int(try #require(runtime.captureFrame()?.pixel(x: 8, y: 8)).r) - 64) <= 2)
}

private let stepSource = """
let step = SZStep(outcomes: ["answer"]) { _ in "answer" }
"""

/// Steps and cards must NOT be cached: neither ever `dlclose`s, so reusing an artifact would put two
/// images with one module name in the process. Pins the tier split against a later "make it uniform".
@Test(.enabled(if: SZGPU.isAvailable)) func stepsAreRebuiltRatherThanReusedFromCache() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let source = dir.appending(path: "Step.swift")
    try stepSource.write(to: source, atomically: true, encoding: .utf8)

    let toolchain = SZToolchain()
    let buildDir = dir.appending(path: "build")
    let first = try toolchain.compile(stepSource: source, into: buildDir)
    let built = try #require(FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date)

    let second = try toolchain.compile(stepSource: source, into: buildDir)
    let after = try #require(FileManager.default.attributesOfItem(atPath: second.path)[.modificationDate] as? Date)
    #expect(after > built, "an unchanged step must still rebuild, for a fresh module name")
}
