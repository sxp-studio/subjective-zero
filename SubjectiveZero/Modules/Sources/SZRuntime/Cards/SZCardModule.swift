// SPDX-License-Identifier: AGPL-3.0-only
// One compiled card dylib and its live instances — the card tier's loader + public face in one
// place. Compile off-main (gated by the toolchain's shared swiftc slots), map with the shared
// dlopen motion (`SZMappedDylib`), mint instances that speak Swift closures, hand each card's
// view out as an opaque pointer (SZRuntime links no UI framework: callers recover it with
// `Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue() as? NSView`).
//
// A retired module is never dlclosed (SZStepLoader's Darwin finding; SwiftUI's attribute graph
// may still hold references into it) — `unload()` destroys the remaining instances and unlinks the
// on-disk copy; co-residency safety is the unique module name per build. Hot reload is caller-
// orchestrated: build a fresh module, remount, then unload the old one once its views left the
// hierarchy. All main-thread by the ABI's contract.
import Foundation
import SZCore

@MainActor
public final class SZCardModule {
    private let image: SZMappedDylib
    private let create: SZCardABI.CreateFn
    private let view: SZCardABI.ViewFn
    private let update: SZCardABI.UpdateFn
    private let destroy: SZCardABI.DestroyFn
    private var instances: [SZCardInstance] = []

    private init(image: SZMappedDylib) throws {
        self.image = image
        create = try image.symbol(SZCardABI.createSymbol)
        view = try image.symbol(SZCardABI.viewSymbol)
        update = try image.symbol(SZCardABI.updateSymbol)
        destroy = try image.symbol(SZCardABI.destroySymbol)
    }

    /// Compile `source` (a Card.swift) into `<workspace>/cards/<artifact>/build`, off-main and
    /// slot-gated, then map it. Throws SZToolchain.CompileError (swiftc log inside) or
    /// SZDylibLoadError.
    public static func build(source: URL, artifact: String, workspace: URL) async throws -> SZCardModule {
        let toolchain = SZToolchain()
        let buildDir = workspace.appending(path: "cards/\(artifact)/build")
        let dylib = try await Task.detached(priority: .userInitiated) {
            try toolchain.gated { try toolchain.compile(cardSource: source, into: buildDir) }.get()
        }.value
        let image = try SZMappedDylib.map(dylib, into: workspace.appending(path: "cards/\(artifact)/runtime-loads"),
                                          prefix: "card-", versionSymbol: SZCardABI.apiVersionSymbol,
                                          expected: SZCardABI.version, tier: "card")
        return try SZCardModule(image: image)
    }

    /// Compile-check a Card.swift without mapping it — the card half of `agent_compile_node`.
    /// Slot-gated like every other compile; the scratch build is removed after. Callable off-main.
    public nonisolated static func compileCheck(source: URL, workspace: URL) -> SZBuildResult {
        let toolchain = SZToolchain()
        let scratch = workspace.appending(path: "cards/check/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        switch toolchain.gated({ try toolchain.compile(cardSource: source, into: scratch) }) {
        case .success: return .ok
        case .failure(let error): return .failed(String(describing: error))
        }
    }

    /// Mint a live instance wired to `verbs`. Nil if the dylib refused (version guard).
    public func createInstance(verbs: SZCardVerbs) -> SZCardInstance? {
        let box = SZCardVerbBox(verbs)
        var raw = SZCardHostRaw()
        raw.hostContext = Unmanaged.passUnretained(box).toOpaque()
        raw.liveFn = szCardLive
        raw.commitFn = szCardCommit
        raw.sizeFn = szCardSize
        raw.callFn = szCardCall
        guard let pointer = withUnsafeMutablePointer(to: &raw, { create(UnsafeMutableRawPointer($0)) }) else { return nil }
        let instance = SZCardInstance(pointer: pointer, view: view, update: update, destroy: destroy, box: box)
        instances.removeAll { !$0.isLive }
        instances.append(instance)
        return instance
    }

    /// Destroy the remaining instances and unlink the copy (the mapping stays resident). Call only
    /// after the module's views left the view hierarchy.
    public func unload() {
        for instance in instances { instance.destroy() }
        instances.removeAll()
        image.discard(dlclose: false)
    }
}

