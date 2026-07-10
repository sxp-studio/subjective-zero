// SPDX-License-Identifier: AGPL-3.0-only
// Schedules + executes the node DAG each frame (RUNTIME.md). The graph is a **strict DAG**: nodes are
// topologically ordered (a connection `from → to` means `from` runs first), then each node's `update` is
// encoded in order. A node's declared outputs are allocated from the asset manager by id
// ("<nodeID>:<port>"); a downstream node's inputs are bound to the same ids via its data connections. The
// render-endpoint texture is returned for the caller to blit to the viewport / read back.
//
// Flow vs data: data edges carry the runtime texture a node actually reads and define execution order.
// Flow edges are a transient authoring annotation (drawing intent the Director resolves into data wiring)
// and are NOT a runtime construct — the topological order is derived from DATA edges only (GRAPH_AND_NODES).
// The topo kernel is Kahn's algorithm.
import Foundation
import Metal
import SZCore

/// Per-frame bindings for one node — the opaque object the C-ABI resolver fns read against: declared
/// input/output textures, plus scalar input values (v3) for unconnected inputs.
final class SZFrameBindings {
    var inputs: [String: any MTLTexture] = [:]
    var outputs: [String: any MTLTexture] = [:]
    var values: [String: [Float]] = [:]
    var strings: [String: String] = [:]   // v4: enum/string input values (unconnected inputs)
    var outputValues: [String: [Float]] = [:]   // v5: scalar OUTPUT values the node emits this frame
    var holds: SZFrameHolds?              // v6: the FRAME-wide hold list (one per encodeFrame, shared)
}

/// Objects pinned for one frame's GPU lifetime (v6, `holdUntilFrameCompletes`): accumulated across every
/// node's encode, then captured by the command buffer's completed-handler — that capture IS the
/// retention; GPU completion releases it.
final class SZFrameHolds: @unchecked Sendable {   // append-only during single-threaded encode; immutable once the handler holds it
    var objects: [AnyObject] = []
}

// Host-side resolvers handed to each node via the raw context. Non-capturing `@convention(c)` closures
// (they only call a global helper), so they are valid C function pointers.
let szResolveInputTexture: SZTextureResolver = { ctx, name in szResolveTexture(ctx, name, outputs: false) }
let szResolveOutputTexture: SZTextureResolver = { ctx, name in szResolveTexture(ctx, name, outputs: true) }

private func szResolveTexture(
    _ ctx: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?,
    outputs: Bool
) -> UnsafeMutableRawPointer? {
    guard let ctx, let name else { return nil }
    let bindings = Unmanaged<SZFrameBindings>.fromOpaque(ctx).takeUnretainedValue()
    let port = String(cString: name)
    guard let texture = (outputs ? bindings.outputs : bindings.inputs)[port] else { return nil }
    return Unmanaged.passUnretained(texture as AnyObject).toOpaque()
}

/// Resolves a port name to its value(s): copies up to `capacity` floats into `out`, returns the value's
/// FULL count (0 if the port has no value) so an undersized caller can grow + retry (a `floatArray` read).
let szResolveInputValue: SZValueResolver = { ctx, name, out, capacity in
    guard let ctx, let name, let out else { return 0 }
    let bindings = Unmanaged<SZFrameBindings>.fromOpaque(ctx).takeUnretainedValue()
    guard let values = bindings.values[String(cString: name)] else { return 0 }
    let n = min(values.count, Int(capacity))
    for i in 0..<n { out[i] = values[i] }
    return Int32(values.count)   // full length (not n) so an undersized caller can grow + retry — `floatArray` reads of any size
}

/// Resolves a port name to its string value (v4): copies up to `capacity` UTF-8 bytes into `out`, returns
/// the value's FULL byte length (0 if the port has no value) so the node can grow + retry on truncation.
let szResolveInputString: SZStringResolver = { ctx, name, out, capacity in
    guard let ctx, let name, let out else { return 0 }
    let bindings = Unmanaged<SZFrameBindings>.fromOpaque(ctx).takeUnretainedValue()
    guard let value = bindings.strings[String(cString: name)] else { return 0 }
    let bytes = Array(value.utf8)
    let n = min(bytes.count, Int(capacity))
    for i in 0..<n { out[i] = CChar(bitPattern: bytes[i]) }
    return Int32(bytes.count)
}

