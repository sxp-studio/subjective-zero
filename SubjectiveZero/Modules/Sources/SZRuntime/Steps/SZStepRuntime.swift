// SPDX-License-Identifier: AGPL-3.0-only
// The keyed execution tier over `SZStepLoader`: one table of loaded decision steps, keyed by
// OWNER + STEP. The owner is part of the key on purpose — two agents may each ship a step of
// the same name, and a bare-name table would let whichever compile finished last answer for
// both.
//
// What this tier adds over a bare loader:
// - SCHEDULED COMPILES: `scheduleLoad` runs swiftc off-main and swaps the module in on green;
//   a red compile keeps the previous module answering (the loader's keep-old-on-red, surfaced
//   through `onRedCompile` so the failure lands somewhere a user actually looks). Schedules
//   for a key already compiling COALESCE — the latest source is remembered and compiled once
//   more after the in-flight build finishes, so the newest source always ends up live.
// - COMPILE SLOTS: a shared semaphore caps concurrent swiftc invocations app-wide for the
//   step tier. Without it, parallel schedulers (or parallel test processes) each spawning
//   their own compiles have wedged a machine before — a swiftc storm is a documented failure,
//   not a hypothetical.
// - EVALUATE AWAITS THE COMPILE: `evaluate` waits out any in-flight build for its key before
//   running, so an evaluation's outcome never depends on launch timing. Putting the wait here
//   means no caller can forget it.
// - WATCHDOG: every evaluation runs under a deadline. A step parked forever (an ask that
//   never settles, an authored infinite loop that still awaits) is cancelled through the
//   loader's existing task-cancellation plumbing and reported as a timeout failure — the
//   graph traversal above must always get an answer.
import Foundation
import Synchronization

/// One step's identity in the table: the owning agent + the step's name.
public struct SZStepKey: Hashable, Sendable {
    public var agent: String
    public var step: String

    public init(agent: String, step: String) {
        self.agent = agent
        self.step = step
    }
}

/// MainActor by contract: the table and each entry's compile state are actor-confined, which
/// is the entire synchronization story — only the compile itself leaves the actor.
@MainActor
public final class SZStepRuntime {
    /// What one schedule asked for — carried whole so a coalesced re-schedule can swap in a
    /// different source (or even different directories) and still win.
    private struct LoadRequest: Sendable {
        var sourceURL: URL
        var buildDir: URL
        var runtimeLoadsDir: URL
    }

    /// One key's slot: the loader that owns its mapped modules, the in-flight compile (if
    /// any), and at most ONE queued request — a second schedule while one compiles just
    /// overwrites the queue slot, which is exactly "latest source wins".
    private final class Entry {
        let loader = SZStepLoader()
        var compileTask: Task<Void, Never>?
        var queued: LoadRequest?
    }

    /// App-wide swiftc gate for the step tier, sized to keep a burst of schedules from
    /// becoming a compile storm. Static on purpose: every runtime instance (and every test
    /// in the process) shares the same slots. The blocking wait is acceptable because it
    /// happens on a detached utility task whose whole job is to sit in a subprocess anyway.
    private nonisolated static let compileSlots = DispatchSemaphore(value: 4)

    /// The slot-gated compile, synchronous by design: the semaphore wait must live in a sync
    /// frame (it is unavailable to async contexts), and the detached task that calls this is
    /// exactly the thread we mean to park.
    private nonisolated static func gatedCompile(_ toolchain: SZToolchain,
                                                 _ request: LoadRequest) -> Result<URL, Error> {
        compileSlots.wait()
        defer { compileSlots.signal() }
        return Result { try toolchain.compile(stepSource: request.sourceURL, into: request.buildDir) }
    }

    private let toolchain = SZToolchain()
    private var entries: [SZStepKey: Entry] = [:]

    /// How long one evaluation may run before the watchdog cancels it. Var so a host (or a
    /// test) can tighten it; read at evaluate-start, so a change never retroactively shortens
    /// an evaluation already in flight.
    public var evaluationDeadline: Duration = .seconds(120)

    /// Fired once per failed load (red compile OR an unloadable dylib), AFTER the
    /// keep-old-on-red decision — the host's chance to surface the failure in the UI instead
    /// of only the console. Called on the main actor.
    public var onRedCompile: ((SZStepKey, String) -> Void)?

    public init() {}

    // MARK: - Loading

    /// Compile `sourceURL` off-main and swap the result in for `key` on green. A schedule for
    /// a key that is already compiling coalesces: the request is parked (replacing any
    /// earlier parked one) and compiled once more when the in-flight build finishes.
    public func scheduleLoad(key: SZStepKey, sourceURL: URL, buildDir: URL, runtimeLoadsDir: URL) {
        let request = LoadRequest(sourceURL: sourceURL, buildDir: buildDir, runtimeLoadsDir: runtimeLoadsDir)
        let entry: Entry
        if let existing = entries[key] {
            entry = existing
        } else {
            entry = Entry()
            entries[key] = entry
        }
        if entry.compileTask != nil {
            entry.queued = request
            return
        }
        startCompile(key: key, entry: entry, request: request)
    }

