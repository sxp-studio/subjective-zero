// SPDX-License-Identifier: AGPL-3.0-only
// SZRuntime — the lightweight rendering engine (RUNTIME.md). Owns Metal (via SZAssetManager), compiles +
// loads each node of a graph (SZToolchain + one SZLoader per node), and drives the per-frame schedule
// (SZScheduler) into the asset pool. `captureFrame()` is the real framebuffer readback behind
// `agent_view_frame` (MCP.md).
//
// The SZCore seam protocols (SZNodeCompiler/SZRenderer) are still deferred — the host and tests call
// these concrete methods directly (seams earned, not scheduled).
import Foundation
import Metal
import MetalKit
import MetalPerformanceShaders
import Synchronization
import SZCore

/// Result of a compile-check (`compileNodeSource`). `.failed` carries the swiftc log for the agent's
/// fix loop / `debug_get_build_errors`.
/// Something loaded between prepare and commit, so the prepared modules no longer cover the graph.
/// Nothing retries: it surfaces to the user, hence the readable sentence.
public enum SZLoadError: Error, LocalizedError, CustomStringConvertible {
    case staleLoad
    public var description: String { "the graph changed while this load was being prepared" }
    public var errorDescription: String? { description }
}

public enum SZBuildResult: Sendable, Equatable {
    case ok
    case failed(String)
}

/// Threading model (why this is not `@MainActor`):
/// - The runtime owns THE render loop: `SZRenderLoop`'s pacing display link fires `tick()` on its own
///   thread. Viewports are `SZRenderSurface`s the tick fans frames out to — the driver surface
///   (sets `renderSize`) presents synchronously on the loop thread, mirrors on their own queues.
/// - The host alone decides when the loop runs (`setPacing`); the runtime never guesses liveness.
/// - All engine state lives in `EngineState` behind `engine` (a Mutex).
///
/// Rules:
/// - LOCK SCOPE: only CPU encode/state work under the lock — never `nextDrawable`, GPU waits, or
///   readbacks. Backpressure is `framesInFlight`, waited BEFORE the lock. Exception: graph swaps hold
///   the lock through teardown+setup so a frame never sees a half-swapped graph.
/// - COMMIT UNDER LOCK: a schedule buffer is committed in the critical section that encoded it, so
///   commit order == encode order and pool-texture hazard tracking keeps passes consistent.
///   Presentation is a separate blit buffer after `nextDrawable()` (a capture landing in between can
///   show a one-frame-newer endpoint — whole frames, monotonic).
/// - The engine lock never calls into the loop or a surface queue.
/// - COMPILES: `prepareLoad` runs on whatever thread the caller gives it (`prepareProject` gives it a
///   detached one). Only `commit` must run on the thread that owns the graph.
///
/// `@unchecked Sendable`: `assets`' pool is touched only under the lock; the toolchain is a value type
/// writing to per-node dirs; the rest is Mutex-guarded or immutable.
public final class SZRuntime: @unchecked Sendable {
    /// Everything a frame encode reads or a load/reload swaps — guarded by `engine`.
    private struct EngineState {
        var scheduler: SZScheduler?
        var loaders: [SZNodeID: SZLoader] = [:]
        /// The artifact each live loader came from. Content-addressed, so an unchanged source resolves
        /// to the same URL: that is how `reloadNode` spots a save that changed nothing.
        var loaderDylibs: [SZNodeID: URL] = [:]
        /// Live scalar input values per node/port (the v3 ABI channel): seeded from contract input
        /// defaults on load, overridable via `setInputValue` — read every frame, no recompile.
        var inputValues: [SZNodeID: [String: [Float]]] = [:]
        /// Live string/enum input values per node/port (the v4 ABI channel) — same lifecycle.
        var inputStrings: [SZNodeID: [String: String]] = [:]
        /// The virtual playback clock — owns `frameIndex` + `timeSeconds`, pausable/resettable from the
        /// HUD. Read and advanced only here under the engine lock (see SZTimeline).
        var timeline = SZTimeline()
        /// Scalar output values emitted during the most recently ENCODED frame, keyed
        /// `"<nodeID>:<port>"` (the v5 channel, surfaced by the scheduler). Host-side observation only
        /// (`readOutputFloats`) — never fed back into a frame. Paused frames don't encode, so this holds
        /// the pre-pause frame's values, matching the frozen viewport.
        var lastOutputValues: [String: [Float]] = [:]
        /// String output values from the same frame (the v8 channel) — same lifecycle as `lastOutputValues`.
        var lastOutputStrings: [String: String] = [:]
        /// Offscreen render size; the loop overrides it each tick with the driver surface's drawable size.
        var renderSize: (width: Int, height: Int)
        /// The zero-copy node-preview stream (watched set + IOSurface target pairs). A class ref so
        /// completion handlers can hold it; its vars follow this struct's lock, its atomics don't
        /// need it — see SZPreviewStream's header.
        let previews = SZPreviewStream()
        /// Attached viewport surfaces by layer identity; every tick presents to all of them.
        var surfaces: [ObjectIdentifier: SZRenderSurface] = [:]
        /// The surface that defines `renderSize` and presents synchronously (`setDriver`). Resolved
        /// per tick; a stale key just keeps the last size.
        var driverKey: ObjectIdentifier?
    }

    private let engine: Mutex<EngineState>
    private let assets: SZAssetManager
    private let toolchain = SZToolchain()
    private let workspace: URL
    /// Built node dylibs, keyed by node id then content key. Deliberately outside `workspace`, which is
    /// per-launch scratch: a cache in there would miss on every cold open.
    private let buildCache: URL
    /// The aspect-fit scaler behind size-mismatched presents (mirror viewports at their own size,
    /// resize races). Its own kernel — NOT the preview stream's — and its own mutex: scaleTransform/
    /// clipRect are mutated per encode, and mirrors present from independent display-link threads.
    /// The critical section covers only set-transform + encode (CPU-cheap, per the lock-scope rule).
    /// The box exists because MPS kernels aren't Sendable — safe here for the same narrow reason as
    /// the class's own `@unchecked Sendable`: the kernel is only ever touched inside `withLock`.
    private final class SZPresentScalerBox: @unchecked Sendable {
        let kernel: MPSImageBilinearScale
        init(device: any MTLDevice) { kernel = MPSImageBilinearScale(device: device) }
    }
    private let presentScaler = Mutex<SZPresentScalerBox?>(nil)

    /// The render clock; set at the end of init (its tick needs `self`).
    private var loop: SZRenderLoop!
    /// Loop frames allowed on the GPU at once. Waited before the engine lock, signalled on frame
    /// completion. `renderFrame()`/`captureFrame()` don't take part (they wait synchronously).
    private let framesInFlight = DispatchSemaphore(value: 2)

