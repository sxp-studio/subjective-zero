// SPDX-License-Identifier: AGPL-3.0-only
// Subprocess runner for spawning provider CLIs (claude, codex) and health checks.
//
// Swift-Concurrency-native (per Apple's Synchronization guidance: prefer concurrency, reach for a
// lock only when concurrency isn't feasible). Going async removed the need for any lock at all —
// output is accumulated inside one child task's *local* buffer (no shared mutable state), so there
// is no NSLock/Mutex/@unchecked Sendable and no DispatchSemaphore poll-loop. Structured pieces:
//   - output drain: `readabilityHandler` bridged to an `AsyncStream<Data>` (chunked, not byte-by-byte
//     AsyncBytes), collected by a child task;
//   - termination: `terminationHandler` bridged to an `AsyncStream` signal;
//   - timeouts: a task-group race against `Task.sleep` — a wall-clock deadline, and an optional
//     inactivity deadline that every output chunk pushes forward (the drain and the watchdog share one
//     atomic last-output timestamp; a plain counter, not a lock — see `SZActivityClock`);
//   - cancellation: `withTaskCancellationHandler` SIGTERMs the process.
// We signal by pid (Sendable Int32), never capturing the non-Sendable `Process` in a @Sendable
// closure.
import Foundation
import Synchronization

/// The outcome of one subprocess run. `exitCode` is 124 on timeout (matching `timeout(1)`).
public struct SZProcessResult: Sendable {
    public var exitCode: Int32
    public var output: String          // stdout + stderr, interleaved
    public var timedOut: Bool
    /// Signal number when the process died to an uncaught signal (killed/crashed) OUT FROM UNDER
    /// US — a plain `exitCode` can't tell `exit(9)` from SIGKILL. nil on normal exit and whenever
    /// the kill was ours: timeout (`timedOut` names that cause) or task cancellation (a user Stop
    /// is a choice, not a crash).
    public var uncaughtSignal: Int32?

    public init(exitCode: Int32, output: String, timedOut: Bool = false, uncaughtSignal: Int32? = nil) {
        self.exitCode = exitCode
        self.output = output
        self.timedOut = timedOut
        self.uncaughtSignal = uncaughtSignal
    }
}

