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
    enum LoadError: Error, CustomStringConvertible {
        case dlopenFailed(String)
        case missingSymbol(String)
        case apiMismatch(found: Int32, expected: Int32)

        var description: String {
            switch self {
            case .dlopenFailed(let msg): "dlopen failed: \(msg)"
            case .missingSymbol(let name): "node dylib is missing required symbol \(name)"
            case .apiMismatch(let found, let expected): "node ABI version \(found) != host \(expected)"
            }
        }
    }

    private var handle: UnsafeMutableRawPointer?
    private var update: SZNodeABI.UpdateFn?
    private var teardownFn: SZNodeABI.TeardownFn?
    private var enumerateOptionsFn: SZNodeABI.EnumerateOptionsFn?
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
        let fm = FileManager.default
        try fm.createDirectory(at: runtimeLoadsDir, withIntermediateDirectories: true)
        let copy = runtimeLoadsDir.appending(path: "node-\(UUID().uuidString).dylib")
        try? fm.removeItem(at: copy)
        try fm.copyItem(at: dylib, to: copy)

        guard let newHandle = dlopen(copy.path, RTLD_NOW | RTLD_LOCAL) else {
            try? fm.removeItem(at: copy)
            throw LoadError.dlopenFailed(String(cString: dlerror()))
        }

        func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
            guard let sym = dlsym(newHandle, name) else {
                dlclose(newHandle)
                try? fm.removeItem(at: copy)
                throw LoadError.missingSymbol(name)
            }
            return sym
        }

        let apiVersion = unsafeBitCast(try symbol(SZNodeABI.apiVersionSymbol), to: SZNodeABI.APIVersionFn.self)
        let found = apiVersion()
        guard found == SZNodeABI.version else {
            dlclose(newHandle)
            try? fm.removeItem(at: copy)
            throw LoadError.apiMismatch(found: found, expected: SZNodeABI.version)
        }

        // Optional — resolved without throwing; a node with no dynamic options simply won't export it.
        let enumerate = dlsym(newHandle, SZNodeABI.enumerateOptionsSymbol)
            .map { unsafeBitCast($0, to: SZNodeABI.EnumerateOptionsFn.self) }

        pending = Pending(
            handle: newHandle,
            setup: unsafeBitCast(try symbol(SZNodeABI.setupSymbol), to: SZNodeABI.SetupFn.self),
            update: unsafeBitCast(try symbol(SZNodeABI.updateSymbol), to: SZNodeABI.UpdateFn.self),
            teardown: unsafeBitCast(try symbol(SZNodeABI.teardownSymbol), to: SZNodeABI.TeardownFn.self),
            enumerateOptions: enumerate,
            copy: copy)
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
