// SPDX-License-Identifier: AGPL-3.0-only
// Compiles an authored Swift file — a node's `Node.swift` or a decision step's `Step.swift` —
// into a signed, loadable dylib. One pipeline, two tiers: they differ only in the host-owned
// support source compiled alongside, the module-name prefix, and the product name.
//
// The essential compile pipeline: write the
// host-owned RuntimeSupport beside the node, `swiftc -emit-library`, then `codesign -s -` (ad-hoc
// signing is REQUIRED for `dlopen` on macOS). This compiles ONE node's source; the graph wiring lives
// elsewhere (topo order in `SZScheduler`, per-node loaders in `SZRuntime.loadGraph`). Still not
// built — added only when earned: a `CompileRequest`/file manifest, runtime contract validation (the
// node touches only its declared ports), and rebuild-staleness (we recompile all nodes on reload,
// fine for the current graph sizes).
import Foundation

public struct SZToolchain {
    public init() {}

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
                    supportFileName: SZRuntimeSupport.fileName, supportSource: SZRuntimeSupport.source,
                    modulePrefix: "SZNode_", product: "Node.dylib")
    }

    /// Compile a decision step's `Step.swift` into `Step.dylib` — same pipeline, the step
    /// SDK as the support blob, its own module prefix.
    public func compile(stepSource: URL, into buildDir: URL) throws -> URL {
        try compile(source: stepSource, into: buildDir,
                    supportFileName: SZStepSDK.fileName, supportSource: SZStepSDK.source,
                    modulePrefix: "SZStep_", product: "Step.dylib")
    }

    /// The one pipeline both tiers share: write the host-owned support source beside the
    /// authored file, `swiftc -emit-library`, then `codesign -s -` (ad-hoc signing is
    /// REQUIRED for `dlopen` on macOS). Returns the dylib URL. A fresh, unique Swift module
    /// name per build keeps mangled type metadata from colliding when an old + new dylib are
    /// briefly co-resident during hot reload.
    private func compile(source: URL, into buildDir: URL, supportFileName: String,
                         supportSource: String, modulePrefix: String, product: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let supportURL = buildDir.appending(path: supportFileName)
        try supportSource.write(to: supportURL, atomically: true, encoding: .utf8)

        let sdk = try sdkPath()
        let dylib = buildDir.appending(path: product)
        let moduleName = modulePrefix + UUID().uuidString.prefix(8)

        let build = try run("/usr/bin/xcrun", [
            "swiftc", "-emit-library",
            "-module-name", String(moduleName),
            "-sdk", sdk,
            "-o", dylib.path,
            supportURL.path, source.path,
        ])
        guard build.status == 0 else { throw CompileError.compileFailed(log: build.combined) }

        // Ad-hoc sign in place (-f overwrites any stale signature). Required before dlopen.
        let sign = try run("/usr/bin/codesign", ["-s", "-", "-f", dylib.path])
        guard sign.status == 0 else { throw CompileError.signFailed(log: sign.combined) }

        return dylib
    }

    private func sdkPath() throws -> String {
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
