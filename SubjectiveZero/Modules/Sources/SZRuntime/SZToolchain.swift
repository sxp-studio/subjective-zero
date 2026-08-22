// SPDX-License-Identifier: AGPL-3.0-only
// Compiles an authored Swift file — a node's `Node.swift` or a decision step's `Step.swift` —
// into a signed, loadable dylib. One pipeline, two tiers: they differ only in the host-owned
// support source compiled alongside, the module-name prefix, and the product name.
//
// The essential compile pipeline: write the
// host-owned RuntimeSupport beside the node, `swiftc -emit-library`, then `codesign -s -` (ad-hoc
// signing is REQUIRED for `dlopen` on macOS). This compiles ONE node's source; the graph wiring lives
// elsewhere (topo order in `SZScheduler`, per-node loaders in `SZRuntime.loadGraph`). Still not
// built — added only when earned: a `CompileRequest`/file manifest and runtime contract validation
// (the node touches only its declared ports).
//
// Node artifacts are content-addressed per node dir, so an unchanged node never runs swiftc twice,
// across launches included. That is what makes opening a project fast.
import CryptoKit
import Foundation
import Synchronization

public struct SZToolchain {
    public init() {}

    /// The app-wide swiftc gate, shared by every tier that compiles off the main thread (steps,
    /// cards): a burst of schedules must not fan out into a compile storm — a swiftc storm has
    /// wedged a machine before. Static on purpose: every runtime instance (and every test in the
    /// process) shares the same slots. Synchronous by design: the semaphore wait must live in a
    /// sync frame, and the detached task that calls this is exactly the thread meant to park.
    private static let compileSlots = DispatchSemaphore(value: 4)
    public func gated<T>(_ body: () throws -> T) -> Result<T, Error> {
        Self.compileSlots.wait()
        defer { Self.compileSlots.signal() }
        return Result { try body() }
    }

    enum CompileError: Error, CustomStringConvertible {
        case sdkNotFound(log: String)
        case compileFailed(log: String)
        case signFailed(log: String)

        var description: String {
            switch self {
            case .sdkNotFound(let log): "macOS SDK not found via xcrun.\n\(log)"
            case .compileFailed(let log): "swiftc failed:\n\(log)"
            case .signFailed(let log): "codesign failed:\n\(log)"
            }
        }
    }

    /// Compile `nodeSource` into `Node.dylib` inside `buildDir` (created if needed) and ad-hoc sign it.
    func compile(nodeSource: URL, into buildDir: URL) throws -> URL {
        try compile(source: nodeSource, into: buildDir,
                    supportFileName: SZNodeKit.fileName, supportSource: SZNodeKit.source,
                    modulePrefix: "SZNode_", product: "Node.dylib", cached: true)
    }

    /// Compile a decision step's `Step.swift` into `Step.dylib` — same pipeline, SZStepKit
    /// as the support blob, its own module prefix.
    public func compile(stepSource: URL, into buildDir: URL) throws -> URL {
        try compile(source: stepSource, into: buildDir,
                    supportFileName: SZStepKit.fileName, supportSource: SZStepKit.source,
                    modulePrefix: "SZStep_", product: "Step.dylib", cached: false)
    }

    /// Compile a node's `Card.swift` into `Card.dylib` — same pipeline, SZCardKit as the support
    /// blob (SwiftUI/AppKit-linking, separate from the node kit on purpose), its own module prefix.
    public func compile(cardSource: URL, into buildDir: URL) throws -> URL {
        try compile(source: cardSource, into: buildDir,
                    supportFileName: SZCardKit.fileName, supportSource: SZCardKit.source,
                    modulePrefix: "SZCard_", product: "Card.dylib", cached: false)
    }