/// Injectable so the orchestrator and providers can run against a stub in tests.
/// `input` is written to the child's stdin, which is then closed; nil wires stdin to /dev/null.
/// Either way the child sees EOF — never the app's inherited stdin, which may stay open forever
/// (a CLI that reads piped stdin to EOF, like `pi -p`, would block with zero output; verified
/// pi 0.80.6, 2026-07-12).
public protocol SZProcessRunning: Sendable {
    func run(
        _ launchPath: String,
        _ arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL?,
        input: Data?,
        timeout: TimeInterval?,
        inactivityTimeout: TimeInterval?,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> SZProcessResult
}

public extension SZProcessRunning {
    /// Source-compatible overload for a spawn with no inactivity bound (wall clock only).
    func run(
        _ launchPath: String,
        _ arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL?,
        input: Data?,
        timeout: TimeInterval?,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> SZProcessResult {
        try await run(launchPath, arguments, environment: environment,
                      currentDirectoryURL: currentDirectoryURL, input: input,
                      timeout: timeout, inactivityTimeout: nil, onOutput: onOutput)
    }

    /// Source-compatible overload for the common no-stdin spawn.
    func run(
        _ launchPath: String,
        _ arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL?,
        timeout: TimeInterval?,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> SZProcessResult {
        try await run(launchPath, arguments, environment: environment,
                      currentDirectoryURL: currentDirectoryURL, input: nil,
                      timeout: timeout, inactivityTimeout: nil, onOutput: onOutput)
    }
}

/// The production runner: launches a real `Process`, merges stdout+stderr, enforces `timeout`.
public struct SZSystemProcessRunner: SZProcessRunning {
    public init() {}

    public func run(
        _ launchPath: String,
        _ arguments: [String],
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        input: Data? = nil,
        timeout: TimeInterval? = nil,
        inactivityTimeout: TimeInterval? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> SZProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        }
        process.currentDirectoryURL = currentDirectoryURL

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // The child must always see stdin EOF (see SZProcessRunning). Payload → pipe written and
        // closed below; none → /dev/null. Never inherit.
        let stdinPipe: Pipe? = input.map { _ in Pipe() }
        if let stdinPipe {
            process.standardInput = stdinPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        // Bridge process termination to an AsyncStream signal *before* run() so we can't miss it.
        let (terminations, terminationFinish) = AsyncStream.makeStream(of: Void.self)
        process.terminationHandler = { _ in terminationFinish.finish() }

        do {
            try process.run()
        } catch {
            terminationFinish.finish()
            pipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        try? pipe.fileHandleForWriting.close()
        if let stdinPipe {
            // The parent's copy of the READ end must close after spawn — only the child may hold
            // it, or a child that exits without draining never breaks the pipe and a payload
            // larger than the pipe buffer would block this write before the timeout race below is
            // even armed. (Payloads today are tiny RPC lines; the close makes the seam safe for
            // callers that aren't.)
            try? stdinPipe.fileHandleForReading.close()
            // Write the payload then close, delivering EOF. Best-effort: a child that exits
            // without reading (crash, bad argv) breaks the pipe — that's its exit code's story.
            try? stdinPipe.fileHandleForWriting.write(contentsOf: input ?? Data())
            try? stdinPipe.fileHandleForWriting.close()
        }
        let pid = process.processIdentifier

        // Inactivity bound: `inactivityTimeout` seconds of SILENCE kills the turn, where every output
        // chunk pushes the deadline forward — an agent still streaming progress is alive by definition,
        // however long the turn runs. `timeout` stays the wall-clock cap for a CLI that wedges (or
        // streams) forever. The drain task sees every chunk, so it stamps the clock; the watchdog in
        // `awaitExit` sleeps to the stamped deadline.
        let activity: SZActivityClock? = inactivityTimeout != nil ? SZActivityClock() : nil
        let observedOutput: (@Sendable (String) -> Void)?
        if let activity {
            observedOutput = { chunk in activity.touch(); onOutput?(chunk) }
        } else {
            observedOutput = onOutput
        }

        // Drain stdout+stderr in its own task — a *local* buffer, so no synchronization. An explicit
        // Task (not `async let`) so the kill path below can bound and cancel it.
        let collectTask = Task { await Self.collect(pipe.fileHandleForReading, onOutput: observedOutput) }

        let timedOut = await Self.awaitExit(terminations, timeout: timeout,
                                            inactivityTimeout: inactivityTimeout, activity: activity, pid: pid)
        let cancelled = Task.isCancelled
        // On timeout the cancellation handler didn't fire; on cancel it only SIGTERM'd. Either way
        // SIGKILL so the process actually exits, the pipe reaches EOF (`collect` completes), and we
        // never read `terminationStatus` on a still-running task (which throws an NSException).
        if timedOut || cancelled { Self.signalProcessTree(pid, SIGKILL) }

        // The main process has exited (or been killed), so its buffered output drains in milliseconds.
        // But a descendant it spawned (codex forks the vendor binary; a killed tree can leak a fork that
        // outlived the snapshot) can inherit the pipe's write end and hold it open, so the read side may
        // never hit EOF. Bound the drain so `run()` ALWAYS returns — otherwise the dispatch task group
        // never completes and the run wedges with `isRunning` stuck true forever (the reported hang).
        let output = await Self.boundedDrain(collectTask, within: 3.0)
        let exitCode: Int32 = timedOut ? 124 : (process.isRunning ? -1 : process.terminationStatus)
        // `terminationStatus` is the signal number when the reason is `.uncaughtSignal`; not
        // meaningful when the kill was OURS — timeout or cancellation — or while somehow still
        // running. Excluding both keeps the field's contract ("the CLI died out from under us"):
        // a user Stop must never read as a crash.
        let uncaughtSignal: Int32? =
            (!timedOut && !cancelled && !process.isRunning && process.terminationReason == .uncaughtSignal)
            ? process.terminationStatus : nil
        return SZProcessResult(
            exitCode: exitCode,
            output: String(decoding: output, as: UTF8.self),
            timedOut: timedOut,
            uncaughtSignal: uncaughtSignal
        )
    }

    /// Signal `pid` AND every live descendant. The provider CLIs are wrappers (codex is a Node
    /// script that spawns the vendor binary as a grandchild), so signalling only the direct child
    /// orphans the process actually talking to the model — it keeps burning tokens after Stop.
    /// Foundation.Process can't put the child in its own process group (no `posix_spawn` attribute
    /// access, and parent-side `setpgid` fails post-exec), so this enumerates the tree via
    /// `proc_listchildpids` at signal time: collect breadth-first FIRST, then signal deepest-first
    /// so no still-live parent can respawn or reap into the gap. Inherently a snapshot — a process
    /// forking mid-kill can slip through; if that ever bites, the deeper fix is the posix_spawn +
    /// `POSIX_SPAWN_SETPGROUP` rewrite.
    static func signalProcessTree(_ pid: Int32, _ signal: Int32) {
        var pids = [pid]
        var index = 0
        while index < pids.count {
            pids.append(contentsOf: childPIDs(of: pids[index]))
            index += 1
        }
        for pid in pids.reversed() { kill(pid, signal) }
    }

    /// Direct live children of `pid`. `proc_listchildpids` returns the ENTRY count, unlike
    /// `proc_listpids`'s bytes — verified empirically (two sleeping children → 2).
    /// The fixed buffer bounds a pathological fork storm, not normal use.
    private static func childPIDs(of pid: Int32) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }
        return Array(buffer.prefix(Int(count))).filter { $0 > 0 }
    }

    /// Read the handle to EOF via `readabilityHandler` → `AsyncStream`, accumulating locally. Finishes on
    /// cancellation too (force-closing the stream), so a caller can bound the drain when the pipe may never
    /// reach EOF — an orphaned descendant that outlived the kill can hold the write end open forever.
    private static func collect(_ handle: FileHandle, onOutput: (@Sendable (String) -> Void)?) async -> Data {
        nonisolated(unsafe) var continuationRef: AsyncStream<Data>.Continuation?
        let chunks = AsyncStream<Data> { continuation in
            continuationRef = continuation   // set synchronously in the builder, before any await/cancel
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    fh.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
        var accumulated = Data()
        await withTaskCancellationHandler {
            for await chunk in chunks {
                accumulated.append(chunk)
                onOutput?(String(decoding: chunk, as: UTF8.self))
            }
        } onCancel: {
            handle.readabilityHandler = nil
            continuationRef?.finish()   // end the `for await` even if the pipe never hits EOF
        }
        return accumulated
    }

    /// Await the collect task, but no longer than `grace` seconds — used after the process has exited or
    /// been killed. If a leaked descendant keeps the pipe open, EOF never comes; without this bound the
    /// drain (and thus the whole run) would wedge with `isRunning` stuck true. A watchdog cancels the
    /// drain once the grace elapses (its cancellation handler force-finishes the stream), so `.value`
    /// resolves promptly with whatever was accumulated.
    private static func boundedDrain(_ collectTask: Task<Data, Never>, within grace: TimeInterval) async -> Data {
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(grace))
            collectTask.cancel()
        }
        let output = await collectTask.value   // resolves naturally, or when the watchdog cancels it
        watchdog.cancel()
        return output
    }

