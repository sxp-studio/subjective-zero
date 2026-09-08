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

/// Whether this Mac can compile at all: Apple's developer tools (the Xcode Command Line Tools or
/// Xcode) present with a swiftc and a macOS SDK, or not.
public enum SZToolchainAvailability: Equatable, Sendable {
    case ready(developerDir: String)
    case missing
}

public struct SZToolchain {
    /// Where a release bundle keeps its prebuilt step dylibs (Contents/PlugIns). nil, or a
    /// directory that does not exist, means every step compiles.
    public let prebuiltStepsDir: URL?

    public init(prebuiltStepsDir: URL? = nil) {
        self.prebuiltStepsDir = prebuiltStepsDir
    }

    // MARK: - Availability

    /// Filesystem only: never runs xcrun or a /usr/bin tool shim, which would open Apple's
    /// install dialog on a Mac without the tools. Never cached, so a re-check sees an install land.
    public static func availability(
        developerDir: () -> String? = { activeDeveloperDir() },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> SZToolchainAvailability {
        guard let dir = developerDir(), !dir.isEmpty, fileExists(dir) else { return .missing }
        // Command Line Tools layout, then Xcode's.
        let compilers = ["\(dir)/usr/bin/swiftc",
                         "\(dir)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"]
        let sdks = ["\(dir)/SDKs/MacOSX.sdk",
                    "\(dir)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"]
        guard compilers.contains(where: fileExists), sdks.contains(where: fileExists) else { return .missing }
        return .ready(developerDir: dir)
    }

    /// The active developer directory: `DEVELOPER_DIR` when set, else what `xcode-select -p`
    /// prints. `xcode-select -p` exits 2 with an error on a clean Mac and opens no dialog; only
    /// the tool shims and `--install` do.
    public static func activeDeveloperDir(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let dir = environment["DEVELOPER_DIR"], !dir.isEmpty { return dir }
        guard let result = try? SZToolchain().run("/usr/bin/xcode-select", ["-p"]), result.status == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Open Apple's Command Line Tools installer. The dialog belongs to the system; the caller
    /// re-probes to learn the outcome.
    public static func openInstallDialog() {
        _ = try? SZToolchain().run("/usr/bin/xcode-select", ["--install"])
    }

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
        case lipoFailed(log: String)

        /// What a user reads if a compile still runs with the tools gone.
        static let toolsMissingMessage =
            "Apple's developer tools are not installed. Install the Xcode Command Line Tools, then build again."

        var description: String {
            switch self {
            case .sdkNotFound(let log): "\(Self.toolsMissingMessage)\n\(log)"
            case .compileFailed(let log): "swiftc failed:\n\(log)"
            case .signFailed(let log): "codesign failed:\n\(log)"
            case .lipoFailed(let log): "lipo failed:\n\(log)"
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
        try swiftc(moduleName: moduleName, sdk: sdk, output: staged, sources: [supportURL, source], target: nil)
        try adHocSign(staged)
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

    /// The one swiftc invocation, shared by the runtime compile and the release prebuild so the
    /// flag lists cannot drift; `target` is the only difference between them.
    private func swiftc(moduleName: String, sdk: String, output: URL, sources: [URL], target: String?) throws {
        var arguments = ["swiftc", "-emit-library", "-module-name", moduleName, "-sdk", sdk]
        if let target { arguments += ["-target", target] }
        arguments += ["-o", output.path] + sources.map(\.path)
        let build = try run("/usr/bin/xcrun", arguments)
        guard build.status == 0 else { throw CompileError.compileFailed(log: build.combined) }
    }

    /// Ad-hoc sign in place (-f overwrites any stale signature). Required before dlopen.
    private func adHocSign(_ dylib: URL) throws {
        let sign = try run("/usr/bin/codesign", ["-s", "-", "-f", dylib.path])
        guard sign.status == 0 else { throw CompileError.signFailed(log: sign.combined) }
    }

    // MARK: - Prebuilt steps

    /// The slices a shipped step is built for: both Mac architectures, pinned to the app's
    /// minimum macOS so a kit API newer than that fails at release time, not at a user's dlopen.
    public static let prebuiltStepTargets = ["arm64-apple-macos15.0", "x86_64-apple-macos15.0"]
    /// Bump when the prebuild pipeline changes shape in a way the hashed inputs cannot see.
    private static let prebuiltFormatSalt = "1"

    /// A shipped step's artifact name: a hash of every input that changes what swiftc emits, minus
    /// the compiler itself (a user's Mac has none). Agent and step are in the key so two steps with
    /// identical source never share a module.
    public static func prebuiltStepArtifactName(key: SZStepKey, source: Data) -> String {
        prebuiltStepArtifactName(key: key, source: source, kit: SZStepKit.source, abi: SZStepABI.version,
                                 targets: prebuiltStepTargets, salt: prebuiltFormatSalt)
    }

    static func prebuiltStepArtifactName(key: SZStepKey, source: Data, kit: String, abi: Int32,
                                         targets: [String], salt: String) -> String {
        var hasher = SHA256()
        hasher.update(data: source)
        for part in [key.agent, key.step, kit, "\(abi)", "Step.dylib", targets.joined(separator: ","), salt] {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "SZStep-\(key.agent)-\(key.step)-\(hex).dylib"
    }

    /// The bundled artifact for exactly these source bytes, or nil: an edited step, a dev build,
    /// or a stale bundle all compile instead.
    public func prebuiltStep(key: SZStepKey, source: URL) -> URL? {
        guard let dir = prebuiltStepsDir, let bytes = try? Data(contentsOf: source) else { return nil }
        let candidate = dir.appending(path: Self.prebuiltStepArtifactName(key: key, source: bytes))
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// True when `dylib` is one of the bundle's prebuilt artifacts.
    public func isPrebuilt(_ dylib: URL) -> Bool {
        guard let dir = prebuiltStepsDir else { return false }
        return dylib.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path + "/")
    }

    /// Build one shipped step for every slice in `prebuiltStepTargets`, join them with lipo, ad-hoc
    /// sign, and publish as `outDir/<artifact name>` (replacing an earlier file of that name).
    /// The release script re-signs the result with the Developer ID.
    public func prebuildStep(key: SZStepKey, source: URL, into outDir: URL) throws -> URL {
        let fm = FileManager.default
        let bytes = try Data(contentsOf: source)
        let name = Self.prebuiltStepArtifactName(key: key, source: bytes)
        let staging = outDir.appending(path: ".prebuilding-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let supportURL = staging.appending(path: SZStepKit.fileName)
        try SZStepKit.source.write(to: supportURL, atomically: true, encoding: .utf8)

        let sdk = try Self.sdk()
        let moduleName = "SZStep_" + UUID().uuidString.prefix(8)
        var slices: [URL] = []
        for target in Self.prebuiltStepTargets {
            let slice = staging.appending(path: "\(target)/Step.dylib")
            try fm.createDirectory(at: slice.deletingLastPathComponent(), withIntermediateDirectories: true)
            try swiftc(moduleName: String(moduleName), sdk: sdk, output: slice,
                       sources: [supportURL, source], target: target)
            slices.append(slice)
        }
        let joined = staging.appending(path: name)
        let lipo = try run("/usr/bin/lipo", ["-create"] + slices.map(\.path) + ["-output", joined.path])
        guard lipo.status == 0 else { throw CompileError.lipoFailed(log: lipo.combined) }
        try adHocSign(joined)

        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let published = outDir.appending(path: name)
        try? fm.removeItem(at: published)
        try fm.moveItem(at: joined, to: published)
        return published
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
