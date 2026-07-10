// SPDX-License-Identifier: AGPL-3.0-only
// A topology-only reload (rewiring, moving the render endpoint) reuses every already-loaded node's
// module in place — ZERO recompiles — rebuilds the schedule, and preserves live input overrides.
// This is the incremental `loadGraph` path that replaced the recompile-every-node freeze.
import Testing
import Foundation
import Metal
@testable import SZRuntime
@testable import SZCore

// Clears the output to a gray = the `level` scalar input (read via the v3 ABI channel). Same shape as
// SZScalarInputTests' node — two instances of it act as independent color sources.
private let levelSource = """
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

private func writeSource(_ id: SZNodeID, in dir: URL) throws {
    let url = SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: id)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try levelSource.write(to: url, atomically: true, encoding: .utf8)
}

// Reads TWO scalar inputs and paints them into separate channels: R = `level`, G = `boost`. An input
// with no seeded value resolves to nil → 0 (channel stays black). Lets a test tell "port seeded" from
// "port absent" by reading one channel, independent of the other.
private let twoInputSource = """
import Metal
final class Node: SZNode {
    func update(_ ctx: SZFrameContext) {
        guard let out = ctx.outputTexture("color") else { return }
        let lvl = Double(ctx.inputFloat("level") ?? 0)
        let bst = Double(ctx.inputFloat("boost") ?? 0)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: lvl, green: bst, blue: 0, alpha: 1.0)
        pass.colorAttachments[0].storeAction = .store
        ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }
}
enum SZNodeMain { static func make() -> SZNode { Node() } }
"""

private func writeTwoInputSource(_ id: SZNodeID, in dir: URL) throws {
    let url = SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: id)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try twoInputSource.write(to: url, atomically: true, encoding: .utf8)
}

private func levelNode(_ id: SZNodeID, title: String, def: Double) -> SZNode {
    SZNode(id: id, kind: .generated, title: title,
           contract: SZNodeContract(title: title, sfSymbol: "", summary: "",
                                    inputs: [SZPort(name: "level", type: .float, def: .float(def))],
                                    outputs: [SZPort(name: "color", type: .texture, display: true)]),
           position: SZPoint(x: 0, y: 0))
}

/// Two independent source nodes; move the render endpoint between them (a pure topology edit). Assert:
/// both loaders are REUSED across each reload (identity stable ⇒ no recompile), the rebind takes effect
/// (rendered pixel follows the new endpoint), and a live slider override on a retained node SURVIVES the
/// reload (isn't reset to the contract default).
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func topologyReloadReusesLoadersRebindsAndKeepsOverrides() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))

    let idA = SZNodeID(), idB = SZNodeID()
    func project(endpoint: SZNodeID) -> SZProject {
        SZProject(name: "incremental",
                  graph: SZGraph(nodes: [levelNode(idA, title: "A", def: 0.25),   // → gray ≈ 64
                                         levelNode(idB, title: "B", def: 0.75)],   // → gray ≈ 191
                                 connections: [],
                                 renderEndpoint: SZPortRef(node: endpoint, port: "color")))
    }

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-incremental-\(UUID().uuidString)").appending(path: "g.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project(endpoint: idA), to: dir)
    for id in [idA, idB] { try writeSource(id, in: dir) }

    // v1 — endpoint on A. Seeded default 0.25 → ~64.
    try runtime.loadProject(at: dir)
    let loaders1 = runtime.loaderIdentities()
    #expect(Set(loaders1.keys) == [idA, idB])
    #expect(abs(Int(try #require(runtime.captureFrame()?.pixel(x: 8, y: 8)).r) - 64) <= 2)

    // Live override on A → 0.5 (~128). Must survive the topology reloads below.
    runtime.setInputValue(node: idA, port: "level", floats: [0.5])
    #expect(abs(Int(try #require(runtime.captureFrame()?.pixel(x: 8, y: 8)).r) - 128) <= 2)

    // Rewire — move the render endpoint to B (a topology-only edit: same node set, new schedule).
    try SZProjectIO.save(project(endpoint: idB), to: dir)
    try runtime.loadProject(at: dir)

    // Both modules were REUSED (same object identity) — zero recompiles.
    let loaders2 = runtime.loaderIdentities()
    #expect(loaders2 == loaders1, "topology reload must reuse loaders, not rebuild them")
    // Rebind took effect: endpoint now follows B's default 0.75 → ~191.
    #expect(abs(Int(try #require(runtime.captureFrame()?.pixel(x: 8, y: 8)).r) - 191) <= 2)

    // Point back at A and confirm A's OVERRIDE (0.5 → ~128) survived — not reset to its default (0.25 → 64).
    try SZProjectIO.save(project(endpoint: idA), to: dir)
    try runtime.loadProject(at: dir)
    #expect(runtime.loaderIdentities() == loaders1, "second topology reload must also reuse loaders")
    let afterA = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8)).r
    #expect(abs(Int(afterA) - 128) <= 2, "override 0.5 must survive incremental reload (got \(afterA))")
}

/// Adding a genuinely-new node compiles ONLY that node and leaves the existing one's loader untouched;
/// removing a node tears down only it. Proves the diff (added compiles, retained reused, removed dropped).
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func addingNodeCompilesOnlyNewOneRemovingDropsOnlyIt() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))

    let idA = SZNodeID(), idB = SZNodeID()
    func project(nodes: [SZNode], endpoint: SZNodeID) -> SZProject {
        SZProject(name: "grow",
                  graph: SZGraph(nodes: nodes, connections: [],
                                 renderEndpoint: SZPortRef(node: endpoint, port: "color")))
    }
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-grow-\(UUID().uuidString)").appending(path: "g.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

    let nodeA = levelNode(idA, title: "A", def: 0.25)
    let nodeB = levelNode(idB, title: "B", def: 0.75)
    try SZProjectIO.save(project(nodes: [nodeA], endpoint: idA), to: dir)
    for id in [idA, idB] { try writeSource(id, in: dir) }

    // Only A loaded.
    try runtime.loadProject(at: dir)
    let a1 = runtime.loaderIdentities()
    #expect(Set(a1.keys) == [idA])

    // Add B, endpoint → B. A is retained (identity stable); B is genuinely new (compiled + loaded).
    try SZProjectIO.save(project(nodes: [nodeA, nodeB], endpoint: idB), to: dir)
    try runtime.loadProject(at: dir)
    let a2 = runtime.loaderIdentities()
    #expect(Set(a2.keys) == [idA, idB])
    #expect(a2[idA] == a1[idA], "existing node A must be reused, not recompiled, when B is added")
    #expect(abs(Int(try #require(runtime.captureFrame()?.pixel(x: 8, y: 8)).r) - 191) <= 2)  // B's 0.75

    // Remove B (endpoint back to A). B is torn down; A stays the same live module.
    try SZProjectIO.save(project(nodes: [nodeA], endpoint: idA), to: dir)
    try runtime.loadProject(at: dir)
    let a3 = runtime.loaderIdentities()
    #expect(Set(a3.keys) == [idA])
    #expect(a3[idA] == a1[idA], "node A must remain the same live module after B is removed")
    #expect(!runtime.isNodeLoaded(idB), "removed node B must be torn down")
}

/// A retained node whose contract GAINS an input (the Director adds a port to an already-loaded node,
/// then a promote-reload installs the wider contract under the same id) must seed that NEW port from
/// its default — otherwise the per-frame resolver returns nothing, the node reads nil, and the input is
/// dead (renders as 0) until a cold reopen. Regression for the "toggle a just-added input does nothing"
/// bug. Also asserts an EXISTING input's live override survives the same reload (only new ports seed).
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func retainedNodeSeedsNewlyAddedInputAndKeepsExistingOverride() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))

    let id = SZNodeID()
    // Same source both times (reads level→R, boost→G); only the CONTRACT widens. v1 declares just
    // `level`; v2 adds `boost` (default 0.75). The node id is retained across the reload ⇒ no recompile.
    func project(inputs: [SZPort]) -> SZProject {
        SZProject(name: "widen",
                  graph: SZGraph(nodes: [SZNode(id: id, kind: .generated, title: "N",
                                                contract: SZNodeContract(
                                                    title: "N", sfSymbol: "", summary: "",
                                                    inputs: inputs,
                                                    outputs: [SZPort(name: "color", type: .texture, display: true)]),
                                                position: SZPoint(x: 0, y: 0))],
                                 connections: [],
                                 renderEndpoint: SZPortRef(node: id, port: "color")))
    }
    let levelOnly = [SZPort(name: "level", type: .float, def: .float(0.25))]        // R ≈ 64
    let withBoost = [SZPort(name: "level", type: .float, def: .float(0.25)),
                     SZPort(name: "boost", type: .float, def: .float(0.75))]        // G ≈ 191 once seeded

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-widen-\(UUID().uuidString)").appending(path: "g.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project(inputs: levelOnly), to: dir)
    try writeTwoInputSource(id, in: dir)

    // v1 — only `level` declared. `boost` is unseeded ⇒ nil ⇒ 0 (green channel black).
    try runtime.loadProject(at: dir)
    let loaders1 = runtime.loaderIdentities()
    let v1 = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(abs(Int(v1.r) - 64) <= 2)                                  // level default 0.25
    #expect(Int(v1.g) <= 2, "boost must be absent (0) before it is declared, got \(v1.g)")

    // Live override on the EXISTING `level` input → 0.5 (~128). Must survive the widening reload.
    runtime.setInputValue(node: id, port: "level", floats: [0.5])
    #expect(abs(Int(try #require(runtime.captureFrame()?.pixel(x: 8, y: 8)).r) - 128) <= 2)

    // v2 — contract gains `boost` (default 0.75). Same id ⇒ retained (loader reused, no recompile).
    try SZProjectIO.save(project(inputs: withBoost), to: dir)
    try runtime.loadProject(at: dir)
    #expect(runtime.loaderIdentities() == loaders1, "widening the contract must reuse the loader, not rebuild it")
    let v2 = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(abs(Int(v2.g) - 191) <= 2, "newly-added `boost` must seed from its default 0.75, got \(v2.g)")
    #expect(abs(Int(v2.r) - 128) <= 2, "existing `level` override 0.5 must survive the reload, got \(v2.r)")
}

/// Builds a one-node project whose single node id is stable across reloads (so it is RETAINED, not
/// recompiled) with a given input contract and node source. The contract is what varies between reloads.
private func oneNodeProject(_ id: SZNodeID, inputs: [SZPort],
                            outputs: [SZPort] = [SZPort(name: "color", type: .texture, display: true)],
                            endpoint: String = "color") -> SZProject {
    SZProject(name: "reconcile",
              graph: SZGraph(nodes: [SZNode(id: id, kind: .generated, title: "N",
                                            contract: SZNodeContract(title: "N", sfSymbol: "", summary: "",
                                                                     inputs: inputs, outputs: outputs),
                                            position: SZPoint(x: 0, y: 0))],
                             connections: [],
                             renderEndpoint: SZPortRef(node: id, port: endpoint)))
}

/// REMOVE: a retained node whose contract DROPS an input must prune that input's live value (the render
/// falls back to the port's absence), while an UNTOUCHED input's override survives. Same `twoInputSource`
/// (level→R, boost→G); override both, then reload with `boost` removed.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func retainedNodePrunesRemovedInputAndKeepsOtherOverride() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))

    let id = SZNodeID()
    let both = [SZPort(name: "level", type: .float, def: .float(0.25)),
                SZPort(name: "boost", type: .float, def: .float(0.25))]
    let levelOnly = [SZPort(name: "level", type: .float, def: .float(0.25))]

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-remove-\(UUID().uuidString)").appending(path: "g.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(oneNodeProject(id, inputs: both), to: dir)
    try writeTwoInputSource(id, in: dir)

    // v1 — both declared; override both to 0.5 (~128 on R and G).
    try runtime.loadProject(at: dir)
    let loaders1 = runtime.loaderIdentities()
    runtime.setInputValue(node: id, port: "level", floats: [0.5])
    runtime.setInputValue(node: id, port: "boost", floats: [0.5])
    let v1 = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(abs(Int(v1.r) - 128) <= 2)
    #expect(abs(Int(v1.g) - 128) <= 2)

    // v2 — `boost` removed. Its override is pruned ⇒ nil ⇒ G black; `level` override survives.
    try SZProjectIO.save(oneNodeProject(id, inputs: levelOnly), to: dir)
    try runtime.loadProject(at: dir)
    #expect(runtime.loaderIdentities() == loaders1, "removing an input must reuse the loader, not rebuild it")
    let v2 = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(Int(v2.g) <= 2, "removed `boost` value must be pruned (renders 0), got \(v2.g)")
    #expect(abs(Int(v2.r) - 128) <= 2, "untouched `level` override 0.5 must survive, got \(v2.r)")
}

/// RENAME: with no stable port identity, a rename is remove+add — the OLD name's override must NOT leak.
/// Override `boost`, then rename it (`boost`→`gain`) while the source still reads `boost`: the old value
/// is dropped (G falls to 0) rather than surviving under the new name. Codifies the settled semantics.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func retainedNodeDropsOverrideOnRename() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))

    let id = SZNodeID()
    let withBoost = [SZPort(name: "level", type: .float, def: .float(0.25)),
                     SZPort(name: "boost", type: .float, def: .float(0.25))]
    let renamed = [SZPort(name: "level", type: .float, def: .float(0.25)),
                   SZPort(name: "gain", type: .float, def: .float(0.25))]   // source still reads `boost`

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-rename-\(UUID().uuidString)").appending(path: "g.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(oneNodeProject(id, inputs: withBoost), to: dir)
    try writeTwoInputSource(id, in: dir)

    try runtime.loadProject(at: dir)
    let loaders1 = runtime.loaderIdentities()
    runtime.setInputValue(node: id, port: "boost", floats: [0.75])   // G ~191
    #expect(abs(Int(try #require(runtime.captureFrame()?.pixel(x: 8, y: 8)).g) - 191) <= 2)

    // Rename `boost`→`gain`. The source reads `boost`, now undeclared ⇒ nil ⇒ G black. The 0.75 override
    // does NOT reappear under `gain` (deterministic remove+add — no override carried across a rename).
    try SZProjectIO.save(oneNodeProject(id, inputs: renamed), to: dir)
    try runtime.loadProject(at: dir)
    #expect(runtime.loaderIdentities() == loaders1, "renaming an input must reuse the loader, not rebuild it")
    #expect(Int(try #require(runtime.captureFrame()?.pixel(x: 8, y: 8)).g) <= 2,
            "a renamed port must not carry the old override — it starts fresh")
}

/// RETYPE across channels: a port declared `float` (rides the `inputValues` channel) redeclared as
/// `string` (rides the `inputStrings` channel) must drop the stale float and seed the string default. The
/// source reads `level`→R (float) and `tint`→G via the STRING channel; when `tint` is a float it reads as
/// nil (G=0), and once retyped to a string default "hi" it reads through (G=255).
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func retainedNodeReseedsInputRetypedAcrossChannels() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))

    let id = SZNodeID()
    let tintFloat = [SZPort(name: "level", type: .float, def: .float(0.25)),
                     SZPort(name: "tint", type: .float, def: .float(0.9))]      // wrong channel for the source
    let tintString = [SZPort(name: "level", type: .float, def: .float(0.25)),
                      SZPort(name: "tint", type: .string, def: .string("hi"))]  // now the string channel

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-retype-\(UUID().uuidString)").appending(path: "g.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(oneNodeProject(id, inputs: tintFloat), to: dir)
    // Reads level→R (float channel) and tint→G via the STRING channel (G=255 iff tint == "hi").
    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            guard let out = ctx.outputTexture("color") else { return }
            let lvl = Double(ctx.inputFloat("level") ?? 0)
            let g = (ctx.inputString("tint") == "hi") ? 1.0 : 0.0
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = out
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: lvl, green: g, blue: 0, alpha: 1.0)
            pass.colorAttachments[0].storeAction = .store
            ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: id), atomically: true, encoding: .utf8)

    // v1 — `tint` is a float: it seeds the float channel, but the source reads the string channel ⇒ G=0.
    try runtime.loadProject(at: dir)
    let loaders1 = runtime.loaderIdentities()
    let v1 = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(abs(Int(v1.r) - 64) <= 2)
    #expect(Int(v1.g) <= 2, "a float-typed `tint` must not appear on the string channel, got \(v1.g)")

    // v2 — `tint` retyped to string "hi": the stale float is dropped and the string default seeds ⇒ G=255.
    try SZProjectIO.save(oneNodeProject(id, inputs: tintString), to: dir)
    try runtime.loadProject(at: dir)
    #expect(runtime.loaderIdentities() == loaders1, "retyping an input must reuse the loader, not rebuild it")
    let v2 = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(Int(v2.g) >= 250, "retyped-to-string `tint` must seed the string channel from its default, got \(v2.g)")
    #expect(abs(Int(v2.r) - 64) <= 2, "unrelated `level` must be unaffected, got \(v2.r)")
}

/// OUTPUT-ADD (the "input/output" half of the ask): a retained node whose contract gains a texture OUTPUT
/// needs no seeding — the scheduler allocates output textures per frame from the contract, so the new
/// output renders immediately after reload, with the loader reused. Guards the plan's "outputs already
/// self-apply" claim.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func retainedNodeGainsOutputWithoutReopen() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))

    let id = SZNodeID()
    let outA = [SZPort(name: "a", type: .texture, display: true)]
    let outAB = [SZPort(name: "a", type: .texture, display: true),
                 SZPort(name: "b", type: .texture, display: true)]

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-outadd-\(UUID().uuidString)").appending(path: "g.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(oneNodeProject(id, inputs: [], outputs: outA, endpoint: "a"), to: dir)
    // Paints output `a` red and output `b` green — each only when that output is declared (else nil ⇒ skip).
    try """
    import Metal
    final class Node: SZNode {
        private func fill(_ tex: MTLTexture, _ r: Double, _ g: Double, _ ctx: SZFrameContext) {
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = tex
            p.colorAttachments[0].loadAction = .clear
            p.colorAttachments[0].clearColor = MTLClearColor(red: r, green: g, blue: 0, alpha: 1.0)
            p.colorAttachments[0].storeAction = .store
            ctx.commandBuffer.makeRenderCommandEncoder(descriptor: p)?.endEncoding()
        }
        func update(_ ctx: SZFrameContext) {
            if let a = ctx.outputTexture("a") { fill(a, 1.0, 0.0, ctx) }
            if let b = ctx.outputTexture("b") { fill(b, 0.0, 1.0, ctx) }
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: id), atomically: true, encoding: .utf8)

    // v1 — only output `a` (red) declared; endpoint on `a`.
    try runtime.loadProject(at: dir)
    let loaders1 = runtime.loaderIdentities()
    let v1 = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(Int(v1.r) >= 250 && Int(v1.g) <= 5, "output `a` should render red")

    // v2 — output `b` (green) added, endpoint moved to it. Loader reused; the new output renders at once.
    try SZProjectIO.save(oneNodeProject(id, inputs: [], outputs: outAB, endpoint: "b"), to: dir)
    try runtime.loadProject(at: dir)
    #expect(runtime.loaderIdentities() == loaders1, "adding an output must reuse the loader, not rebuild it")
    let v2 = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(Int(v2.g) >= 250 && Int(v2.r) <= 5, "newly-added output `b` should render green without a reopen, got r=\(v2.r) g=\(v2.g)")
}

