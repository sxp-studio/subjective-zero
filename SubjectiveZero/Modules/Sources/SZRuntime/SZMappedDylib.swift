// SPDX-License-Identifier: AGPL-3.0-only
// The one dlopen motion every plugin tier (node, step, card) shares: copy the built dylib to a
// unique path under `runtime-loads/` (so the canonical build artifact can be overwritten while the
// mapped copy stays live), `dlopen(RTLD_NOW|RTLD_LOCAL)`, check the ABI version symbol FIRST, then
// resolve what the tier needs. Any failure before the image served an instance unmaps it and
// unlinks the copy, so a throw never leaks a mapping. What happens at retirement is each tier's
// decision (`discard(dlclose:)`) — nodes unmap, steps and cards keep the image resident.
import Foundation

enum SZDylibLoadError: Error, CustomStringConvertible {
    case dlopenFailed(String)
    case missingSymbol(String)
    case apiMismatch(tier: String, found: Int32, expected: Int32)

    var description: String {
        switch self {
        case .dlopenFailed(let msg): "dlopen failed: \(msg)"
        case .missingSymbol(let name): "dylib is missing required symbol \(name)"
        case .apiMismatch(let tier, let found, let expected): "\(tier) ABI version \(found) != host \(expected)"
        }
    }
}

struct SZMappedDylib {
    let handle: UnsafeMutableRawPointer
    let copy: URL

    /// Copy → dlopen → `<versionSymbol>() == expected`. `prefix` names the copy (`node-`, `step-`,
    /// `card-`) so a runtime-loads dir reads at a glance.
    static func map(_ dylib: URL, into runtimeLoadsDir: URL, prefix: String,
                    versionSymbol: String, expected: Int32, tier: String) throws -> SZMappedDylib {
        let fm = FileManager.default
        try fm.createDirectory(at: runtimeLoadsDir, withIntermediateDirectories: true)
        let copy = runtimeLoadsDir.appending(path: "\(prefix)\(UUID().uuidString).dylib")
        try? fm.removeItem(at: copy)
        try fm.copyItem(at: dylib, to: copy)
        guard let handle = dlopen(copy.path, RTLD_NOW | RTLD_LOCAL) else {
            try? fm.removeItem(at: copy)
            // dlerror() is nullable — another subsystem's dl-call can clear it between our
            // failure and this read.
            throw SZDylibLoadError.dlopenFailed(dlerror().map { String(cString: $0) } ?? "unknown dlopen error")
        }
        let image = SZMappedDylib(handle: handle, copy: copy)
        let version: (@convention(c) () -> Int32) = try image.symbol(versionSymbol)
        let found = version()
        guard found == expected else {
            image.discard(dlclose: true)
            throw SZDylibLoadError.apiMismatch(tier: tier, found: found, expected: expected)
        }
        return image
    }

    /// A REQUIRED symbol as a C function pointer; missing → the image is discarded and the throw
    /// names the symbol.
    func symbol<F>(_ name: String) throws -> F {
        guard let sym = dlsym(handle, name) else {
            discard(dlclose: true)
            throw SZDylibLoadError.missingSymbol(name)
        }
        return unsafeBitCast(sym, to: F.self)
    }

    /// An OPTIONAL symbol — nil when the dylib doesn't export it (older authored source).
    func optionalSymbol<F>(_ name: String) -> F? {
        dlsym(handle, name).map { unsafeBitCast($0, to: F.self) }
    }

    /// Unlink the on-disk copy (the mapping survives unlink) and, for tiers that unmap, dlclose.
    func discard(dlclose shouldClose: Bool) {
        if shouldClose { dlclose(handle) }
        try? FileManager.default.removeItem(at: copy)
    }
}