    /// Wait for the process to exit, returning `true` if either deadline — wall clock, or silence past
    /// `inactivityTimeout` — won the race. SIGTERMs on cancel.
    private static func awaitExit(_ terminations: AsyncStream<Void>, timeout: TimeInterval?,
                                  inactivityTimeout: TimeInterval? = nil, activity: SZActivityClock? = nil,
                                  pid: Int32) async -> Bool {
        await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await _ in terminations {}   // finishes when terminationHandler fires
                    return false
                }
                if let timeout {
                    group.addTask {
                        do { try await Task.sleep(for: .seconds(timeout)); return true }
                        catch { return false }       // cancelled because the process exited first
                    }
                }
                if let inactivityTimeout, let activity {
                    group.addTask {
                        // Sleep to the CURRENT silence deadline. A chunk that lands while we sleep moves
                        // the deadline, so on wake either it moved (loop and sleep again) or the window
                        // truly elapsed in silence.
                        while true {
                            let deadline = activity.lastActivity.advanced(by: .seconds(inactivityTimeout))
                            if ContinuousClock.now >= deadline { return true }
                            do { try await Task.sleep(until: deadline, clock: .continuous) }
                            catch { return false }   // cancelled because the process exited first
                        }
                    }
                }
                let timedOut = await group.next() ?? false
                group.cancelAll()
                return timedOut
            }
        } onCancel: {
            signalProcessTree(pid, SIGTERM)
        }
    }
}

