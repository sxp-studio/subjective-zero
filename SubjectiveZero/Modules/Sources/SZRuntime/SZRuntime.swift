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
import Synchronization
import SZCore

/// Result of a compile-check (`compileNodeSource`). `.failed` carries the swiftc log for the agent's
/// fix loop / `debug_get_build_errors`.
public enum SZBuildResult: Sendable, Equatable {
    case ok
    case failed(String)
}

/// Threading contract (the reason this class is NOT `@MainActor`): the live viewport renders on a
/// dedicated display-link thread — SZUI's viewport render loop drives the host-wired closure → `drawLive(into:)` —
/// so the editor's SwiftUI work can never starve viewport frames (profiled on main, camera/drag
/// interactions delayed draws by 20–700ms). Everything a frame encode touches lives in `EngineState`
/// behind a `Mutex` — the compiler enforces that no engine state is reachable outside `withLock`.
///
/// THE LOCK-SCOPE RULE (what makes a mutex acceptable in a renderer): critical sections contain
/// ONLY CPU-side encode/state work, never anything that can block — `nextDrawable()` (parks up to
/// ~1s on an occluded window), `waitUntilCompleted`, CPU readbacks, and node device enumeration all
/// run OUTSIDE the lock. Worst-case cross-thread wait is therefore one encode (sub-ms), not a
/// drawable stall; the one deliberate exception is a graph swap/hot reload, which holds the lock
/// through node teardown+setup so a frame can never interleave a half-swapped graph.
///
/// THE COMMIT-UNDER-LOCK RULE: every schedule command buffer is COMMITTED inside the same critical
/// section that encoded it (commit is a non-blocking enqueue), so no encoded-but-uncommitted buffer
/// ever escapes — commit order equals encode order by construction, and Metal's hazard tracking on
/// the (whole-resource-synchronized) pool textures keeps every pass consistent. Presentation is a
/// separate tiny blit buffer AFTER `nextDrawable()`. The one accepted effect: a capture or offline
/// render committed between a live frame's commit and its present blit can make the viewport show a
/// one-frame-NEWER endpoint — whole frames only, monotonic, invisible in practice.
///
/// `@unchecked Sendable` is retained but NARROW: `assets`' mutable pool is only ever touched inside
/// `engine.withLock`, and `toolchain`/compile paths are main-thread-only by convention. Everything
/// else is either in the Mutex or immutable.
public final class SZRuntime: @unchecked Sendable {
    /// Everything a frame encode reads or a load/reload swaps — guarded by `engine`.
    private struct EngineState {
        var scheduler: SZScheduler?
        var loaders: [SZNodeID: SZLoader] = [:]
        /// Live scalar input values per node/port (the v3 ABI channel): seeded from contract input
        /// defaults on load, overridable via `setInputValue` — read every frame, no recompile.
        var inputValues: [SZNodeID: [String: [Float]]] = [:]
        /// Live string/enum input values per node/port (the v4 ABI channel) — same lifecycle.
        var inputStrings: [SZNodeID: [String: String]] = [:]
        /// The virtual playback clock — owns `frameIndex` + `timeSeconds`, pausable/resettable from the
        /// HUD. Read and advanced only here under the engine lock (see SZTimeline).
        var timeline = SZTimeline()
        /// Offscreen render size; the live viewport overrides it each frame with its drawable size.
        var renderSize: (width: Int, height: Int)
    }

    private let engine: Mutex<EngineState>
    private let assets: SZAssetManager
    private let toolchain = SZToolchain()
    private let workspace: URL

    /// The permission broker. The runtime owns permissions; capture lives in the node. The host
    /// pre-grants declared permissions (`requestDeclaredPermissions`) before loading.
    public let permissions = SZPermissions()

    /// Offscreen render size (the live viewport overrides it each frame with its drawable size).
    /// Read-only publicly: the render thread writes it per frame under the engine lock.
    public var renderSize: (width: Int, height: Int) {
        engine.withLock { $0.renderSize }
    }

    /// The owned Metal device — vended to the viewport's layer by the host.
    public var device: any MTLDevice { assets.device }

    public init?(renderSize: (width: Int, height: Int) = (1280, 800), workspace: URL? = nil) {
        guard let assets = SZAssetManager() else { return nil }
        self.assets = assets
        self.engine = Mutex(EngineState(renderSize: renderSize))
        self.workspace = workspace
            ?? FileManager.default.temporaryDirectory.appending(path: "SZRuntime-\(UUID().uuidString)")
    }