/// Records a node's emitted scalar OUTPUT value(s) (v5): copies `count` floats from `in` into the node's
/// bindings, where the scheduler reads them back after the frame to feed a connected downstream input.
let szResolveOutputValue: SZOutputValueResolver = { ctx, name, in_, count in
    guard let ctx, let name, let in_ else { return }
    let bindings = Unmanaged<SZFrameBindings>.fromOpaque(ctx).takeUnretainedValue()
    bindings.outputValues[String(cString: name)] = Array(UnsafeBufferPointer(start: in_, count: Int(count)))
}

/// Pins an object until the frame's command buffer completes (v6). OWNERSHIP TRANSFER: the node side
/// passed a +1-retained pointer (`passRetained`), balanced here by `takeRetainedValue` into the frame's
/// hold list. Dropped (released immediately) if the frame has no hold list — nothing to pin against.
let szFrameHold: SZFrameHoldFn = { ctx, object in
    guard let ctx, let object else { return }
    let bindings = Unmanaged<SZFrameBindings>.fromOpaque(ctx).takeUnretainedValue()
    let held = Unmanaged<AnyObject>.fromOpaque(object).takeRetainedValue()
    bindings.holds?.objects.append(held)
}

struct SZScheduler: Sendable {
    enum SchedulerError: Error, CustomStringConvertible {
        case cycle
        var description: String { "graph is not a DAG (cycle detected)" }
    }

    let graph: SZGraph
    /// Topological execution order (node ids).
    let order: [SZNodeID]
    /// The texture output blitted to the viewport. Seeded from `graph.renderEndpoint`, but mutable so the
    /// host can re-point it live (`SZRuntime.setRenderEndpoint`, behind `ui_toggle_display`) without a
    /// reload — only the final endpoint lookup changes, not the topology.
    var renderEndpoint: SZPortRef?

    init(graph: SZGraph) throws {
        guard let order = Self.topologicalOrder(graph) else { throw SchedulerError.cycle }
        self.graph = graph
        self.order = order
        self.renderEndpoint = graph.renderEndpoint
    }

    /// Encode every node's `update` for one frame into `commandBuffer`. Returns the render-endpoint
    /// texture (nil if the graph has no endpoint). Does not commit — the caller owns commit/present/wait.
    func encodeFrame(
        device: any MTLDevice,
        commandBuffer: any MTLCommandBuffer,
        assets: SZAssetManager,
        loaders: [SZNodeID: SZLoader],
        inputValues: [SZNodeID: [String: [Float]]],
        inputStrings: [SZNodeID: [String: String]],
        frameIndex: UInt64,
        time: Double,
        width: Int,
        height: Int
    ) -> (any MTLTexture)? {
        // Scalar output values emitted by nodes earlier this frame, keyed "<nodeID>:<port>" — the v5
        // connected value channel. Topo order runs producers first, so a downstream node's connected value
        // input is already populated here by the time we bind it. Frame-scoped (cleared each call).
        var valueOutputs: [String: [Float]] = [:]
        // Frame-lifetime holds (v6) — one list for the whole frame, shared by every node's bindings.
        let holds = SZFrameHolds()

        for nodeID in order {
            guard let node = graph.node(id: nodeID), let loader = loaders[nodeID] else { continue }

            let bindings = SZFrameBindings()
            for port in node.contract?.outputs ?? [] where port.type == .texture {
                bindings.outputs[port.name] = assets.texture(
                    id: Self.textureID(node: nodeID, port: port.name), width: width, height: height)
            }
            bindings.values = inputValues[nodeID] ?? [:]   // scalar input values (unconnected inputs)
            bindings.strings = inputStrings[nodeID] ?? [:]  // string/enum input values (unconnected inputs)
            bindings.holds = holds

            // Route each data edge into this node by its SOURCE port's type: a texture binds the upstream
            // texture (as before); a non-texture source feeds the upstream node's emitted output value into
            // this input, overriding the unconnected default seeded just above.
            for connection in graph.connections where connection.kind == .data && connection.to.node == nodeID {
                let sourceID = Self.textureID(node: connection.from.node, port: connection.from.port)
                if Self.sourcePortType(graph, connection.from) == .texture {
                    bindings.inputs[connection.to.port] = assets.texture(
                        id: sourceID, width: width, height: height)
                } else if let value = valueOutputs[sourceID] {
                    bindings.values[connection.to.port] = value
                }
            }

            withExtendedLifetime(bindings) {
                var ctx = SZRuntimeContextRaw()
                ctx.frameIndex = frameIndex
                ctx.viewportWidth = UInt32(width)
                ctx.viewportHeight = UInt32(height)
                ctx.timeSeconds = time
                ctx.device = Unmanaged.passUnretained(device as AnyObject).toOpaque()
                ctx.commandBuffer = Unmanaged.passUnretained(commandBuffer as AnyObject).toOpaque()
                ctx.resolverContext = Unmanaged.passUnretained(bindings).toOpaque()
                ctx.inputTextureFn = szResolveInputTexture
                ctx.outputTextureFn = szResolveOutputTexture
                ctx.inputValueFn = szResolveInputValue
                ctx.inputStringFn = szResolveInputString
                ctx.outputValueFn = szResolveOutputValue
                ctx.frameHoldFn = szFrameHold
                withUnsafeMutablePointer(to: &ctx) { pointer in
                    _ = loader.renderFrame(context: UnsafeMutableRawPointer(pointer))
                }
            }

            // Publish this node's emitted output values for downstream nodes later in the topo order.
            for (port, value) in bindings.outputValues {
                valueOutputs[Self.textureID(node: nodeID, port: port)] = value
            }
        }

        // The completed-handler's capture keeps every held object alive until the GPU has executed
        // this frame; registered here (pre-commit — the runtime commits after encodeFrame returns).
        if !holds.objects.isEmpty {
            commandBuffer.addCompletedHandler { _ in _ = holds }
        }

        guard let endpoint = renderEndpoint else { return nil }
        return assets.texture(
            id: Self.textureID(node: endpoint.node, port: endpoint.port), width: width, height: height)
    }