/// A live card instance behind opaque pointers. Retains the verb box the dylib's function
/// pointers dereference, so the box can't outlive-or-underlive the instance.
@MainActor
public final class SZCardInstance {
    private var pointer: UnsafeMutableRawPointer?
    private let view: SZCardABI.ViewFn
    private let update: SZCardABI.UpdateFn
    private let destroyFn: SZCardABI.DestroyFn
    private let box: SZCardVerbBox

    fileprivate init(pointer: UnsafeMutableRawPointer, view: @escaping SZCardABI.ViewFn,
                     update: @escaping SZCardABI.UpdateFn, destroy: @escaping SZCardABI.DestroyFn,
                     box: SZCardVerbBox) {
        self.pointer = pointer
        self.view = view
        self.update = update
        self.destroyFn = destroy
        self.box = box
    }

    var isLive: Bool { pointer != nil }

    /// +0 borrowed opaque NSView pointer, valid until `destroy()`.
    public func viewPointer() -> UnsafeMutableRawPointer? {
        guard let pointer else { return nil }
        return view(pointer)
    }

    /// Push a JSON payload down a channel: "state" (scoped node snapshot) or "telemetry" (lossy).
    public func push(channel: String, json: Data) {
        guard let pointer else { return }
        channel.withCString { name in
            json.withUnsafeBytes { bytes in
                update(pointer, name, bytes.bindMemory(to: UInt8.self).baseAddress, Int32(json.count))
            }
        }
    }

    /// Idempotent; consumes the instance (its view pointer dies with it).
    public func destroy() {
        guard let pointer else { return }
        self.pointer = nil
        destroyFn(pointer)
    }
}

/// The card's outbound verb surface, as plain Swift closures. All invoked on the main actor.
public struct SZCardVerbs {
    /// Continuous gesture stream (port, values): runtime-only, never the store.
    public var live: (String, [Float]) -> Void
    /// Gesture-end write (port, values): one store commit per gesture.
    public var commit: (String, [Float]) -> Void
    /// Measured intrinsic content height in points.
    public var size: (Double) -> Void
    /// Named host verb (tool, argsJSON) — the host allowlists per node kind.
    public var call: (String, String) -> Void

    public init(live: @escaping (String, [Float]) -> Void = { _, _ in },
                commit: @escaping (String, [Float]) -> Void = { _, _ in },
                size: @escaping (Double) -> Void = { _ in },
                call: @escaping (String, String) -> Void = { _, _ in }) {
        self.live = live
        self.commit = commit
        self.size = size
        self.call = call
    }
}

// MARK: - closure ↔ C bridge

/// `hostContext` points here. The C fns below are captureless by necessity — the box carries the
/// closures across. `@MainActor` isolates the closures to the thread the ABI promises AND makes the
/// box Sendable, so the nonisolated C entry can hand it into `assumeIsolated`.
@MainActor
final class SZCardVerbBox {
    let verbs: SZCardVerbs
    init(_ verbs: SZCardVerbs) { self.verbs = verbs }
    nonisolated static func from(_ ctx: UnsafeMutableRawPointer?) -> SZCardVerbBox? {
        ctx.map { Unmanaged<SZCardVerbBox>.fromOpaque($0).takeUnretainedValue() }
    }
}

private let szCardLive: SZCardEmitFn = { ctx, port, values, count in
    guard let box = SZCardVerbBox.from(ctx), let port, let values else { return }
    let floats = Array(UnsafeBufferPointer(start: values, count: Int(count)))
    let name = String(cString: port)
    MainActor.assumeIsolated { box.verbs.live(name, floats) }
}

private let szCardCommit: SZCardEmitFn = { ctx, port, values, count in
    guard let box = SZCardVerbBox.from(ctx), let port, let values else { return }
    let floats = Array(UnsafeBufferPointer(start: values, count: Int(count)))
    let name = String(cString: port)
    MainActor.assumeIsolated { box.verbs.commit(name, floats) }
}

private let szCardSize: SZCardSizeFn = { ctx, height in
    guard let box = SZCardVerbBox.from(ctx) else { return }
    let h = Double(height)
    MainActor.assumeIsolated { box.verbs.size(h) }
}

private let szCardCall: SZCardCallFn = { ctx, tool, args in
    guard let box = SZCardVerbBox.from(ctx), let tool else { return }
    let name = String(cString: tool)
    let json = args.map { String(cString: $0) } ?? "{}"
    MainActor.assumeIsolated { box.verbs.call(name, json) }
}
