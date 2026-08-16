// SPDX-License-Identifier: AGPL-3.0-only
// The card plugin ABI: a runtime-compiled `Card.swift` (beside a node's `Node.swift`) yields a
// SwiftUI-backed NSView the editor mounts as that node's card body. Separate from the node ABI
// (SZNode.swift) on purpose — cards link SwiftUI/AppKit while nodes link Metal, and the frozen
// node ABI must not absorb UI churn.
//
// Boundary rules (why each type below is shaped the way it is): system-framework types
// (SwiftUI/AppKit) exist ONCE per process and are shared with every dylib; ObjC classes (NSView)
// have runtime-global identity; types defined in the support source are duplicated per dylib
// module and must NEVER cross the boundary. So the crossing surface is only C function pointers,
// opaque Unmanaged pointers, and the byte-mirrored struct below (same-toolchain ⇒ identical
// layout — the same accepted constraint as SZRuntimeContextRaw). The card hands its view across
// as an opaque NSView pointer, not a SwiftUI value: everything dylib-defined stays behind one
// AppKit object whose lifetime the host controls (unmount → release → retire).
import Foundation

// Host-side verbs a card invokes; `hostContext` is the host's opaque box, borrowed for the
// instance's lifetime. Signatures are shared by both sides of the boundary.
typealias SZCardEmitFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<Float>?, Int32) -> Void
typealias SZCardSizeFn = @convention(c) (UnsafeMutableRawPointer?, Float) -> Void

/// The frozen contract between the host and a compiled card dylib. Version bumps on ANY change to
/// the symbols, their signatures, or `SZCardHostRaw`'s layout (append-only, like the node ABI).
/// All five entry points are main-thread calls by contract (the dylib asserts via
/// `MainActor.assumeIsolated`).
enum SZCardABI {
    static let version: Int32 = 1

    static let apiVersionSymbol = "SZCardAPIVersion"
    static let createSymbol = "SZCardCreate"
    static let viewSymbol = "SZCardView"
    static let updateSymbol = "SZCardUpdate"
    static let destroySymbol = "SZCardDestroy"

    typealias APIVersionFn = @convention(c) () -> Int32
    /// Pointer to `SZCardHostRaw` (copied by value inside) → +1 retained opaque instance, nil on
    /// version mismatch.
    typealias CreateFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    /// Instance → +0 borrowed opaque NSView (owned by the instance; valid until destroy).
    typealias ViewFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    /// (instance, channel cstring, JSON bytes, length). Channels: "state" (scoped node snapshot),
    /// "telemetry" (lossy display stream).
    typealias UpdateFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<UInt8>?, Int32) -> Void
    /// Consumes the +1 from create.
    typealias DestroyFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
}

/// Host→card context handed to `SZCardCreate`, copied by value inside the dylib. Byte-mirrored in
/// `SZCardKit.source`; fields are APPEND-ONLY (layout pinned by SZABILayoutTests).
struct SZCardHostRaw {
    var apiVersion: Int32 = SZCardABI.version
    /// Opaque host box, unretained borrow — the host guarantees it outlives the instance.
    var hostContext: UnsafeMutableRawPointer?
    /// Continuous gesture stream (port, floats): runtime-only, never the store.
    var liveFn: SZCardEmitFn?
    /// Gesture-end write (port, floats): one store commit per gesture.
    var commitFn: SZCardEmitFn?
    /// Measured intrinsic content height in points (auto-size rows).
    var sizeFn: SZCardSizeFn?
}