/// RETYPE within the float channel that CHANGES ARITY: a scalar `float` override must be DROPPED (not kept
/// as a wrong-length value) when the port is redeclared `float3`, and the new float3 default seeds instead —
/// otherwise the node reads a 1-element array where it expects 3 (garbage / out-of-bounds). The source reads
/// `tint` as a 3-vector and falls back to RED when it isn't exactly 3 elements, so the fix is observable:
/// a wrongly-kept scalar override → count 1 → red; the correctly-seeded float3 default `[0,1,0]` → green.
@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func retainedNodeDropsArityMismatchedOverrideOnRetype() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))

    let id = SZNodeID()
    let tintScalar = [SZPort(name: "tint", type: .float, def: .float(0.3))]
    let tintVec = [SZPort(name: "tint", type: .float3, def: .float3([0, 1, 0]))]   // green

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szruntime-arity-\(UUID().uuidString)").appending(path: "g.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(oneNodeProject(id, inputs: tintScalar), to: dir)
    // Reads `tint` as a 3-vector → renders (r,g,b); anything that isn't exactly 3 elements → red.
    try """
    import Metal
    final class Node: SZNode {
        func update(_ ctx: SZFrameContext) {
            guard let out = ctx.outputTexture("color") else { return }
            let t = ctx.inputFloats("tint") ?? []
            let ok = t.count == 3
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = out
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: ok ? Double(t[0]) : 1.0, green: ok ? Double(t[1]) : 0.0, blue: ok ? Double(t[2]) : 0.0, alpha: 1.0)
            pass.colorAttachments[0].storeAction = .store
            ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }
    enum SZNodeMain { static func make() -> SZNode { Node() } }
    """.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: id), atomically: true, encoding: .utf8)

    // v1 — `tint` is a scalar; override it to [0.3]. Source sees count 1 (not a 3-vector) ⇒ red.
    try runtime.loadProject(at: dir)
    let loaders1 = runtime.loaderIdentities()
    runtime.setInputValue(node: id, port: "tint", floats: [0.3])
    let v1 = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(Int(v1.r) >= 250 && Int(v1.g) <= 5, "scalar tint renders the count!=3 red fallback")

    // v2 — retype `tint` to float3 (green default). The count-1 override no longer fits the arity ⇒ dropped ⇒
    // the float3 default [0,1,0] seeds ⇒ green. (Without the arity check it would keep [0.3] ⇒ still red.)
    try SZProjectIO.save(oneNodeProject(id, inputs: tintVec), to: dir)
    try runtime.loadProject(at: dir)
    #expect(runtime.loaderIdentities() == loaders1, "retype must reuse the loader, not rebuild it")
    let v2 = try #require(runtime.captureFrame()?.pixel(x: 8, y: 8))
    #expect(Int(v2.g) >= 250 && Int(v2.r) <= 5,
            "an arity-mismatched override must drop, seeding the float3 default (green), got r=\(v2.r) g=\(v2.g)")
}
