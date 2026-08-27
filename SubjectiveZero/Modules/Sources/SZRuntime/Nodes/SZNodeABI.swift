// SPDX-License-Identifier: AGPL-3.0-only
// The frozen node ABI (host-owned, stable across all nodes — RUNTIME.md, BUILD_SPEC.md).
//
// The cross-`dlopen` contract is **C-ABI** (sidesteps Swift cross-module ABI fragility). The ergonomic
// `SZNode` protocol + typed contexts are *compiled into each node* from the host-owned
// `SZNodeKit.source` injected alongside the author's `Node.swift`. A node dylib exports
// four stable C symbols; the host dlsym's those and populates the raw context struct below.
//
// The context carries **declared input/output texture bindings**: the runtime doesn't hand the node one
// output texture, it hands a *resolver* (an opaque per-frame bindings object + two C function pointers)
// so the node fetches `inputTexture("input")` / `outputTexture("output")` by the port names in its
// contract. Texture handles cross as opaque pointers (recovered via `Unmanaged`). A third resolver fn
// is the scalar-input channel: it resolves a port name to its float value(s) (an unconnected input's
// default, live-overridable from the host) so a node reads e.g. `ctx.inputFloat("speed")` at runtime.
// Output channels mirror the input ones: floats (v5) and strings (v8) a node emits flow downstream.
// A fourth write channel carries no value: `reportError` (v9) tells the host why the node produced
// nothing this frame.
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

/// Emits a port's string output value (v8): the node hands the runtime `byteCount` UTF-8 bytes from `in`
/// for a named declared `string`/`enum` output port, which the runtime routes across a `.data` edge into a
/// downstream node's string input (read there via `inputString`). The write-side mirror of
/// `SZStringResolver`. Host-side, called node-side. `(resolverContext, portName, in, byteCount) -> Void`.
typealias SZOutputStringResolver = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Void

/// Reports why this node produced nothing (v9): `byteCount` UTF-8 bytes from `in`. No port name, because
/// this is about the node, not one of its ports. It describes one frame: the node re-reports while the
/// fault holds, and the first quiet frame clears it. Host-side, called node-side.
/// `(resolverContext, in, byteCount) -> Void`.
typealias SZReportErrorFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32) -> Void

enum SZNodeABI {
    /// Bumped on a breaking ABI change. The loader rejects a mismatch. v2 = binding-table context;
    /// v3 = scalar-input value channel; v4 = string-input channel; v5 = output value channel
    /// (a node's non-texture output flowing across a data edge to a downstream input); v6 = frame-lifetime
    /// hold (pin an object until the frame's command buffer completes — pooled capture buffers etc.);
    /// v7 = setPaused (the one transport event `update()` can't deliver, because pause means no more
    /// frames — so a node's self-driving resource can stop when the graph does); v8 = string output
    /// channel (a `string`/`enum` output flowing across a data edge, and host-readable — the learn key
    /// carrier for controller nodes); v9 = the node→host error channel (`reportError`), for a decode or
    /// pipeline failure the host cannot see from outside.
    static let version: Int32 = 9

    static let apiVersionSymbol = "SZPluginAPIVersion"
    static let setupSymbol = "SZNodeSetup"
    static let updateSymbol = "SZNodeUpdate"
    static let teardownSymbol = "SZNodeTeardown"
    /// Optional (v4): a node's dynamic enum options for a port. Absent on a node that has none.
    static let enumerateOptionsSymbol = "SZNodeEnumerateOptions"
    /// Optional (v7): the runtime paused/resumed. Absent on a node that owns nothing running on its own.
    static let setPausedSymbol = "SZNodeSetPaused"

    typealias APIVersionFn = @convention(c) () -> Int32
    typealias SetupFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias UpdateFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias TeardownFn = @convention(c) () -> Void
    /// `(portName, out, capacity) -> fullLength`: writes the port's options as positional-pair JSON
    /// (`[["label","value"],…]`) into `out`, returning the full byte length (grow + retry on truncation).
    typealias EnumerateOptionsFn = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int32) -> Int32
    /// `(paused)`: 1 = paused, 0 = running. No context — this isn't a frame, it's the transport moving.
    typealias SetPausedFn = @convention(c) (Int32) -> Void
}

/// The raw context struct passed across the C-ABI boundary. **Its layout must byte-match the copy inside
/// `SZNodeKit.source`** — both are compiled by the same `swiftc`, so identical field order/types ⇒
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
    var outputStringFn: SZOutputStringResolver?      // v8: string OUTPUT values (appended → layout-compatible)
    var reportErrorFn: SZReportErrorFn?              // v9: node→host fault reason (appended → layout-compatible)
}
