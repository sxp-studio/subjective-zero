// SPDX-License-Identifier: AGPL-3.0-only
// The frozen node ABI (host-owned, stable across all nodes — RUNTIME.md, BUILD_SPEC.md).
//
// The cross-`dlopen` contract is **C-ABI** (sidesteps Swift cross-module ABI fragility). The ergonomic
// `SZNode` protocol + typed contexts are *compiled into each node* from the host-owned
// `SZRuntimeSupport.source` injected alongside the author's `Node.swift`. A node dylib exports
// four stable C symbols; the host dlsym's those and populates the raw context struct below.
//
// The context carries **declared input/output texture bindings**: the runtime doesn't hand the node one
// output texture, it hands a *resolver* (an opaque per-frame bindings object + two C function pointers)
// so the node fetches `inputTexture("input")` / `outputTexture("output")` by the port names in its
// contract. Texture handles cross as opaque pointers (recovered via `Unmanaged`). A third resolver fn
// is the scalar-input channel: it resolves a port name to its float value(s) (an unconnected input's
// default, live-overridable from the host) so a node reads e.g. `ctx.inputFloat("speed")` at runtime.
// `persistentTexture` is still not in the ABI (earned, not scheduled).
import Foundation

/// Resolves a port name to an opaque texture pointer against a per-frame bindings object. Implemented
/// host-side (SZScheduler), called node-side. `(resolverContext, portName) -> texturePtr?`.
typealias SZTextureResolver = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

/// Resolves a port name to its scalar value(s): writes up to `capacity` floats into `out`, returns the
/// count written (0 if the port has no value, e.g. it's connected or unset). Host-side, called node-side.
/// `(resolverContext, portName, out, capacity) -> count`.
typealias SZValueResolver = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<Float>?, Int32) -> Int32

/// Resolves a port name to its string value (an `enum`/`string` input's default, live-overridable from
/// the host): writes up to `capacity` UTF-8 bytes into `out`, returns the value's FULL byte length (0 if
/// the port has no value). Returning the full length lets the node grow its buffer + retry on truncation.
/// Host-side, called node-side. `(resolverContext, portName, out, capacity) -> fullLength`.
typealias SZStringResolver = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int32) -> Int32

/// Emits a port's scalar output value(s): the node hands the runtime up to `count` floats from `in` for a
/// named declared NON-texture output port, which the runtime then routes across a `.data` edge into a
/// downstream node's input. The write-side mirror of `SZValueResolver`. Host-side, called node-side.
/// `(resolverContext, portName, in, count) -> Void`.
typealias SZOutputValueResolver = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<Float>?, Int32) -> Void

/// Pins an object until this frame's command buffer has EXECUTED on the GPU (v6). OWNERSHIP TRANSFER —
/// unlike the borrow-only resolvers above, the node side passes a +1-RETAINED pointer
/// (`Unmanaged.passRetained`); the host takes ownership (`takeRetainedValue`) into the frame's hold
/// list and releases after GPU completion. Host-side, called node-side. `(resolverContext, object)`.
typealias SZFrameHoldFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

enum SZNodeABI {
    /// Bumped on a breaking ABI change. The loader rejects a mismatch. v2 = binding-table context;
    /// v3 = scalar-input value channel; v4 = string-input channel; v5 = output value channel
    /// (a node's non-texture output flowing across a data edge to a downstream input); v6 = frame-lifetime
    /// hold (pin an object until the frame's command buffer completes — pooled capture buffers etc.).
    static let version: Int32 = 6

    static let apiVersionSymbol = "SZPluginAPIVersion"
    static let setupSymbol = "SZNodeSetup"
    static let updateSymbol = "SZNodeUpdate"
    static let teardownSymbol = "SZNodeTeardown"
    /// Optional (v4): a node's dynamic enum options for a port. Absent on a node that has none.
    static let enumerateOptionsSymbol = "SZNodeEnumerateOptions"

    typealias APIVersionFn = @convention(c) () -> Int32
    typealias SetupFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias UpdateFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias TeardownFn = @convention(c) () -> Void
    /// `(portName, out, capacity) -> fullLength`: writes the port's options as positional-pair JSON
    /// (`[["label","value"],…]`) into `out`, returning the full byte length (grow + retry on truncation).
    typealias EnumerateOptionsFn = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int32) -> Int32
}

