// SPDX-License-Identifier: AGPL-3.0-only
// dlopen-based loader for a compiled node dylib. Holds one live node; on reload it tears down the
// old module, then sets up the new one (teardown-then-swap).
//
// Copy the dylib to a unique
// runtime-loads path (so the canonical build artifact can be overwritten while the previous copy
// stays mapped), `dlopen(RTLD_NOW|RTLD_LOCAL)`, dlsym the four C symbols, check the API version,
// then drive setup/update/teardown.
//
// Loading is split into two phases so the runtime can tear the OLD graph down *between* them
// (`SZRuntime.loadGraph`): `open` maps the dylib + resolves symbols WITHOUT running `setup()`, then
// `activate` runs `setup()`. A node that grabs an exclusive device in `setup()` (the camera's
// `AVCaptureSession`) must not start until the previous node holding that device has been torn down,
// or the two sessions contend and the new feed freezes. `load` keeps the one-shot open→setup
// swap for the single-loader path.
import Foundation
import SZCore

/// `@unchecked Sendable`: all mutation (open/load/unload) happens on the load paths, which run inside
/// the runtime's engine lock (or single-threaded tests); `enumerateOptions` is the one documented
/// concurrent READ (UI dropdown vs render thread) and touches only the immutable resolved symbols.
final class SZLoader: @unchecked Sendable {
    typealias LoadError = SZDylibLoadError

    private var handle: UnsafeMutableRawPointer?
    private var update: SZNodeABI.UpdateFn?
    private var teardownFn: SZNodeABI.TeardownFn?
    private var enumerateOptionsFn: SZNodeABI.EnumerateOptionsFn?
    private var setPausedFn: SZNodeABI.SetPausedFn?
    private var loadedCopy: URL?

    /// An `open`ed-but-not-yet-`activate`d module: the dylib is mapped + its symbols resolved, but
    /// `setup()` hasn't run, so it owns no devices yet. Held separately from the live module so the
    /// caller can tear the old live module down before activating this one.
    private struct Pending {
        let handle: UnsafeMutableRawPointer
        let setup: SZNodeABI.SetupFn
        let update: SZNodeABI.UpdateFn
        let teardown: SZNodeABI.TeardownFn
        let enumerateOptions: SZNodeABI.EnumerateOptionsFn?   // optional (v4)
        let setPaused: SZNodeABI.SetPausedFn?                 // optional (v7)
        let copy: URL
    }
    private var pending: Pending?

    /// True once a node module is loaded and set up (activated).
    var isLoaded: Bool { handle != nil }

    deinit { unload() }

    /// Phase 1: copy `dylib` to a unique path under `runtimeLoadsDir`, dlopen, verify the ABI version,
    /// and resolve symbols — but DO NOT run `setup()`. Stashed in `pending` until `activate`. Throwing
    /// here leaves any live module untouched (the runtime's atomic-failure property). Discards a prior
    /// un-activated pending first.
    func open(dylib: URL, runtimeLoadsDir: URL) throws {
        discardPending()
        let image = try SZMappedDylib.map(dylib, into: runtimeLoadsDir, prefix: "node-",
                                          versionSymbol: SZNodeABI.apiVersionSymbol,
                                          expected: SZNodeABI.version, tier: "node")
        // Optional symbols resolve without throwing; a node with no dynamic options simply won't
        // export them.
        pending = Pending(
            handle: image.handle,
            setup: try image.symbol(SZNodeABI.setupSymbol),
            update: try image.symbol(SZNodeABI.updateSymbol),
            teardown: try image.symbol(SZNodeABI.teardownSymbol),
            enumerateOptions: image.optionalSymbol(SZNodeABI.enumerateOptionsSymbol),
            setPaused: image.optionalSymbol(SZNodeABI.setPausedSymbol),
            copy: image.copy)
    }

    /// Phase 2: run the pending module's `setup(setupContext)` and install it as the live module. The
    /// caller is responsible for having torn down whatever previously held any device this `setup()`
    /// grabs. No-op if nothing is pending.
    func activate(setupContext: UnsafeMutableRawPointer?) {
        guard let p = pending else { return }
        pending = nil
        p.setup(setupContext)
        handle = p.handle
        update = p.update
        teardownFn = p.teardown
        enumerateOptionsFn = p.enumerateOptions
        setPausedFn = p.setPaused
        loadedCopy = p.copy
    }

    /// One-shot load (open → swap → activate) for the single-loader path: tear down this loader's own
    /// live module, then set up the new one. Multi-node reloads use `open`/`activate` directly so the
    /// runtime can tear ALL old nodes down before activating ANY new one.
    func load(dylib: URL, runtimeLoadsDir: URL, setupContext: UnsafeMutableRawPointer?) throws {
        try open(dylib: dylib, runtimeLoadsDir: runtimeLoadsDir)
        unloadLive()                              // tear down the old live module (keeps `pending`)
        activate(setupContext: setupContext)
    }

    /// Run one frame (`update`). Returns the node's status code, or failure (1) if nothing is loaded.
    @discardableResult
    func renderFrame(context: UnsafeMutableRawPointer?) -> Int32 {
        guard let update else { return 1 }
        return update(context)
    }

    /// Tell the live node the runtime paused / resumed (v7). No-op for a node that doesn't implement
    /// it — which is every node that owns nothing running on its own.
    func setPaused(_ paused: Bool) { setPausedFn?(paused ? 1 : 0) }

    /// Ask the live node for a port's dynamic enum options (v4) — the host's editor dropdown + snapshot
    /// source. Empty if the node has no dynamic options for `port` (or isn't activated). Grows + retries
    /// on truncation; parses the node's positional-pair JSON (`[["label","value"],…]`).
    func enumerateOptions(port: String) -> [SZEnumOption] {
        guard let fn = enumerateOptionsFn else { return [] }
        var capacity = 1024
        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let full = port.withCString { name in
                buffer.withUnsafeMutableBufferPointer { fn(name, $0.baseAddress, Int32($0.count)) }
            }
            guard full > 0 else { return [] }
            if Int(full) > capacity { capacity = Int(full); continue }
            let bytes = buffer.prefix(Int(full)).map { UInt8(bitPattern: $0) }
            guard let pairs = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [[String]] else { return [] }
            return pairs.compactMap { $0.count == 2 ? SZEnumOption(label: $0[0], value: $0[1]) : nil }
        }
    }

    /// Tear down the live node, dlclose, and delete its runtime copy. Also discards any un-activated
    /// pending module (so a loader opened but never activated — e.g. a reload that threw partway — frees
    /// its mapping + copy).
    func unload() {
        unloadLive()
        discardPending()
    }

    /// Tear down ONLY the live module (leaving any `pending` intact) — the swap step of `load`, where the
    /// freshly-`open`ed pending must survive the old module's teardown.
    private func unloadLive() {
        teardownFn?()
        if let handle { dlclose(handle) }
        if let loadedCopy { try? FileManager.default.removeItem(at: loadedCopy) }
        handle = nil
        update = nil
        teardownFn = nil
        enumerateOptionsFn = nil
        setPausedFn = nil
        loadedCopy = nil
    }

    /// Drop an `open`ed-but-not-`activate`d module without running its `setup()`/`teardown()` (it never
    /// ran setup, so there's nothing to tear down): dlclose + delete its copy.
    private func discardPending() {
        guard let p = pending else { return }
        pending = nil
        dlclose(p.handle)
        try? FileManager.default.removeItem(at: p.copy)
    }
}