    /// The pooled texture the CURRENT `renderEndpoint` points at, WITHOUT encoding a frame. The by-id
    /// pool still holds every node's last-written output, so a paused viewport can present the live
    /// endpoint by reading it directly — and following a display-target switch shows that node's held
    /// frame rather than a stale cached one. nil if there's no endpoint.
    func endpointTexture(assets: SZAssetManager, width: Int, height: Int) -> (any MTLTexture)? {
        guard let endpoint = renderEndpoint else { return nil }
        return assets.texture(
            id: Self.textureID(node: endpoint.node, port: endpoint.port), width: width, height: height)
    }

    static func textureID(node: SZNodeID, port: String) -> String { "\(node.uuidString):\(port)" }

    /// The declared type of a connection's source output port (nil if the node/port/contract is missing).
    /// Used to route a data edge: `.texture` flows a texture; any other type flows a scalar value (v5).
    static func sourcePortType(_ graph: SZGraph, _ ref: SZPortRef) -> SZPortType? {
        graph.node(id: ref.node)?.contract?.outputs.first { $0.name == ref.port }?.type
    }

    /// Kahn's algorithm over DATA edges (flow is authoring intent, not runtime order). Returns nil on a
    /// cycle. Ties broken by graph node order for determinism.
    static func topologicalOrder(_ graph: SZGraph) -> [SZNodeID]? {
        let nodeIDs = graph.nodes.map(\.id)
        let index = Dictionary(uniqueKeysWithValues: nodeIDs.enumerated().map { ($1, $0) })
        var indegree = Dictionary(uniqueKeysWithValues: nodeIDs.map { ($0, 0) })
        var successors: [SZNodeID: [SZNodeID]] = [:]
        for connection in graph.connections where connection.kind == .data {
            let from = connection.from.node, to = connection.to.node
            guard index[from] != nil, index[to] != nil, from != to else { continue }
            successors[from, default: []].append(to)
            indegree[to, default: 0] += 1
        }

        var ready = nodeIDs.filter { indegree[$0] == 0 }.sorted { index[$0]! < index[$1]! }
        var result: [SZNodeID] = []
        while let next = ready.first {
            ready.removeFirst()
            result.append(next)
            for successor in successors[next] ?? [] {
                indegree[successor]! -= 1
                if indegree[successor] == 0 {
                    let position = ready.firstIndex { index[$0]! > index[successor]! } ?? ready.endIndex
                    ready.insert(successor, at: position)
                }
            }
        }
        return result.count == nodeIDs.count ? result : nil
    }
}