/// The raw context struct passed across the C-ABI boundary. **Its layout must byte-match the copy inside
/// `SZRuntimeSupport.source`** — both are compiled by the same `swiftc`, so identical field order/types ⇒
/// identical layout. Opaque pointers carry Metal objects; the resolver fn pointers + context carry the
/// per-frame texture bindings.
struct SZRuntimeContextRaw {
    var apiVersion: Int32 = SZNodeABI.version
    var frameIndex: UInt64 = 0
    var viewportWidth: UInt32 = 0
    var viewportHeight: UInt32 = 0
    var timeSeconds: Double = 0
    var device: UnsafeMutableRawPointer?
    var commandBuffer: UnsafeMutableRawPointer?
    var resolverContext: UnsafeMutableRawPointer?    // opaque SZFrameBindings (host-side)
    var inputTextureFn: SZTextureResolver?
    var outputTextureFn: SZTextureResolver?
    var inputValueFn: SZValueResolver?               // v3: scalar input values (appended → layout-compatible)
    var inputStringFn: SZStringResolver?             // v4: string/enum input values (appended → layout-compatible)
    var outputValueFn: SZOutputValueResolver?        // v5: scalar OUTPUT values (appended → layout-compatible)
    var frameHoldFn: SZFrameHoldFn?                  // v6: frame-lifetime hold (appended → layout-compatible)
}

/// The host-owned Swift source compiled into every node dylib (alongside the author's `Node.swift`). It
/// defines the `SZNode` protocol + typed contexts and exports the four `@_cdecl` C entry points. Node
/// authors must NOT redeclare these symbols or touch the raw struct (RUNTIME.md).
enum SZRuntimeSupport {
    /// Relative path the support file is written to inside a node's build dir.
    static let fileName = "SZRuntimeSupport.swift"