    /// Load a whole project from its `.subz` directory: read the model, compile each node's `Node.swift`,
    /// and build the schedule. Replaces any live graph. The host should `requestDeclaredPermissions`
    /// first so a node that needs e.g. the camera is already authorized when its `setup` runs.
    public func loadProject(at url: URL) throws {
        let project = try SZProjectIO.load(from: url)
        // Render only IMPLEMENTED nodes: a prompt node has no Node.swift to compile. This is what lets a
        // graph with un-implemented (dirty) prompt nodes load — the agent loop starts from exactly that,
        // and the node becomes renderable once its coding agent's source is promoted (kind → generated).
        try loadGraph(Self.renderableSubgraph(project.graph)) { SZProjectIO.nodeSourceURL(projectURL: url, nodeID: $0) }
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
        do {
            _ = try toolchain.compile(
                nodeSource: source,
                into: workspace.appending(path: "staging-check/\(UUID().uuidString)"))
            return .ok
        } catch {
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
            nodeSource: source, into: workspace.appending(path: "build/\(id.uuidString)"))
        // The in-place module swap must not interleave a live-viewport frame encode.
        try engine.withLock { _ in
            var ctx = SZRuntimeContextRaw()
            ctx.device = Unmanaged.passUnretained(assets.device as AnyObject).toOpaque()
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
        let schedule = try SZScheduler(graph: graph)

        // Diff old vs new node sets. `added` compile; `removed` tear down; the rest are reused untouched.
        let oldIDs = engine.withLock { Set($0.loaders.keys) }
        let newIDs = Set(graph.nodes.map(\.id))
        let added = newIDs.subtracting(oldIDs)
        let removed = oldIDs.subtracting(newIDs)
        let retained = newIDs.intersection(oldIDs)

        // Phase 1 — compile + open only the added nodes (no setup yet), strictly OUTSIDE the lock (slow).
        // Throws leave the live graph untouched. Empty for a pure wiring edit ⇒ zero compiles.
        var newLoaders: [SZNodeID: SZLoader] = [:]
        for nodeID in schedule.order where added.contains(nodeID) {
            let dylib = try toolchain.compile(
                nodeSource: sourceURL(nodeID),
                into: workspace.appending(path: "build/\(nodeID.uuidString)"))
            let loader = SZLoader()
            try loader.open(
                dylib: dylib,
                runtimeLoadsDir: workspace.appending(path: "runtime-loads/\(nodeID.uuidString)"))
            newLoaders[nodeID] = loader
        }

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
                }
            }

            // Commit: drop removed loaders, splice in the added ones, leave retained in place.
            for id in removed { state.loaders[id] = nil }
            for (id, loader) in newLoaders { state.loaders[id] = loader }
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

    /// Re-point the live render endpoint without a reload (the host op behind `ui_toggle_display`). The
    /// scheduler reads this each frame → the viewport switches next frame. `nil` clears it (black
    /// viewport). The host should only point it at a currently-rendered (generated) node's texture output.
    public func setRenderEndpoint(_ ref: SZPortRef?) {
        engine.withLock { $0.scheduler?.renderEndpoint = ref }
    }

    /// Pause/resume the playback clock (the HUD Pause/Play toggle). While paused the render loop stops
    /// advancing the schedule and just re-presents the current endpoint (see `drawLive` / `captureFrame`),
    /// so the whole graph holds still; on resume the clock continues from where it stopped (the paused
    /// span is excluded, so no time jump).
    public func setPaused(_ paused: Bool) {
        engine.withLock { $0.timeline.setPaused(paused, now: CACurrentMediaTime()) }
    }

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

    /// Encode one schedule pass into a fresh command buffer and COMMIT it — the commit-under-lock rule
    /// (see the class header). Caller must be inside `engine.withLock`; extra work destined for the
    /// same buffer (a capture blit) is encoded via `beforeCommit` so it still precedes the commit.
    private func encodeAndCommitFrame(
        _ state: inout EngineState, width: Int, height: Int,
        beforeCommit: (any MTLCommandBuffer, any MTLTexture) -> Void = { _, _ in }
    ) -> (buffer: (any MTLCommandBuffer)?, endpoint: (any MTLTexture)?) {
        guard let scheduler = state.scheduler else { return (nil, nil) }
        guard let commandBuffer = assets.commandQueue.makeCommandBuffer() else { return (nil, nil) }
        let timing = state.timeline.nextFrame(now: CACurrentMediaTime())
        let endpoint = scheduler.encodeFrame(
            device: assets.device, commandBuffer: commandBuffer, assets: assets, loaders: state.loaders,
            inputValues: state.inputValues, inputStrings: state.inputStrings, frameIndex: timing.frameIndex,
            time: timing.timeSeconds,
            width: width, height: height)
        if let endpoint { beforeCommit(commandBuffer, endpoint) }
        commandBuffer.commit()
        return (commandBuffer, endpoint)
    }