    private func startCompile(key: SZStepKey, entry: Entry, request: LoadRequest) {
        let toolchain = self.toolchain
        entry.compileTask = Task { [weak self] in
            // The slow part, off the actor and gated by the shared slots. Everything the
            // detached closure touches is Sendable; the toolchain is stateless.
            let compiled = await Task.detached(priority: .utility) {
                Self.gatedCompile(toolchain, request)
            }.value
            self?.finishCompile(key: key, entry: entry, request: request, compiled: compiled)
        }
    }

    private func finishCompile(key: SZStepKey, entry: Entry, request: LoadRequest,
                               compiled: Result<URL, Error>) {
        // The entry may have been unloaded (or unloaded-and-rescheduled, minting a fresh
        // entry) while the compile ran — a stale build must not resurrect it.
        guard entries[key] === entry else { return }
        entry.compileTask = nil
        switch compiled {
        case .success(let dylib):
            do {
                // Swap on green; a throw here (unmappable dylib, ABI mismatch) leaves the
                // previous module answering — the loader's contract.
                try entry.loader.load(dylib: dylib, runtimeLoadsDir: request.runtimeLoadsDir)
            } catch {
                onRedCompile?(key, String(describing: error))
            }
        case .failure(let error):
            onRedCompile?(key, String(describing: error))
        }
        // A schedule arrived while we compiled: the latest source goes through one more
        // build. (Chained, not looped — each finish drains at most the one parked request.)
        if let next = entry.queued {
            entry.queued = nil
            startCompile(key: key, entry: entry, request: next)
        }
    }

    // MARK: - Evaluation

    /// One evaluation of the step at `key`, under the watchdog. Awaits any in-flight compile
    /// (including a coalesced follow-up) first — the outcome must never depend on whether the
    /// launch build has finished yet.
    public func evaluate(key: SZStepKey, factsJSON: String,
                         ask: @escaping SZStepAskRunner) async -> SZStepEvalResult {
        // Each awaited task may chain a coalesced recompile behind itself; loop until the
        // key is quiet. Re-read the entry every pass — an unload can drop it mid-wait.
        while let inFlight = entries[key]?.compileTask {
            await inFlight.value
        }
        guard let entry = entries[key] else {
            return .failed("no step is loaded for \(key.agent)/\(key.step)")
        }

        let deadline = evaluationDeadline
        let evalTask = Task { await entry.loader.evaluate(factsJSON: factsJSON, ask: ask) }
        // The watchdog: on expiry, cancel the evaluation through the loader's existing
        // task-cancellation path. `timedOut` is what tells a deadline cancel apart from a
        // caller's cancel — both settle the loader as `.cancelled`.
        let timedOut = Mutex(false)
        let watchdog = Task {
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            timedOut.withLock { $0 = true }
            evalTask.cancel()
        }
        let result = await withTaskCancellationHandler {
            await evalTask.value
        } onCancel: {
            evalTask.cancel()
        }
        // Evaluation finished first ⇒ the watchdog's sleep wakes immediately and it exits —
        // no parked task outlives the call.
        watchdog.cancel()
        if case .cancelled = result, timedOut.withLock({ $0 }) {
            return .failed("step \(key.agent)/\(key.step) timed out after \(Self.describe(deadline))")
        }
        return result
    }

    private static func describe(_ duration: Duration) -> String {
        let parts = duration.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return seconds == seconds.rounded() ? "\(Int(seconds))s" : "\(seconds)s"
    }

    // MARK: - Table reads

    /// What the loaded step says it answers with (its declaration JSON), read at load time.
    /// nil = nothing loaded for the key, or a step that declares nothing in code.
    public func declaration(key: SZStepKey) -> String? {
        entries[key]?.loader.declaration
    }

    /// The declaration for `key`, awaiting any in-flight compile first — the pack gate's
    /// read: schedule a step's source, then ask; the answer must never race the build.
    public func declarationAwaitingCompile(key: SZStepKey) async -> String? {
        while let inFlight = entries[key]?.compileTask {
            await inFlight.value
        }
        return declaration(key: key)
    }

    public func isLoaded(key: SZStepKey) -> Bool {
        entries[key]?.loader.isLoaded == true
    }

    /// Every key with a live module, in no particular order.
    public var loadedKeys: [SZStepKey] {
        entries.compactMap { $0.value.loader.isLoaded ? $0.key : nil }
    }

    /// Drop the runtime's handle on `key`: the entry leaves the table, and a compile still in
    /// flight for it is discarded when it lands (the entry-identity check in `finishCompile`).
    /// The mapped module itself stays mapped — the loader never unmaps by design; what
    /// retirement means at that tier is deleting the on-disk copy, and dropping
    /// the loader here simply stops routing anything else to it.
    public func unload(key: SZStepKey) {
        entries[key] = nil
    }
}