    static let source = """
    // HOST-OWNED. Generated by SZRuntime. Do not edit in a node.
    import Foundation
    @preconcurrency import Metal

    public enum SZNodeStatus {
        public static let success: Int32 = 0
        public static let failure: Int32 = 1
    }

    /// One dynamic choice a node offers for an `enum` port: a human `label` + the canonical `value` the
    /// node switches on. Mirrors SZCore.SZEnumOption; crosses to the host as positional-pair JSON.
    public struct SZEnumOption {
        public let label: String
        public let value: String
        public init(label: String, value: String) { self.label = label; self.value = value }
        public init(_ value: String) { self.label = value; self.value = value }
    }

    typealias SZTextureResolver = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    typealias SZValueResolver = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<Float>?, Int32) -> Int32
    typealias SZStringResolver = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int32) -> Int32
    typealias SZOutputValueResolver = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<Float>?, Int32) -> Void
    typealias SZFrameHoldFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

    // Must byte-match SZRuntimeContextRaw in the host (SZNode.swift).
    struct SZRuntimeContextRaw {
        var apiVersion: Int32
        var frameIndex: UInt64
        var viewportWidth: UInt32
        var viewportHeight: UInt32
        var timeSeconds: Double
        var device: UnsafeMutableRawPointer?
        var commandBuffer: UnsafeMutableRawPointer?
        var resolverContext: UnsafeMutableRawPointer?
        var inputTextureFn: SZTextureResolver?
        var outputTextureFn: SZTextureResolver?
        var inputValueFn: SZValueResolver?
        var inputStringFn: SZStringResolver?
        var outputValueFn: SZOutputValueResolver?
        var frameHoldFn: SZFrameHoldFn?
    }

    private func szObject<T>(_ pointer: UnsafeMutableRawPointer?) -> T? {
        guard let pointer else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }

    /// One-time (re)load context: build pipelines / declare persistent resources here.
    public struct SZSetupContext {
        public let device: any MTLDevice
        init?(_ raw: UnsafeMutableRawPointer?) {
            guard let raw else { return nil }
            let c = raw.assumingMemoryBound(to: SZRuntimeContextRaw.self).pointee
            guard let device: any MTLDevice = szObject(c.device) else { return nil }
            self.device = device
        }
    }

    /// Per-frame context: the viewport primitives + the declared input/output texture bindings
    /// (fetched by the port names in the node's contract).
    public struct SZFrameContext {
        public let device: any MTLDevice
        public let commandBuffer: any MTLCommandBuffer
        public let width: Int
        public let height: Int
        public let frameIndex: UInt64
        public let time: Double
        private let resolverContext: UnsafeMutableRawPointer?
        private let inputTextureFn: SZTextureResolver?
        private let outputTextureFn: SZTextureResolver?
        private let inputValueFn: SZValueResolver?
        private let inputStringFn: SZStringResolver?
        private let outputValueFn: SZOutputValueResolver?
        private let frameHoldFn: SZFrameHoldFn?

        init?(_ raw: UnsafeMutableRawPointer?) {
            guard let raw else { return nil }
            let c = raw.assumingMemoryBound(to: SZRuntimeContextRaw.self).pointee
            guard let device: any MTLDevice = szObject(c.device),
                  let commandBuffer: any MTLCommandBuffer = szObject(c.commandBuffer) else {
                return nil
            }
            self.device = device
            self.commandBuffer = commandBuffer
            self.width = Int(c.viewportWidth)
            self.height = Int(c.viewportHeight)
            self.frameIndex = c.frameIndex
            self.time = c.timeSeconds
            self.resolverContext = c.resolverContext
            self.inputTextureFn = c.inputTextureFn
            self.outputTextureFn = c.outputTextureFn
            self.inputValueFn = c.inputValueFn
            self.inputStringFn = c.inputStringFn
            self.outputValueFn = c.outputValueFn
            self.frameHoldFn = c.frameHoldFn
        }

        private func resolve(_ fn: SZTextureResolver?, _ port: String) -> (any MTLTexture)? {
            guard let fn else { return nil }
            guard let ptr = port.withCString({ fn(resolverContext, $0) }) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue() as? (any MTLTexture)
        }

        /// The texture flowing into the named declared input port (nil if unconnected).
        public func inputTexture(_ port: String) -> (any MTLTexture)? { resolve(inputTextureFn, port) }

        /// The texture the node must fill for the named declared output port (allocated by the runtime).
        public func outputTexture(_ port: String) -> (any MTLTexture)? { resolve(outputTextureFn, port) }

        /// The scalar value(s) of a named input port (its unconnected default, live-overridable from the
        /// host). Up to 16 floats (covers float … float4x4 / colors; bool as 0/1). Empty/nil if unset.
        public func inputFloats(_ port: String) -> [Float]? {
            guard let fn = inputValueFn else { return nil }
            var buffer = [Float](repeating: 0, count: 16)
            let count = port.withCString { name in
                buffer.withUnsafeMutableBufferPointer { fn(resolverContext, name, $0.baseAddress, Int32($0.count)) }
            }
            guard count > 0 else { return nil }
            return Array(buffer.prefix(Int(count)))
        }

        /// The first scalar of a named input port — the common single-float case (e.g. a slider).
        public func inputFloat(_ port: String) -> Float? { inputFloats(port)?.first }

        /// The full variable-length value(s) of a connected `floatArray` input port (e.g. audio samples or
        /// an FFT spectrum) — the array the upstream node emitted via `setOutputFloats`. Unlike
        /// `inputFloats` (capped at 16, for scalars/vectors), this grows + retries to read any length.
        /// nil if the port is unconnected/empty.
        public func inputFloatArray(_ port: String) -> [Float]? {
            guard let fn = inputValueFn else { return nil }
            var capacity = 4096
            while true {
                var buffer = [Float](repeating: 0, count: capacity)
                let full = port.withCString { name in
                    buffer.withUnsafeMutableBufferPointer { fn(resolverContext, name, $0.baseAddress, Int32($0.count)) }
                }
                guard full > 0 else { return nil }
                if Int(full) > capacity { capacity = Int(full); continue }   // truncated → grow & retry
                return Array(buffer.prefix(Int(full)))
            }
        }

        /// Emit the scalar value(s) of a named declared NON-texture output port. The runtime routes them
        /// across a `.data` edge into the connected downstream node's input (read there via `inputFloats` /
        /// `inputFloat`). The write-side mirror of `inputFloats`. Call it every frame the value changes; a
        /// port with no downstream connection is simply dropped. No-op if the host didn't wire the channel.
        public func setOutputFloats(_ port: String, _ values: [Float]) {
            guard let fn = outputValueFn else { return }
            port.withCString { name in
                values.withUnsafeBufferPointer { fn(resolverContext, name, $0.baseAddress, Int32($0.count)) }
            }
        }

        /// Emit a single scalar for a named declared output port — the common single-float case.
        public func setOutputFloat(_ port: String, _ value: Float) { setOutputFloats(port, [value]) }

        /// The string value of a named `enum`/`string` input port (its unconnected default,
        /// live-overridable from the host). nil if unset. Grows + retries on truncation.
        public func inputString(_ port: String) -> String? {
            guard let fn = inputStringFn else { return nil }
            var capacity = 256
            while true {
                var buffer = [CChar](repeating: 0, count: capacity)
                let full = port.withCString { name in
                    buffer.withUnsafeMutableBufferPointer { fn(resolverContext, name, $0.baseAddress, Int32($0.count)) }
                }
                guard full > 0 else { return nil }
                if Int(full) > capacity { capacity = Int(full); continue }   // truncated → grow & retry
                return String(decoding: buffer.prefix(Int(full)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }

        /// Keep `object` alive until THIS frame's command buffer has executed on the GPU. Use it for
        /// anything a pool can recycle under the GPU — e.g. the CVMetalTexture + CVPixelBuffer behind
        /// a camera/video frame (see camera.macos). One call per object, every frame you sample it.
        /// No-op if the host didn't wire the channel.
        public func holdUntilFrameCompletes(_ object: AnyObject) {
            frameHoldFn?(resolverContext, Unmanaged.passRetained(object).toOpaque())
        }
    }

    /// The frozen node ABI. `setup`/`teardown` default to no-ops; a node implements `update`.
    /// `dynamicOptions` defaults to none — a node overrides it only to offer runtime-enumerated choices
    /// for an `enum` port (e.g. the live camera list); the host calls it for the editor dropdown + snapshot.
    public protocol SZNode {
        func setup(_ ctx: SZSetupContext)
        func update(_ ctx: SZFrameContext)
        func teardown()
        func dynamicOptions(for port: String) -> [SZEnumOption]
    }
    public extension SZNode {
        func setup(_ ctx: SZSetupContext) {}
        func teardown() {}
        func dynamicOptions(for port: String) -> [SZEnumOption] { [] }
    }

    // Holds the single live node instance for this dylib. Swift 5 mode (no strict concurrency).
    enum SZNodeHost {
        static var node: SZNode?
    }

    @_cdecl("SZPluginAPIVersion")
    public func SZPluginAPIVersion() -> Int32 { \(SZNodeABI.version) }

    @_cdecl("SZNodeSetup")
    public func SZNodeSetup(_ raw: UnsafeMutableRawPointer?) {
        let node = SZNodeMain.make()
        SZNodeHost.node = node
        if let ctx = SZSetupContext(raw) {
            node.setup(ctx)
        }
    }

    @_cdecl("SZNodeUpdate")
    public func SZNodeUpdate(_ raw: UnsafeMutableRawPointer?) -> Int32 {
        guard let node = SZNodeHost.node, let ctx = SZFrameContext(raw) else {
            return SZNodeStatus.failure
        }
        node.update(ctx)
        return SZNodeStatus.success
    }

    @_cdecl("SZNodeTeardown")
    public func SZNodeTeardown() {
        SZNodeHost.node?.teardown()
        SZNodeHost.node = nil
    }

    // The host asks the node for a port's dynamic enum options (v4). Uses the live instance if set up,
    // else a transient one (enumeration is stateless). Writes positional-pair JSON into `out` up to `cap`,
    // returns the full byte length so the host grows + retries on truncation.
    @_cdecl("SZNodeEnumerateOptions")
    public func SZNodeEnumerateOptions(_ port: UnsafePointer<CChar>?, _ out: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
        guard let port, let out else { return 0 }
        let node = SZNodeHost.node ?? SZNodeMain.make()
        let options = node.dynamicOptions(for: String(cString: port))
        guard !options.isEmpty else { return 0 }
        let pairs = options.map { [$0.label, $0.value] }
        guard let data = try? JSONSerialization.data(withJSONObject: pairs) else { return 0 }
        let bytes = [UInt8](data)
        let n = min(bytes.count, Int(cap))
        for i in 0..<n { out[i] = CChar(bitPattern: bytes[i]) }
        return Int32(bytes.count)
    }
    """
}