    /// Live viewport frame, called on the DISPLAY-LINK thread (the viewport's render loop → the host-wired
    /// closure), never the main thread — see the class header. Takes the viewport's `CAMetalLayer`:
    /// its drawable APIs are thread-safe, and `drawableSize` is READ-only here (the view owns it and
    /// keeps it synced on the main thread), so no cross-thread geometry writes.
    ///
    /// Pipeline (lock-scope + commit-under-lock rules): the schedule encodes AND commits inside the
    /// lock; then — no lock held — `nextDrawable()` (can park ~1s on an occluded window) and a second
    /// tiny buffer blits the endpoint onto the drawable and presents. The endpoint local is retained,
    /// so a concurrent graph swap resetting the pool can't deallocate it under the blit.
    public func drawLive(into layer: CAMetalLayer) {
        let size = layer.drawableSize   // synced by the view on the main thread
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return }

        let endpoint = engine.withLock { state -> (any MTLTexture)? in
            state.renderSize = (width, height)
            // Paused → hold the frame: DON'T advance the schedule, just re-present the CURRENT render
            // endpoint's pooled texture (each node's last output is still in the pool). This freezes the
            // ENTIRE graph (camera, live-capture, generative) at the runtime level, so pause works for
            // every project regardless of whether its node sources know about the timeline — and reading
            // the *current* endpoint means switching the display target while paused shows that node's
            // held frame, not a stale one. Re-presented each vsync so the freeze survives occlusion /
            // display changes / resize.
            if state.timeline.paused {
                return state.scheduler?.endpointTexture(assets: assets, width: width, height: height)
            }
            return encodeAndCommitFrame(&state, width: width, height: height).endpoint
        }

        // Blocking presentation below — no lock held.
        guard let drawable = layer.nextDrawable(),
              let presentBuffer = assets.commandQueue.makeCommandBuffer() else { return }
        if let endpoint {
            // Clamp to the drawable's actual size: the layer can resize between the drawableSize read
            // (before encoding) and nextDrawable(), and an out-of-bounds blit fails Metal validation.
            Self.encodeCopy(endpoint, into: drawable.texture,
                            width: min(width, drawable.texture.width),
                            height: min(height, drawable.texture.height),
                            on: presentBuffer)
        } else {
            // No render endpoint (e.g. its node was deleted): clear the drawable to black instead of
            // presenting an uninitialized buffer, which shows up as garbage/glitching.
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            presentBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        presentBuffer.present(drawable)
        presentBuffer.commit()
    }

    /// Real framebuffer readback of the render-endpoint texture (`agent_view_frame`). Renders a fresh
    /// frame and blits the endpoint into a fresh `.shared` capture texture INSIDE the same command
    /// buffer — immune to live frames re-encoding the endpoint — then waits and reads back OUTSIDE the
    /// lock, so a capture (or an agent polling captures) never stalls the viewport. The capture texture
    /// is per-call (captures are rare debug ops): a cached one could not cross the lock boundary under
    /// region isolation. `nil` if nothing rendered.
    ///
    /// Note the capture encode runs the node schedule on the CALLER'S thread (main, in practice):
    /// `update()` is serialized against live frames by the lock — never concurrent — but nodes must not
    /// assume a single render thread identity (documented in the node ABI's threading contract).
    public func captureFrame() -> SZImageBytes? {
        let result = engine.withLock { state -> (buffer: (any MTLCommandBuffer)?, capture: (any MTLTexture)?) in
            // Blit `endpoint` into a fresh `.shared` capture texture on `commandBuffer` (CPU-readable after
            // the blit completes) and return it. Per-call: captures are rare debug ops.
            func captureEndpoint(_ commandBuffer: any MTLCommandBuffer, _ endpoint: any MTLTexture) -> (any MTLTexture)? {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: endpoint.width, height: endpoint.height, mipmapped: false)
                descriptor.storageMode = .shared
                guard let target = assets.device.makeTexture(descriptor: descriptor) else { return nil }
                Self.encodeCopy(endpoint, into: target, width: endpoint.width, height: endpoint.height,
                                on: commandBuffer)
                return target
            }

            let width = state.renderSize.width, height = state.renderSize.height

            // Paused → capture the HELD endpoint without advancing the schedule, matching the live
            // viewport (both freeze the whole graph at the runtime level).
            if state.timeline.paused {
                guard let endpoint = state.scheduler?.endpointTexture(assets: assets, width: width, height: height),
                      let commandBuffer = assets.commandQueue.makeCommandBuffer(),
                      let capture = captureEndpoint(commandBuffer, endpoint) else { return (nil, nil) }
                commandBuffer.commit()
                return (commandBuffer, capture)
            }

            var capture: (any MTLTexture)?
            let (buffer, _) = encodeAndCommitFrame(&state, width: width, height: height) { commandBuffer, endpoint in
                capture = captureEndpoint(commandBuffer, endpoint)
            }
            return (buffer, capture)
        }
        guard let buffer = result.buffer, let capture = result.capture else { return nil }

        // GPU wait + CPU readback — no lock held; `capture` is only ever written by the buffer above.
        buffer.waitUntilCompleted()
        let width = capture.width, height = capture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            capture.getBytes(
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