/// The one shared datum between the output drain (writer) and the inactivity watchdog (reader): when
/// output last arrived. A single atomic timestamp — not a lock, and not shared *mutable structure* —
/// because the two sides never need mutual exclusion, only a coherent read of "how fresh".
/// Stored as nanoseconds since the clock's creation so it fits an `Atomic<UInt64>`.
private final class SZActivityClock: Sendable {
    private let start = ContinuousClock.now
    private let sinceStartNanos = Atomic<UInt64>(0)

    /// Stamp "output arrived now" — pushes the watchdog's deadline forward.
    func touch() {
        let elapsed = (ContinuousClock.now - start).components
        let nanos = UInt64(elapsed.seconds) &* 1_000_000_000 &+ UInt64(elapsed.attoseconds / 1_000_000_000)
        sinceStartNanos.store(nanos, ordering: .relaxed)
    }

    /// The spawn instant until the first chunk, then the latest chunk's instant.
    var lastActivity: ContinuousClock.Instant {
        start.advanced(by: .nanoseconds(Int64(sinceStartNanos.load(ordering: .relaxed))))
    }
}

/// Launch environment for provider CLIs. `executable` is `/usr/bin/env` and the CLIs sit off a
/// minimal inherited PATH (claude in ~/.local/bin, codex under ~/.nvm/.../bin), so we build a PATH
/// that finds them. Public because the host's Terminal login launcher exports this same PATH —
/// the login shell must resolve the CLI exactly the way the app launches it.
public enum SZAgentEnvironment {
    /// Base env with an augmented PATH; `extra` overrides/extends (e.g. module-cache vars).
    static func base(extra: [String: String] = [:]) -> [String: String] {
        var env = ["PATH": searchPath()]
        for (k, v) in extra { env[k] = v }
        return env
    }

    public static func searchPath(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> String {
        // Verification hook: replace the whole synthesized path. Lets a provider-less machine
        // (`SZ_PATH_OVERRIDE=/usr/bin:/bin`) or a shim-CLI dir be simulated for the setup sheet
        // and the `--verify-agent-providers` self-check (docs/AI_PROVIDERS.md).
        if let override = processEnvironment["SZ_PATH_OVERRIDE"], !override.isEmpty {
            return override
        }
        var paths: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty, seen.insert(p).inserted else { return }
            paths.append(p)
        }
        processEnvironment["PATH"]?.split(separator: ":", omittingEmptySubsequences: true).forEach { add(String($0)) }
        add(processEnvironment["NVM_BIN"] ?? "")
        let home = homeDirectory.path
        // `.opencode/bin` is where opencode's official installer drops its CLI — the installer only
        // adds it to the interactive shell profile, so a windowless app launch wouldn't see it.
        [".local/bin", ".cargo/bin", ".bun/bin", ".opencode/bin"].forEach { add(URL(fileURLWithPath: home).appending(path: $0).path) }
        nodeVersionBinDirectories(homeDirectory: homeDirectory, fileManager: fileManager).forEach { add($0.path) }
        ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"].forEach(add)
        // Codex ships its CLI inside Codex.app — support users who installed the app, not the npm/standalone CLI.
        for apps in ["/Applications", URL(fileURLWithPath: home).appending(path: "Applications").path] {
            let resources = apps + "/Codex.app/Contents/Resources"
            if fileManager.isExecutableFile(atPath: resources + "/codex") { add(resources) }
        }
        ["/usr/bin", "/bin", "/usr/sbin", "/sbin"].forEach(add)
        return paths.joined(separator: ":")
    }

    /// Where `/usr/bin/env <name>` would find the CLI — the setup sheet's path line and the
    /// verifier's `cliPath`. Same walk env does, over the same synthesized PATH.
    static func resolveExecutable(
        _ name: String,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        for dir in searchPath(processEnvironment: processEnvironment).split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appending(path: name).path
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func nodeVersionBinDirectories(homeDirectory: URL, fileManager: FileManager) -> [URL] {
        let versions = homeDirectory.appending(path: ".nvm").appending(path: "versions").appending(path: "node")
        guard let entries = try? fileManager.contentsOfDirectory(
            at: versions, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .map { $0.appending(path: "bin") }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }
}