    /// The permission broker. The runtime owns permissions; capture lives in the node. The host
    /// pre-grants declared permissions (`requestDeclaredPermissions`) before loading.
    public let permissions = SZPermissions()

    /// Offscreen render size (the loop overrides it each tick with the driver surface's drawable size).
    /// Read-only publicly: the loop thread writes it per tick under the engine lock.
    public var renderSize: (width: Int, height: Int) {
        engine.withLock { $0.renderSize }
    }

    /// The owned Metal device — vended to the viewport's layer by the host.
    public var device: any MTLDevice { assets.device }

    /// `~/Library/Caches/SubjectiveZero/NodeBuilds` — machine-local, rebuildable, and safe to delete.
    public static var defaultBuildCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "SubjectiveZero").appending(path: "NodeBuilds")
    }

    /// Drop build dirs untouched for `days`. Node ids are per INSTANCE, so without this every deleted
    /// node leaves ~190 KB behind forever. Once per launch, off-main; failing is fine, it's a cache.
    public static func pruneBuildCache(_ root: URL? = nil, olderThan days: Int = 30) {
        let fm = FileManager.default
        let dir = root ?? defaultBuildCache
        let cutoff = Date(timeIntervalSinceNow: -Double(days) * 86_400)
        for entry in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let touched = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let touched, touched < cutoff { try? fm.removeItem(at: entry) }
        }
    }

    public init?(renderSize: (width: Int, height: Int) = (1280, 800), workspace: URL? = nil,
                 buildCache: URL? = nil) {
        guard let assets = SZAssetManager() else { return nil }
        self.assets = assets
        self.engine = Mutex(EngineState(renderSize: renderSize))
        self.workspace = workspace
            ?? FileManager.default.temporaryDirectory.appending(path: "SZRuntime-\(UUID().uuidString)")
        self.buildCache = buildCache ?? Self.defaultBuildCache
        loop = SZRenderLoop { [weak self] in self?.tick() }
    }

    deinit {
        loop.stop()
    }

    /// Compiled and dlopened but not installed: no `setup()` has run, so dropping one just frees its
    /// mappings. `commit` re-derives its own diff and only needs these loaders to COVER it.
    public struct SZPreparedLoad: Sendable {
        let graph: SZGraph
        let schedule: SZScheduler
        let loaders: [SZNodeID: SZLoader]
        let dylibs: [SZNodeID: URL]
    }

    /// Load a whole project from its `.subz` directory: read the model, compile each node's `Node.swift`,
    /// and build the schedule. Replaces any live graph. The host should `requestDeclaredPermissions`
    /// first so a node that needs e.g. the camera is already authorized when its `setup` runs.
    public func loadProject(at url: URL) throws {
        let project = try SZProjectIO.load(from: url)
        // Render only IMPLEMENTED nodes: a prompt node has no Node.swift to compile. This is what lets a
        // graph with un-implemented (dirty) prompt nodes load — the agent loop starts from exactly that,
        // and the node becomes renderable once its coding agent's source is promoted (kind → generated).
        // …and resolve every file port against the bundle on the way in: the model holds the PORTABLE
        // form (`media/<uuid>/<name>`), the runtime is the one place that needs a machine path,
        // because it is the one place that hands a string to a node that will open it.
        let graph = Self.renderableSubgraph(project.graph).resolvingFilePaths(in: url)
        try loadGraph(graph) { SZProjectIO.nodeSourceURL(projectURL: url, nodeID: $0) }
    }

    /// Compile + dlopen a project's new nodes off the caller's thread, touching nothing live: the cold
    /// open, where every node is new. By value so the caller's repaired graph is the one prepared.
    /// Install with `commit`, or drop it to abandon the load.
    public func prepareProject(_ project: SZProject, at url: URL) async throws -> SZPreparedLoad {
        let graph = Self.renderableSubgraph(project.graph).resolvingFilePaths(in: url)   // see loadProject
        return try await Task.detached(priority: .userInitiated) { [self] in
            try prepareLoad(graph, sourceURL: { SZProjectIO.nodeSourceURL(projectURL: url, nodeID: $0) },
                            offMain: true)
        }.value
    }

    /// The subgraph the runtime can actually render: `generated` nodes, the connections among them, and
    /// the render endpoint only if its node is generated.
    static func renderableSubgraph(_ graph: SZGraph) -> SZGraph {
        let generated = Set(graph.nodes.filter { $0.kind == .generated }.map(\.id))
        return SZGraph(
            nodes: graph.nodes.filter { generated.contains($0.id) },
            connections: graph.connections.filter { generated.contains($0.from.node) && generated.contains($0.to.node) },
            renderEndpoint: graph.renderEndpoint.flatMap { generated.contains($0.node) ? $0 : nil })
    }

    /// Compile-check one staged `Node.swift` WITHOUT loading or swapping it — the validation behind
    /// `agent_compile_node`. The host promotes (copies to the live node folder + reloads) only on `.ok`,
    /// so a broken staged source never clobbers the live one. `.failed` carries the swiftc diagnostics.
    public func compileNodeSource(at source: URL) -> SZBuildResult {
        // The measured thing measures itself: a `compile.check` fence with the outcome as detail,
        // attributed via whatever trace context the caller bound (the MCP bridge's tool span) —
        // off-turn callers have none, and the fence drops.
        let fence = SZTrace.begin(SZTurnStage.compileCheck)
        do {
            _ = try toolchain.compile(
                nodeSource: source,
                into: workspace.appending(path: "staging-check/\(UUID().uuidString)"))
            fence.end(detail: "ok")
            return .ok
        } catch {
            fence.end(detail: "failed")
            return .failed("\(error)")
        }
    }

    /// True if `id` has a live, loaded module — a successfully-compiled `generated` node currently in the
    /// rendered graph. The host uses this to choose the incremental `reloadNode` fast path vs a full
    /// `loadProject` (a node not yet loaded — e.g. a graph stuck failing wholesale — needs the full path).
    public func isNodeLoaded(_ id: SZNodeID) -> Bool {
        engine.withLock { $0.loaders[id] != nil }
    }

    /// Test hook: object identity of each loaded node's live module. An incremental reload that reuses a
    /// node's loader keeps its identity; a recompile installs a fresh `SZLoader` (new identity). Lets tests
    /// assert a topology-only edit did ZERO recompiles. Internal — visible only to `@testable` tests.
    func loaderIdentities() -> [SZNodeID: ObjectIdentifier] {
        engine.withLock { $0.loaders.mapValues(ObjectIdentifier.init) }
    }

    /// Recompile + hot-swap a SINGLE node's module in place — the fast path for hand-editing one node's
    /// `Node.swift`. Leaves every other loaded node, the schedule, the live input values (slider
    /// overrides), and the render endpoint untouched, so only the edited node rebuilds (a much shorter
    /// compile than the whole-graph `loadProject`). Valid only for a pure source edit: a node's
    /// contract/wiring lives in the separate `node-contract.json`, so the topology + bindings are
    /// unchanged by a `Node.swift` save. Throws — leaving the OLD module live and rendering, since
    /// `SZLoader.load` opens the new module BEFORE tearing the old one down — if the new source fails to
    /// compile or load; `"\(error)"` carries the swiftc diagnostics. No-op if `id` isn't loaded.
    public func reloadNode(id: SZNodeID, source: URL) throws {
        guard let loader = engine.withLock({ $0.loaders[id] }) else { return }
        let dylib = try toolchain.compile(
            nodeSource: source, into: buildCache.appending(path: id.uuidString))
        // A save that changed nothing resolves to the artifact already live. Reloading it would map a
        // second copy of the same module (the collision the per-build module name prevents) and
        // re-acquire exclusive devices, restarting a camera for nothing.
        guard engine.withLock({ $0.loaderDylibs[id] }) != dylib else { return }
        // The in-place module swap must not interleave a live-viewport frame encode.
        try engine.withLock { state in
            var ctx = SZRuntimeContextRaw()
            ctx.device = Unmanaged.passUnretained(assets.device as AnyObject).toOpaque()
            let paused = state.timeline.paused
            defer { if paused { loader.setPaused(true) } }   // reloaded while paused ⇒ stays paused
            try withUnsafeMutablePointer(to: &ctx) { pointer in
                // SZLoader.load = open(new) → unloadLive(old: teardown releases an exclusive device like the
                // camera's AVCaptureSession + dlclose) → activate(new: setup re-acquires). The same-node device
                // handoff is correct, and the swap is synchronous (no await between teardown and setup), so no
                // frame interleaves it. We deliberately don't `assets.reset()` (that pool is per-frame scratch —
                // resetting would disturb the other nodes) nor re-seed input values (a slider override survives).
                try loader.load(
                    dylib: dylib,
                    runtimeLoadsDir: workspace.appending(path: "runtime-loads/\(id.uuidString)"),
                    setupContext: UnsafeMutableRawPointer(pointer))
                state.loaderDylibs[id] = dylib
            }
        }
    }

    /// Request every entitlement declared by the project's node contracts (camera, …), prompting once
    /// per still-undetermined one. The host awaits this before `loadProject`. No-op for already-granted
    /// entitlements; never called from headless tests (the node self-guards on authorization status).
    public func requestDeclaredPermissions(at url: URL) async throws {
        await requestDeclaredPermissions(for: try SZProjectIO.load(from: url))
    }

    /// Request every entitlement declared by `project`'s node contracts, prompting once per
    /// still-undetermined one. The in-memory counterpart of `requestDeclaredPermissions(at:)`: a node's
    /// permission is only known once the Director declares its contract — AFTER the initial load — so the
    /// host calls this during a run (before the coding fleet dispatches) to grant a newly-introduced
    /// entitlement before the node's `setup()` runs on the promote-reload. No-op for already-granted ones.
    public func requestDeclaredPermissions(for project: SZProject) async {
        let declared = Set(project.graph.nodes.flatMap { $0.contract?.requiredPermissions ?? [] })
        for entitlement in declared where !permissions.isAuthorized(entitlement) {
            _ = await permissions.requestAccess(entitlement)
        }
    }

    /// Install `graph` as the live graph and rebuild the schedule, compiling only what actually changed.
    /// `sourceURL` resolves each node id to its `Node.swift`.
    ///
    /// Incremental by node id: a node already loaded (`retained`) is reused in place — no recompile, no
    /// teardown, no re-`setup()` — since a pure topology edit (connect/disconnect/reconnect/endpoint)
    /// touches no `Node.swift`. Only `added` ids (new to the graph — the initial load, a promote, or a
    /// split/merge piece) compile + open + activate; only `removed` ids tear down. A wiring change has no
    /// `added`/`removed`, so it does ZERO compiles — it just reschedules and rebinds.
    ///
    /// Assumes a retained node's source is unchanged (source-only edits go through `reloadNode`; no
    /// `loadProject` caller mutates a retained node's `Node.swift` — promote/split/merge introduce *new*
    /// ids). If that ever changes, add a `forceRecompile: Set<SZNodeID>` param and fold it into `added`.
    ///
    /// Ordering matters: compile + `open` (dlopen, NO `setup()`) the added nodes first — a throw here
    /// leaves the old graph live (the atomic-failure property) — THEN tear the removed nodes down, THEN
    /// `activate` (run `setup()`) the added ones. A node that grabs an exclusive device in `setup()` (the
    /// camera's `AVCaptureSession`) must not start until the previous holder is torn down, or the two
    /// sessions contend and the new feed freezes (e.g. after a camera merge). Retained nodes are never
    /// torn down, so an unchanged camera node keeps running across the edit.
    private func loadGraph(_ graph: SZGraph, sourceURL: (SZNodeID) -> URL) throws {
        try commit(prepareLoad(graph, sourceURL: sourceURL, offMain: false))
    }

    /// Phase 1: schedule, diff, compile + `open` (no `setup()`) the added nodes. The slow half, and the
    /// only half touching the toolchain. `offMain` means the caller is a detached thread, so compiles may
    /// run at once and park on the swiftc gate: neither is allowed on the main thread.
    private func prepareLoad(_ graph: SZGraph, sourceURL: (SZNodeID) -> URL,
                             offMain: Bool) throws -> SZPreparedLoad {
        let schedule = try SZScheduler(graph: graph)

        // Diff old vs new node sets. `added` compile; `removed` tear down; the rest are reused untouched.
        let oldIDs = engine.withLock { Set($0.loaders.keys) }
        // Order is irrelevant here: each node builds into its own dir and nothing is activated yet.
        let added = schedule.order.filter { !oldIDs.contains($0) }

        // Throws leave the live graph untouched. Empty for a pure wiring edit ⇒ zero compiles.
        let clock = ContinuousClock()
        let started = clock.now
        let built = try offMain ? buildConcurrently(added, sourceURL: sourceURL)
                                : added.map { ($0, try buildOne($0, source: sourceURL($0), gated: false)) }
        var newLoaders: [SZNodeID: SZLoader] = [:]
        var dylibs: [SZNodeID: URL] = [:]
        for (nodeID, dylib) in built {
            let loader = SZLoader()
            try loader.open(
                dylib: dylib,
                runtimeLoadsDir: workspace.appending(path: "runtime-loads/\(nodeID.uuidString)"))
            newLoaders[nodeID] = loader
            dylibs[nodeID] = dylib
        }
        if SZTrace.isEnabled, !newLoaders.isEmpty {
            print(String(format: "[SZRuntime] built %d node(s) in %.2fs",
                         newLoaders.count, started.duration(to: clock.now).szSeconds))
        }
        return SZPreparedLoad(graph: graph, schedule: schedule, loaders: newLoaders, dylibs: dylibs)
    }

    private func buildOne(_ id: SZNodeID, source: URL, gated: Bool) throws -> URL {
        let dir = buildCache.appending(path: id.uuidString)
        return gated ? try toolchain.gated { try toolchain.compile(nodeSource: source, into: dir) }.get()
                     : try toolchain.compile(nodeSource: source, into: dir)
    }

    /// Build the added nodes at once, so a project costs about its slowest node rather than their sum.
    /// GCD, not a task group: the swiftc gate and `waitUntilExit` block a real thread, and blocking
    /// cooperative-pool threads starves the concurrency runtime.
    private func buildConcurrently(_ ids: [SZNodeID],
                                   sourceURL: (SZNodeID) -> URL) throws -> [(SZNodeID, URL)] {
        guard ids.count > 1 else {
            return try ids.map { ($0, try buildOne($0, source: sourceURL($0), gated: true)) }
        }
        let sources = ids.map { sourceURL($0) }
        let results = Mutex<[SZNodeID: Result<URL, Error>]>([:])
        DispatchQueue.concurrentPerform(iterations: ids.count) { i in
            let built = Result { try buildOne(ids[i], source: sources[i], gated: true) }
            results.withLock { $0[ids[i]] = built }
        }
        return try results.withLock { $0 }.sorted { a, b in
            ids.firstIndex(of: a.key)! < ids.firstIndex(of: b.key)!
        }.map { ($0.key, try $0.value.get()) }
    }

    /// Phases 2+3: swap `prepared` in, synchronously and atomically.
    ///
    /// The diff is re-derived here rather than trusted from prepare, because seconds of compiling sit
    /// between the two and a hot reload in that window moves the live node set. A surplus prepared
    /// loader is dropped unused; a shortfall refuses before anything is mutated.
    public func commit(_ prepared: SZPreparedLoad) throws {
        let graph = prepared.graph
        let schedule = prepared.schedule
        let newLoaders = prepared.loaders
        let newIDs = Set(graph.nodes.map(\.id))
        let oldIDs = engine.withLock { Set($0.loaders.keys) }
        let added = newIDs.subtracting(oldIDs)
        guard added.isSubset(of: newLoaders.keys) else { throw SZLoadError.staleLoad }
        let removed = oldIDs.subtracting(newIDs)
        let retained = newIDs.intersection(oldIDs)

        // Phases 2+3 hold the engine lock: a live-viewport frame must never interleave the teardown →
        // activate window (it would encode against unloaded modules), and the state swap is atomic
        // with respect to the next frame. (Commit-under-lock means everything previously encoded is
        // already committed; executing recorded GPU work during/after teardown is safe — buffers
        // retain their resources and no dylib CPU code runs on the GPU path.)
        engine.withLock { state in
            // Phase 2 — tear down ONLY the removed nodes (releasing their exclusive devices). Retained
            // loaders stay live and untouched. Reset the per-frame pool only on a full swap (nothing
            // retained — a cold load or project switch); on an incremental edit it's shared scratch the
            // retained nodes are still using, so resetting would disturb them (matches `reloadNode`).
            for id in removed { state.loaders[id]?.unload() }
            if retained.isEmpty { assets.reset() }

            // Phase 3 — activate (run setup()) only the added nodes, now that the removed holders are gone.
            var ctx = SZRuntimeContextRaw()
            ctx.device = Unmanaged.passUnretained(assets.device as AnyObject).toOpaque()
            withUnsafeMutablePointer(to: &ctx) { pointer in
                let raw = UnsafeMutableRawPointer(pointer)
                for nodeID in schedule.order where added.contains(nodeID) {
                    newLoaders[nodeID]?.activate(setupContext: raw)
                    // A node set up while the clock is stopped must not come up running — otherwise a
                    // clip added to a paused graph plays audio over a frozen picture. Asserting it here
                    // rather than asking nodes to remember it is what makes that structural.
                    if state.timeline.paused { newLoaders[nodeID]?.setPaused(true) }
                }
            }

            // Commit: drop removed loaders, splice in the added ones, leave retained in place.
            for id in removed { state.loaders[id] = nil; state.loaderDylibs[id] = nil }
            for id in added {                                        // `added` only: a surplus is dropped
                state.loaders[id] = newLoaders[id]
                state.loaderDylibs[id] = prepared.dylibs[id]
            }
            state.scheduler = schedule
            // Inputs: reconcile each live node's overrides against its (possibly edited) contract, so ANY
            // contract change — add / remove / rename / retype a port — self-applies with no cold reopen,
            // and the result is a pure function of (contract, prior overrides), identical whether the node
            // was just added or retained. Connected data-edge values never live here (the scheduler merges
            // those per frame), so this cannot disturb wiring. Keep an override iff the port is still
            // declared on its matching value channel AND the override still fits the port's arity (so a
            // retype that changed the element count — float→float3, float3→float — falls back to the new
            // default rather than feeding the node a wrong-length value); otherwise seed the contract
            // default; drop entries for ports the contract no longer declares (a removal, or the stale half
            // of a rename/retype). A node whose contract isn't known yet (nil) has no boundary to reconcile
            // against, so leave its stored values untouched rather than wiping them.
            for id in removed { state.inputValues[id] = nil; state.inputStrings[id] = nil }
            for node in graph.nodes {
                guard let inputs = node.contract?.inputs else { continue }
                var floats: [String: [Float]] = [:]
                var strings: [String: String] = [:]
                for port in inputs {
                    switch Self.valueChannel(port.type) {
                    case .float:  if let v = Self.reconciledFloats(kept: state.inputValues[node.id]?[port.name], def: port.def?.floats) { floats[port.name] = v }
                    case .string: if let s = state.inputStrings[node.id]?[port.name] ?? port.def?.string { strings[port.name] = s }
                    case .none:   break   // texture / floatArray / event — no seedable by-value state
                    }
                }
                state.inputValues[node.id] = floats
                state.inputStrings[node.id] = strings
            }
        }
    }

    /// Which live-value channel a port's by-value state lives in: numeric kinds + `bool` ride the float
    /// channel (`inputValues`), `enum`/`string` ride the string channel (`inputStrings`), and
    /// texture/floatArray/event carry no seedable by-value state. Mirrors the split already implicit in
    /// `SZPortValue.floats` / `.string`; used by `loadGraph` to reconcile overrides against a contract.
    private enum SZValueChannel { case float, string, none }
    private static func valueChannel(_ type: SZPortType) -> SZValueChannel {
        switch type {
        case .float, .float2, .float3, .float4, .float3x3, .float4x4, .colorRGB, .colorRGBA, .bool: .float
        case .enumeration, .string: .string
        case .texture, .floatArray, .event: .none
        }
    }

    /// Reconcile one float-channel input against its contract default: keep a live override only while it
    /// still fits the port's arity (the default's element count), else fall back to the default. This is
    /// what makes a same-type slider override survive a reload while an override left over from a
    /// different-arity type (float↔float3, a color's 3/4 vs a scalar's 1) is dropped so the node never
    /// reads a wrong-length value. No default to measure against ⇒ keep whatever's there.
    private static func reconciledFloats(kept: [Float]?, def: [Float]?) -> [Float]? {
        guard let kept else { return def }
        guard let def else { return kept }
        return kept.count == def.count ? kept : def
    }

    /// Override a node's scalar input value live (the host op behind `ui_set_input_default`). Read each
    /// frame by the scheduler → the change shows next frame, no recompile.
    public func setInputValue(node: SZNodeID, port: String, floats: [Float]) {
        engine.withLock { $0.inputValues[node, default: [:]][port] = floats }
    }

    /// Override a node's string/enum input value live (the v4 channel behind `ui_set_input_default`). Read
    /// each frame by the scheduler → the change shows next frame, no recompile.
    public func setInputString(node: SZNodeID, port: String, string: String) {
        engine.withLock { $0.inputStrings[node, default: [:]][port] = string }
    }

    /// Drop a node's live override for one input, so the node reads whatever its contract seeds instead. The
    /// counterpart of the two setters above, for a port edit that cleared a value: `loadProject`'s reconcile
    /// keeps an override on purpose, so nothing else would let go of it before a relaunch. A port rides one
    /// channel, and clearing the other is a no-op.
    public func clearInput(node: SZNodeID, port: String) {
        engine.withLock {
            $0.inputValues[node]?[port] = nil
            $0.inputStrings[node]?[port] = nil
        }
    }

    /// Ask a node, live, for a port's dynamic enum options (the v4 `SZNodeEnumerateOptions` channel) — the
    /// camera list etc. Empty for a static/non-enum port. The host throttles + falls back to the contract's
    /// static `options`, so this is called on demand (≈ when the dropdown opens), not per frame.
    ///
    /// The lock covers only the loader lookup: the enumeration itself can be SLOW (the camera node runs
    /// an AVCaptureDevice discovery, 100s of ms) and must not stall the render thread. That means
    /// `enumerateOptions` may run CONCURRENTLY with the node's `update` on the render thread — part of
    /// the node ABI contract (see the authoring docs). The loader can't be torn down under us:
    /// unload/reload happen on this same (main) thread.
    public func enumerateOptions(node: SZNodeID, port: String) -> [SZEnumOption] {
        let loader = engine.withLock { $0.loaders[node] }
        return loader?.enumerateOptions(port: port) ?? []
    }

    /// The scalar value(s) `node` emitted on `port` during the most recently encoded frame — the
    /// host-side read of the v5 output channel (nil if the node emitted nothing there, or no frame has
    /// encoded yet). Observation, not control flow: values are a byproduct of the normal frame encode,
    /// so reading is lock-cheap and never renders. While paused it reports the held frame's values,
    /// matching the frozen viewport. Feeds card telemetry (meters, scopes).
    public func readOutputFloats(node: SZNodeID, port: String) -> [Float]? {
        engine.withLock { $0.lastOutputValues[SZScheduler.textureID(node: node, port: port)] }
    }

    /// The string `node` emitted on a `string`/`enum` output `port` during the most recently encoded
    /// frame — the host-side read of the v8 output channel; same semantics as `readOutputFloats`.
    /// Feeds binding learn (a controller node's `lastKey`) and card telemetry.
    public func readOutputString(node: SZNodeID, port: String) -> String? {
        engine.withLock { $0.lastOutputStrings[SZScheduler.textureID(node: node, port: port)] }
    }

    /// Re-point the live render endpoint without a reload (the host op behind `ui_toggle_display`). The
    /// scheduler reads this each frame → the viewport switches next frame. `nil` clears it (black
    /// viewport). The host should only point it at a currently-rendered (generated) node's texture output.
    public func setRenderEndpoint(_ ref: SZPortRef?) {
        engine.withLock { $0.scheduler?.renderEndpoint = ref }
    }

    /// Pause/resume the playback clock (the HUD Pause/Play toggle). While paused the render loop stops
    /// advancing the schedule and just re-presents the current endpoint (see `tick` / `captureFrame`),
    /// so the whole graph holds still; on resume the clock continues from where it stopped (the paused
    /// span is excluded, so no time jump).
    public func setPaused(_ paused: Bool) {
        engine.withLock { state in
            state.timeline.setPaused(paused, now: CACurrentMediaTime())
            // Stopping the SCHEDULE only freezes what a node computes inside `update()`. Anything running
            // on its own — an AVPlayer's audio, a capture session — never hears about it, and can't ask:
            // pause means no more frames. So tell it. Inside the lock, serialized against frames like any
            // other graph mutation (the ABI tells nodes not to block here).
            for loader in state.loaders.values { loader.setPaused(paused) }
        }
    }

    /// Whether the render clock is paused. The runtime owns this — the host mirrors it for the HUD and
    /// must read it back rather than assume, or the mirror drifts from the nodes' actual state.
    public var isPaused: Bool { engine.withLock { $0.timeline.paused } }


    /// Rewind the playback clock to the start (the HUD Reset Time button): the next frame restarts at
    /// `timeSeconds == 0`, `frameIndex == 0`. Preserves the paused/playing state.
    public func resetTimeline() {
        let wasPaused = engine.withLock { state -> Bool in
            state.timeline.reset()
            return state.timeline.paused
        }
        // While paused the live loop re-presents the held frame and never re-encodes — so render one
        // frame now (it advances the reset-pending timeline to the fresh t=0 state, still frozen) to
        // refresh the held endpoint. Without this, a rewind-while-paused wouldn't be visible until Play.
        if wasPaused { renderFrame() }
    }

    /// Render one frame through the schedule into the asset pool (synchronously — commits under the
    /// lock, waits OUTSIDE it, so the render-endpoint texture is ready for readback when this returns).
    public func renderFrame() {
        let buffer = engine.withLock { state in
            encodeAndCommitFrame(&state, width: state.renderSize.width, height: state.renderSize.height).buffer
        }
        buffer?.waitUntilCompleted()
    }

    /// Encode one schedule pass and COMMIT it (commit-under-lock). Caller holds the engine lock.
    /// `beforeCommit` adds work to the same buffer pre-commit (capture blit, completion handlers);
    /// its `endpoint` is nil when nothing is routed to the display.
    private func encodeAndCommitFrame(
        _ state: inout EngineState, width: Int, height: Int,
        beforeCommit: (any MTLCommandBuffer, (any MTLTexture)?) -> Void = { _, _ in }
    ) -> (buffer: (any MTLCommandBuffer)?, endpoint: (any MTLTexture)?) {
        guard let scheduler = state.scheduler else { return (nil, nil) }
        guard let commandBuffer = assets.commandQueue.makeCommandBuffer() else { return (nil, nil) }
        let timing = state.timeline.nextFrame(now: CACurrentMediaTime())
        let (endpoint, outputValues, outputStrings) = scheduler.encodeFrame(
            device: assets.device, commandBuffer: commandBuffer, assets: assets, loaders: state.loaders,
            inputValues: state.inputValues, inputStrings: state.inputStrings, frameIndex: timing.frameIndex,
            time: timing.timeSeconds,
            width: width, height: height)
        state.lastOutputValues = outputValues
        state.lastOutputStrings = outputStrings
        beforeCommit(commandBuffer, endpoint)
        // The live thumb pass rides THIS buffer (throttled inside) — after the schedule's writes,
        // before the commit, so hazard tracking orders the downscales behind the frame's renders.
        encodePreviewPass(state.previews, on: commandBuffer, now: CACurrentMediaTime())
        commandBuffer.commit()
        return (commandBuffer, endpoint)
    }

    /// Encode the watched-thumb downscales onto the frame's command buffer — the preview stream's
    /// live half. Caller is inside the engine lock, pre-commit. Throttled to `minInterval`
    /// (attempt-based), skipped while the previous pass's completion is pending, free when nothing
    /// is watched. Paused frames never reach here (the paused path doesn't encode), so a frozen
    /// timeline costs previews exactly zero.
    private func encodePreviewPass(_ stream: SZPreviewStream, on commandBuffer: any MTLCommandBuffer,
                                   now: TimeInterval) {
        guard !stream.watched.isEmpty,
              now - stream.lastPass >= stream.minInterval,
              !stream.passInFlight.load(ordering: .acquiring) else { return }
        // Burn the throttle window only when something actually encoded: a graph whose watched
        // pools were never written (nothing rendered yet) must produce a thumb on its FIRST frame,
        // not one interval later.
        if encodeThumbScales(stream, on: commandBuffer) { stream.lastPass = now }
    }

    /// The shared body of the live pass and the watch-change one-shot fill: encode a downscale for
    /// every watched port whose pool texture exists into its pair's BACK buffer, then register the
    /// ONE completion handler that flips fronts, clears the in-flight flag, and publishes. Returns
    /// whether anything was encoded (an unwritten pool encodes nothing — callers must not burn the
    /// throttle window on it). The handler runs on Metal's completion thread with no lock held and
    /// touches only atomics + its captured payload — never the runtime (class-header lock rules).
    @discardableResult
    private func encodeThumbScales(_ stream: SZPreviewStream, on commandBuffer: any MTLCommandBuffer) -> Bool {
        let scaler = stream.scaler ?? MPSImageBilinearScale(device: assets.device)
        stream.scaler = scaler
        var payload: [(frame: SZNodePreviewSurface, pair: SZPreviewTargetPair, back: Int)] = []
        for request in stream.watched {
            let key = SZScheduler.textureID(node: request.node, port: request.port)
            guard let source = assets.existing(id: key), source.pixelFormat == .bgra8Unorm else { continue }
            let (w, h) = SZImageBytes.fittedSize(width: source.width, height: source.height,
                                                 maxDimension: stream.maxDimension)
            let pair: SZPreviewTargetPair
            if let existing = stream.pairs[key], existing.width == w, existing.height == h {
                pair = existing
            } else {
                // First sight of this port, or the source/maxDimension changed size: fresh pair.
                // An in-flight pass keeps the OLD pair alive via its captured payload.
                guard let fresh = SZPreviewTargetPair(device: assets.device, width: w, height: h) else { continue }
                stream.pairs[key] = fresh
                pair = fresh
            }
            let back = 1 - pair.front.load(ordering: .relaxed)
            let target = pair.texture(at: back)
            var transform = MPSScaleTransform(scaleX: Double(target.width) / Double(source.width),
                                              scaleY: Double(target.height) / Double(source.height),
                                              translateX: 0, translateY: 0)
            withUnsafePointer(to: &transform) { pointer in
                scaler.scaleTransform = pointer
                scaler.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: target)
            }
            payload.append((SZNodePreviewSurface(node: request.node, port: request.port,
                                                 surface: pair.surface(at: back)), pair, back))
        }
        guard !payload.isEmpty else { return false }
        stream.passInFlight.store(true, ordering: .releasing)
        let callback = stream.onFrames
        commandBuffer.addCompletedHandler { _ in
            // Metal's completion thread. Touches ONLY the stream's atomics and the captured
            // payload — never its lock-guarded vars. A late pass for a just-de-watched port flips
            // pair objects the stream may no longer reference — harmless: the host re-validates
            // every publish against the live graph before writing a box.
            for item in payload { item.pair.front.store(item.back, ordering: .releasing) }
            stream.passInFlight.store(false, ordering: .releasing)
            callback?(payload.map(\.frame))
        }
        return true
    }

    /// Replace the watched preview set — pushed by the host on WATCH-LIST changes only (never per
    /// frame). Prunes target pairs for de-watched ports. When the timeline is paused, or a newly
    /// watched port has no target yet (scrolled into view; viewport closed), a one-shot thumb-only
    /// buffer fills from the HELD pool textures immediately — a fresh preview must show the held
    /// frame, not "no signal" until the next live frame.
    public func setWatchedPreviews(_ requests: [(node: SZNodeID, port: String)], maxDimension: Int) {
        engine.withLock { state in
            let stream = state.previews
            stream.watched = requests
            if stream.maxDimension != maxDimension {
                stream.maxDimension = maxDimension
                stream.pairs.removeAll()   // every target is the wrong size now
            }
            let keys = Set(requests.map { SZScheduler.textureID(node: $0.node, port: $0.port) })
            stream.pairs = stream.pairs.filter { keys.contains($0.key) }
            let hasNewPort = requests.contains {
                stream.pairs[SZScheduler.textureID(node: $0.node, port: $0.port)] == nil
            }
            guard !requests.isEmpty, state.timeline.paused || hasNewPort,
                  !stream.passInFlight.load(ordering: .acquiring),
                  let commandBuffer = assets.commandQueue.makeCommandBuffer() else { return }
            if encodeThumbScales(stream, on: commandBuffer) { stream.lastPass = CACurrentMediaTime() }
            commandBuffer.commit()   // commit-under-lock, same as every schedule buffer
        }
    }

    /// Install the publish sink for preview frames. CONTRACT: the callback fires on Metal's
    /// completion thread after each thumb pass completes; it must be fast and non-blocking (hop to
    /// the main actor immediately) and must not synchronously re-enter runtime APIs.
    public func setPreviewFrameCallback(_ callback: (@Sendable ([SZNodePreviewSurface]) -> Void)?) {
        engine.withLock { $0.previews.onFrames = callback }
    }

    /// Test hook: drop the pass throttle so back-to-back `renderFrame()` calls each publish.
    func setPreviewThrottleForTests(_ interval: TimeInterval) {
        engine.withLock { $0.previews.minInterval = interval }
    }

    /// Test hook: the surface object held for `layer` (nil once detached).
    func attachedSurfaceForTests(_ layer: CAMetalLayer) -> SZRenderSurface? {
        engine.withLock { $0.surfaces[ObjectIdentifier(layer)] }
    }

    // MARK: - The render loop: surfaces, driver, pacing, tick

    /// Attach a viewport surface: every tick presents into `layer` from now on. Attaching does not
    /// start the loop — the host paces it (`setPacing`).
    public func attach(_ layer: CAMetalLayer) {
        engine.withLock { $0.surfaces[ObjectIdentifier(layer)] = SZRenderSurface(layer: layer) }
    }

    /// Detach a surface. Never waits: an in-flight mirror present keeps the layer alive until done.
    public func detach(_ layer: CAMetalLayer) {
        engine.withLock { $0.surfaces[ObjectIdentifier(layer)] = nil }
    }

    /// The DRIVER surface: its `drawableSize` becomes `renderSize` and it presents synchronously.
    /// The host's drivership ladder decides this on visibility/size edges. nil keeps the last size.
    public func setDriver(_ layer: CAMetalLayer?) {
        engine.withLock { $0.driverKey = layer.map(ObjectIdentifier.init) }
    }

    /// Pace the loop with the link `make` builds (an NSView/NSWindow/NSScreen display-link factory —
    /// main-thread AppKit the runtime doesn't import), or idle on nil. The loop installs it on its
    /// thread and drops the previous one. This is the host's ONE "run the renderer" decision.
    @MainActor
    public func setPacing(_ make: (AnyObject, Selector) -> CADisplayLink?) {
        loop.setPacing(make(loop, #selector(SZRenderLoop.fire(_:))))
    }

    /// One beat: encode+commit under the lock, then fan out with no lock held (driver synchronously,
    /// mirrors on their queues). Paused → no encode; sinks re-present the CURRENT endpoint's held
    /// pool texture every beat (non-allocating read: asking the pool at the driver's size would
    /// destroy the held frame on a paused resize), so the whole graph freezes at the runtime level
    /// and the freeze survives resize/occlusion. Called directly by tests.
    func tick() {
        // Backpressure outside the lock: a GPU-bound graph paces the loop at GPU rate here.
        guard framesInFlight.wait(timeout: .now() + 1) == .success else { return }
        let (encoded, endpoint, driver, mirrors) = engine.withLock {
            state -> (Bool, (any MTLTexture)?, SZRenderSurface?, [SZRenderSurface]) in
            let driver = state.driverKey.flatMap { state.surfaces[$0] }
            if let driver {
                let size = driver.layer.drawableSize   // plain CA read; the view is its single writer (main)
                if size.width > 0, size.height > 0 { state.renderSize = (Int(size.width), Int(size.height)) }
            }
            let mirrors = state.surfaces.values.filter { $0 !== driver }
            if state.timeline.paused {
                return (false, state.scheduler?.heldEndpointTexture(assets: assets), driver, mirrors)
            }
            let semaphore = framesInFlight
            let frame = encodeAndCommitFrame(&state, width: state.renderSize.width,
                                             height: state.renderSize.height) { commandBuffer, _ in
                commandBuffer.addCompletedHandler { _ in semaphore.signal() }   // pre-commit
            }
            return (frame.buffer != nil, frame.endpoint, driver, mirrors)
        }
        if !encoded { framesInFlight.signal() }   // nothing on the GPU this beat
        // `endpoint` is retained by this frame, so a concurrent pool reset can't free it under a blit.
        driver?.presentNow(endpoint, via: self)
        for mirror in mirrors { mirror.presentLater(endpoint, via: self) }
    }

    /// The presentation tail (blocking — no lock held): acquire a drawable and put `endpoint` on it.
    /// Equal sizes → blit; mismatched → clear + aspect-fit; nil endpoint → clear. Returns whether a
    /// buffer was committed; `onCompleted` fires from its completion handler.
    func presentEndpoint(_ endpoint: (any MTLTexture)?, into layer: CAMetalLayer,
                         onCompleted: (@Sendable () -> Void)?) -> Bool {
        guard let drawable = layer.nextDrawable(),
              let presentBuffer = assets.commandQueue.makeCommandBuffer() else { return false }
        let target = drawable.texture
        if let endpoint, endpoint.width == target.width, endpoint.height == target.height {
            Self.encodeCopy(endpoint, into: target, width: endpoint.width, height: endpoint.height,
                            on: presentBuffer)
        } else if let endpoint {
            Self.encodeClear(target, on: presentBuffer)
            encodeAspectFitScale(endpoint, into: target, on: presentBuffer)
        } else {
            Self.encodeClear(target, on: presentBuffer)
        }
        if let onCompleted { presentBuffer.addCompletedHandler { _ in onCompleted() } }
        presentBuffer.present(drawable)
        presentBuffer.commit()
        return true
    }

    /// Clear a texture to opaque black (letterbox bars, endpoint-less viewports).
    private static func encodeClear(_ texture: any MTLTexture, on commandBuffer: any MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }

    /// Encode the aspect-fit bilinear scale of `source` into `destination`'s letterboxed center.
    /// The clipRect is essential: without it MPS fills the WHOLE destination with edge-clamped
    /// samples, smearing the image across the letterbox bars.
    private func encodeAspectFitScale(_ source: any MTLTexture, into destination: any MTLTexture,
                                      on commandBuffer: any MTLCommandBuffer) {
        let fit = Self.aspectFit(source: (source.width, source.height),
                                 dest: (destination.width, destination.height))
        let fittedWidth = min(Int((Double(source.width) * fit.scale).rounded()), destination.width)
        let fittedHeight = min(Int((Double(source.height) * fit.scale).rounded()), destination.height)
        guard fittedWidth > 0, fittedHeight > 0 else { return }
        presentScaler.withLock { slot in
            let box = slot ?? SZPresentScalerBox(device: assets.device)
            slot = box
            // Placement comes from the clipRect ALONE, translation stays zero: MPS composes the
            // scale transform's translation RELATIVE to the clipRect origin (verified empirically
            // — a centering translate + a matching clip origin landed the image at 2× the offset,
            // half in, half clipped: the "black mirror tiles" bug). Zero translate puts the scaled
            // image exactly in the clipped letterbox region; everything outside stays the cleared
            // black bars.
            var transform = MPSScaleTransform(scaleX: fit.scale, scaleY: fit.scale,
                                              translateX: 0, translateY: 0)
            withUnsafePointer(to: &transform) { pointer in
                box.kernel.scaleTransform = pointer
                box.kernel.clipRect = MTLRegion(
                    origin: MTLOrigin(x: min(Int(fit.translateX.rounded()), destination.width - fittedWidth),
                                      y: min(Int(fit.translateY.rounded()), destination.height - fittedHeight), z: 0),
                    size: MTLSize(width: fittedWidth, height: fittedHeight, depth: 1))
                box.kernel.encode(commandBuffer: commandBuffer, sourceTexture: source,
                                  destinationTexture: destination)
            }
        }
    }

    /// Aspect-fit mapping of a source size into a destination size: uniform scale (the smaller of
    /// the two axis ratios) and the centering translation. Pure — pinned by unit tests.
    static func aspectFit(source: (width: Int, height: Int), dest: (width: Int, height: Int))
        -> (scale: Double, translateX: Double, translateY: Double) {
        let scale = min(Double(dest.width) / Double(source.width),
                        Double(dest.height) / Double(source.height))
        let tx = (Double(dest.width) - Double(source.width) * scale) / 2
        let ty = (Double(dest.height) - Double(source.height) * scale) / 2
        return (scale, tx, ty)
    }

    /// Real framebuffer readback of the render-endpoint texture (`agent_view_frame`). Renders a fresh
    /// frame and blits the endpoint into a fresh `.shared` capture texture INSIDE the same command
    /// buffer — immune to live frames re-encoding the endpoint — then waits and reads back OUTSIDE the
    /// lock, so a capture (or an agent polling captures) never stalls the viewport. `nil` if nothing
    /// rendered.
    ///
    /// Note the capture encode runs the node schedule on the CALLER'S thread (main, in practice):
    /// `update()` is serialized against live frames by the lock — never concurrent — but nodes must not
    /// assume a single render thread identity (documented in the node ABI's threading contract).
    public func captureFrame() -> SZImageBytes? {
        let job = engine.withLock { state -> CaptureJob? in
            // Paused → capture the HELD endpoint without advancing the schedule, matching the live
            // viewport (both freeze the whole graph at the runtime level). The non-allocating read
            // matters here too: renderSize can have moved under a paused hold (viewport resized),
            // and an allocating read at the new size would destroy the held frame — the capture
            // reports the held texture's own dimensions, which is the truth.
            if state.timeline.paused {
                guard let endpoint = state.scheduler?.heldEndpointTexture(assets: assets) else { return nil }
                return commitCapture(of: endpoint)
            }
            var capture: (any MTLTexture)?
            let (buffer, _) = encodeAndCommitFrame(&state, width: state.renderSize.width,
                                                   height: state.renderSize.height) { commandBuffer, endpoint in
                if let endpoint { capture = encodeCapture(of: endpoint, on: commandBuffer) }
            }
            guard let buffer, let capture else { return nil }
            return CaptureJob(buffer: buffer, capture: capture)
        }
        return readBack(job)
    }

    /// Readback of ONE node's texture output straight off the asset pool (`agent_view_frame {node}`) —
    /// a look at any rendered port without moving the render endpoint. Reads the last-written pool
    /// texture (at most one frame stale) via its own blit + command buffer, committed under the lock
    /// and read back outside it, like `captureFrame`. `nil` if the port has never rendered (an
    /// unimplemented node, or no frame yet) — never a fabricated blank.
    public func captureTexture(node: SZNodeID, port: String) -> SZImageBytes? {
        let job = engine.withLock { _ -> CaptureJob? in
            guard let source = assets.existing(id: SZScheduler.textureID(node: node, port: port)),
                  source.pixelFormat == .bgra8Unorm else { return nil }
            return commitCapture(of: source)
        }
        return readBack(job)
    }

    /// A committed capture: the buffer to wait on + the `.shared` texture it fills.
    private struct CaptureJob {
        let buffer: any MTLCommandBuffer
        let capture: any MTLTexture
    }

    /// Blit `source` into a fresh `.shared` capture texture on `commandBuffer` (CPU-readable after the
    /// blit completes). Per-call: captures are rare debug ops, and a cached target could not cross the
    /// lock boundary under region isolation. Caller holds the engine lock.
    private func encodeCapture(of source: any MTLTexture, on commandBuffer: any MTLCommandBuffer) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: source.width, height: source.height, mipmapped: false)
        descriptor.storageMode = .shared
        guard let target = assets.device.makeTexture(descriptor: descriptor) else { return nil }
        Self.encodeCopy(source, into: target, width: source.width, height: source.height, on: commandBuffer)
        return target
    }

    /// `encodeCapture` on its own command buffer, committed (commit-under-lock). Caller holds the lock.
    private func commitCapture(of source: any MTLTexture) -> CaptureJob? {
        guard let commandBuffer = assets.commandQueue.makeCommandBuffer(),
              let capture = encodeCapture(of: source, on: commandBuffer) else { return nil }
        commandBuffer.commit()
        return CaptureJob(buffer: commandBuffer, capture: capture)
    }

    /// GPU wait + CPU readback of a committed capture — no lock held; the capture texture is only ever
    /// written by its own buffer.
    private func readBack(_ job: CaptureJob?) -> SZImageBytes? {
        guard let job else { return nil }
        job.buffer.waitUntilCompleted()
        let width = job.capture.width, height = job.capture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            job.capture.getBytes(
                raw.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0)
        }
        return SZImageBytes(width: width, height: height, bgra: bytes)
    }

    /// The one texture-to-texture copy both presentation (endpoint → drawable) and capture
    /// (endpoint → capture target) encode — a single site so clamp/origin fixes can't drift apart.
    private static func encodeCopy(_ source: any MTLTexture, into destination: any MTLTexture,
                                   width: Int, height: Int, on commandBuffer: any MTLCommandBuffer) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(
            from: source, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: destination, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }
}

/// A captured frame: raw BGRA8 pixels (row-major, 4 bytes/pixel) + dimensions. PNG encoding layers on
/// when a consumer needs it. (Would move to SZCore if a Metal-free `SZRenderer` seam ever appears.)
public struct SZImageBytes: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let bgra: [UInt8]

    public init(width: Int, height: Int, bgra: [UInt8]) {
        self.width = width
        self.height = height
        self.bgra = bgra
    }

    /// The BGRA pixel at (x, y), or nil if out of bounds. Convenience for tests.
    public func pixel(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        guard i + 3 < bgra.count else { return nil }
        return (bgra[i], bgra[i + 1], bgra[i + 2], bgra[i + 3])
    }
}