    /// The one pipeline all tiers share: write the host-owned support source beside the
    /// authored file, `swiftc -emit-library`, then `codesign -s -` (ad-hoc signing is
    /// REQUIRED for `dlopen` on macOS). Returns the dylib URL.
    ///
    /// `cached` is the NODE tier only, and two rules keep it safe:
    ///   - `buildDir` is per node, so the module name stays a fresh `UUID` per build and two nodes with
    ///     identical source never share mangled type metadata while co-resident.
    ///   - Steps and cards are NOT cached: neither ever `dlclose`s, so re-mapping one artifact would put
    ///     two images with one module name in the process.
    /// A cached build is staged and moved into place only once signed, so an interrupted compile leaves
    /// nothing half-built to be trusted later.
    private func compile(source: URL, into buildDir: URL, supportFileName: String,
                         supportSource: String, modulePrefix: String, product: String,
                         cached: Bool) throws -> URL {
        let fm = FileManager.default
        let key = cached ? try buildKey(source: source, supportSource: supportSource, product: product)
                         : ""
        let entry = cached ? buildDir.appending(path: key) : buildDir
        if cached, fm.fileExists(atPath: entry.appending(path: product).path) {
            return entry.appending(path: product)
        }

        // Stage: a build in progress must not be reachable under its final name.
        let staging = cached ? buildDir.appending(path: ".building-\(UUID().uuidString)") : buildDir
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { if cached { try? fm.removeItem(at: staging) } }
        let supportURL = staging.appending(path: supportFileName)
        try supportSource.write(to: supportURL, atomically: true, encoding: .utf8)

        let sdk = try Self.sdk()
        let moduleName = modulePrefix + UUID().uuidString.prefix(8)

        let staged = staging.appending(path: product)
        let build = try run("/usr/bin/xcrun", [
            "swiftc", "-emit-library",
            "-module-name", String(moduleName),
            "-sdk", sdk,
            "-o", staged.path,
            supportURL.path, source.path,
        ])
        guard build.status == 0 else { throw CompileError.compileFailed(log: build.combined) }

        // Ad-hoc sign in place (-f overwrites any stale signature). Required before dlopen.
        let sign = try run("/usr/bin/codesign", ["-s", "-", "-f", staged.path])
        guard sign.status == 0 else { throw CompileError.signFailed(log: sign.combined) }
        guard cached else { return staged }

        // Publish in one atomic move. Losing the race to another process is success: same key, same
        // bytes.
        try? fm.removeItem(at: entry)
        do { try fm.moveItem(at: staging, to: entry) } catch {
            guard fm.fileExists(atPath: entry.appending(path: product).path) else { throw error }
        }
        // One live artifact per node: the key that just built is the only one worth keeping.
        for stale in (try? fm.contentsOfDirectory(at: buildDir, includingPropertiesForKeys: nil)) ?? []
        where stale.lastPathComponent != key {
            try? fm.removeItem(at: stale)
        }
        return entry.appending(path: product)
    }

    /// The content key an artifact is filed under: everything that changes what swiftc would emit.
    private func buildKey(source: URL, supportSource: String, product: String) throws -> String {
        var hasher = SHA256()
        hasher.update(data: try Data(contentsOf: source))
        let toolchain = try Self.toolchain()
        for part in [supportSource, product, toolchain.sdk, toolchain.compiler, Self.formatSalt] {
            hasher.update(data: Data(part.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Bump by hand when the pipeline itself changes shape (flags, signing, layout) in a way the
    /// hashed inputs can't see. An ABI change rides the support source and needs no bump.
    private static let formatSalt = "1"

    /// Resolved once per process; `xcrun` was being spawned per node. A FAILURE is never memoized, or
    /// one transient `xcrun` would kill every compile until relaunch.
    private static let resolved = Mutex<(sdk: String, compiler: String)?>(nil)
    private static func toolchain() throws -> (sdk: String, compiler: String) {
        if let known = resolved.withLock({ $0 }) { return known }
        let probe = SZToolchain()
        let found = (sdk: try probe.resolveSDKPath(), compiler: probe.resolveCompilerVersion())
        resolved.withLock { $0 = found }
        return found
    }
    private static func sdk() throws -> String { try toolchain().sdk }

    /// In the key because the SDK path alone doesn't move for an Xcode point release or a `TOOLCHAINS`
    /// switch, which emit different code. Unreadable is its own key, not a failure.
    private func resolveCompilerVersion() -> String {
        ((try? run("/usr/bin/xcrun", ["swiftc", "--version"]))?.stdout ?? "unknown")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveSDKPath() throws -> String {
        let result = try run("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"])
        // Read stdout ONLY for the path. On macOS 26+, subprocesses launched from an Xcode-run app
        // inherit an environment that makes them spew `objc[...]: Class USK... implemented in both`
        // duplicate-class warnings to *stderr*; merging those into the path yields a multi-line blob
        // that swiftc rejects as a bogus `-sdk`. Defensively pick the line that is an absolute `.sdk`
        // path, falling back to the trimmed stdout.
        let lines = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let path = lines.last { $0.hasPrefix("/") && $0.hasSuffix(".sdk") }
            ?? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !path.isEmpty else { throw CompileError.sdkNotFound(log: result.combined) }
        return path
    }

    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        /// stdout + stderr for human-facing diagnostic logs (order: stdout first, then stderr).
        var combined: String {
            switch (stdout.isEmpty, stderr.isEmpty) {
            case (true, _): stderr
            case (_, true): stdout
            default: stdout + "\n" + stderr
            }
        }
    }

    /// Run a subprocess, capturing stdout and stderr SEPARATELY. Drains stderr on a background queue
    /// while draining stdout on this thread, so neither full pipe buffer can deadlock the other.
    private func run(_ launchPath: String, _ args: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()

        // Box lets the background stderr reader hand its Data back without mutating a captured var
        // (which trips Swift 6's Sendable-closure check).
        final class Box: @unchecked Sendable { var data = Data() }
        let errBox = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return RunResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errBox.data, as: UTF8.self))
    }
}
