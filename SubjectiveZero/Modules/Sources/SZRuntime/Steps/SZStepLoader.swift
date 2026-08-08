// SPDX-License-Identifier: AGPL-3.0-only
// dlopen-based loader for a compiled decision-step dylib — `SZLoader`'s small sibling, ABI v4.
// Same mapping discipline as the node tier: copy the dylib to a unique `runtime-loads/` path
// (so the canonical build artifact can be overwritten while the previous copy stays mapped),
// `dlopen(RTLD_NOW|RTLD_LOCAL)`, dlsym, check the API version, and keep the OLD module live on
// any failure (a red reload never costs the green module).
//
// v4 adds two things the async ABI demands:
// - `evaluate` is async: it parks on the module's completion callback, forwards Swift task
//   cancellation as `SZStepCancel`, and serves the step's `askModel` calls through a per-
//   evaluation runner that guarantees every accepted ask is answered exactly once.
// - SWAP-WITH-DRAIN: a newly verified module takes over new evaluations immediately, while
//   the old module keeps running its in-flight evaluations to completion; only when its
//   count reaches zero is it torn down and dlclosed. An evaluation never has its code
//   unloaded from under it.
import Foundation

/// How one evaluation settled. `failed` carries a human-readable reason (a thrown body, a
/// model failure the step didn't catch, a schema mismatch, or a loader-level refusal).
public enum SZStepEvalResult: Sendable, Equatable {
    case outcome(String)
    case cancelled
    case failed(String)
}

/// One stateless model completion, host-side: the loader hands it the `SZAskRequest` JSON
/// exactly as the step sent it and awaits the raw reply text. Throwing `CancellationError`
/// answers the step's ask as cancelled; any other error answers it as failed.
public typealias SZStepAskRunner = @Sendable (String) async throws -> String

/// One mapped step dylib and its in-flight ledger. `@unchecked Sendable`: the symbol pointers
/// are immutable after init; the ledger is lock-guarded.
final class SZStepModule: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    let evaluateFn: SZStepABI.EvaluateFn
    let cancelFn: SZStepABI.CancelFn
    private let teardownFn: SZStepABI.TeardownFn?
    private let copy: URL

    private let lock = NSLock()
    private var inFlight = 0
    private var retired = false
    private var closed = false

    init(handle: UnsafeMutableRawPointer, evaluateFn: SZStepABI.EvaluateFn,
         cancelFn: SZStepABI.CancelFn, teardownFn: SZStepABI.TeardownFn?, copy: URL) {
        self.handle = handle
        self.evaluateFn = evaluateFn
        self.cancelFn = cancelFn
        self.teardownFn = teardownFn
        self.copy = copy
    }

    func begin() {
        lock.lock(); inFlight += 1; lock.unlock()
    }

    /// Called exactly once per begun evaluation, when its completion fires (or when it could
    /// not start). Closes the module if it was retired and this was the last evaluation.
    func end() {
        lock.lock()
        inFlight -= 1
        let shouldClose = retired && inFlight == 0 && !closed
        if shouldClose { closed = true }
        lock.unlock()
        if shouldClose { close() }
    }

    /// The old module's path out during a hot swap: new evaluations already go to the new
    /// module; this one drains. Closes immediately if nothing is in flight.
    func retire() {
        lock.lock()
        retired = true
        let shouldClose = inFlight == 0 && !closed
        if shouldClose { closed = true }
        lock.unlock()
        if shouldClose { close() }
    }

    var isDraining: Bool {
        lock.lock(); defer { lock.unlock() }
        return retired && !closed
    }

    private func close() {
        teardownFn?()
        dlclose(handle)
        try? FileManager.default.removeItem(at: copy)
    }
}

/// `@unchecked Sendable`: load/retire mutate under the lock; evaluation touches only a
/// module's immutable symbols plus its own per-call state.
public final class SZStepLoader: @unchecked Sendable {
    enum LoadError: Error, CustomStringConvertible {
        case dlopenFailed(String)
        case missingSymbol(String)
        case apiMismatch(found: Int32, expected: Int32)

        var description: String {
            switch self {
            case .dlopenFailed(let msg): "dlopen failed: \(msg)"
            case .missingSymbol(let name): "step dylib is missing required symbol \(name)"
            case .apiMismatch(let found, let expected): "step ABI version \(found) != host \(expected)"
            }
        }
    }

    private let lock = NSLock()
    private var current: SZStepModule?
    private var draining: [SZStepModule] = []
    /// What the loaded step says it answers with, as JSON — read once at load.
    public private(set) var declaration: String?

    public init() {}

    public var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return current != nil
    }

    /// Test hook: how many retired modules still hold in-flight evaluations.
    var drainingCount: Int {
        lock.lock()
        draining.removeAll { !$0.isDraining }
        let count = draining.count
        lock.unlock()
        return count
    }

    /// Map + verify `dylib`, then swap it in. The old module is RETIRED, not torn down: its
    /// in-flight evaluations finish on the old code, and it closes when the last one settles.
    /// A throw leaves the live module untouched.
    public func load(dylib: URL, runtimeLoadsDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: runtimeLoadsDir, withIntermediateDirectories: true)
        let copy = runtimeLoadsDir.appending(path: "step-\(UUID().uuidString).dylib")
        try? fm.removeItem(at: copy)
        try fm.copyItem(at: dylib, to: copy)

        guard let handle = dlopen(copy.path, RTLD_NOW | RTLD_LOCAL) else {
            try? fm.removeItem(at: copy)
            throw LoadError.dlopenFailed(String(cString: dlerror()))
        }
        func discard(_ error: LoadError) -> LoadError {
            dlclose(handle)
            try? fm.removeItem(at: copy)
            return error
        }

        guard let versionSym = dlsym(handle, SZStepABI.apiVersionSymbol) else {
            throw discard(.missingSymbol(SZStepABI.apiVersionSymbol))
        }
        let found = unsafeBitCast(versionSym, to: SZStepABI.APIVersionFn.self)()
        guard found == SZStepABI.version else {
            throw discard(.apiMismatch(found: found, expected: SZStepABI.version))
        }
        guard let evaluateSym = dlsym(handle, SZStepABI.evaluateSymbol) else {
            throw discard(.missingSymbol(SZStepABI.evaluateSymbol))
        }
        guard let cancelSym = dlsym(handle, SZStepABI.cancelSymbol) else {
            throw discard(.missingSymbol(SZStepABI.cancelSymbol))
        }
        let teardown = dlsym(handle, SZStepABI.teardownSymbol)
            .map { unsafeBitCast($0, to: SZStepABI.TeardownFn.self) }
        var declared: String?
        if let declareSym = dlsym(handle, SZStepABI.declareSymbol) {
            let declareFn = unsafeBitCast(declareSym, to: SZStepABI.DeclareFn.self)
            declared = Self.readString { out, cap in declareFn(out, cap) }
        }

        let module = SZStepModule(
            handle: handle,
            evaluateFn: unsafeBitCast(evaluateSym, to: SZStepABI.EvaluateFn.self),
            cancelFn: unsafeBitCast(cancelSym, to: SZStepABI.CancelFn.self),
            teardownFn: teardown,
            copy: copy)

        lock.lock()
        let old = current
        current = module
        declaration = declared
        // Pruning of settled modules happens lazily in `drainingCount`: the old module only
        // reads as draining AFTER `retire()` below, so pruning here would drop it early.
        if let old { draining.append(old) }
        lock.unlock()
        old?.retire()
    }

    /// The grow-and-retry string channel (Declare only in v4).
    static func readString(_ call: (UnsafeMutablePointer<CChar>?, Int32) -> Int32) -> String? {
        var capacity = 512
        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let full = buffer.withUnsafeMutableBufferPointer { call($0.baseAddress, Int32($0.count)) }
            guard full > 0 else { return nil }
            if Int(full) > capacity { capacity = Int(full); continue }
            return String(decoding: buffer.prefix(Int(full)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// One asynchronous evaluation against the current module: hand the step its facts
    /// snapshot, serve its `askModel` calls through `ask`, and settle when its completion
    /// fires. Swift task cancellation propagates as `SZStepCancel` + cancellation of every
    /// in-flight ask; the result is then `.cancelled`, never a defect.
    private func currentModule() -> SZStepModule? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func evaluate(factsJSON: String, ask: @escaping SZStepAskRunner) async -> SZStepEvalResult {
        guard let module = currentModule() else { return .failed("no step is loaded") }

        module.begin()
        let box = SZHostEvalBox(ask: ask, module: module)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SZStepEvalResult, Never>) in
                box.arm(continuation)
                let retained = Unmanaged.passRetained(box).toOpaque()
                let token = factsJSON.withCString { factsPtr -> UInt64 in
                    var request = SZStepEvalRequestRaw(
                        factsJSON: factsPtr,
                        factsLen: Int32(factsJSON.utf8.count),
                        hostContext: Unmanaged.passUnretained(box).toOpaque(),
                        askFn: szStepAskTrampoline)
                    return withUnsafePointer(to: &request) {
                        module.evaluateFn(UnsafeRawPointer($0), szStepCompletionTrampoline, retained)
                    }
                }
                if token == 0 {
                    // Could not start: the completion will never fire. Undo its retain and
                    // settle here, through the same idempotent path the trampoline uses.
                    Unmanaged<SZHostEvalBox>.fromOpaque(retained).release()
                    box.settle(.failed("the step could not start (facts rejected)"))
                    module.end()
                } else {
                    box.noteToken(token)
                }
            }
        } onCancel: {
            box.requestCancel()
        }
    }
}

// MARK: - Per-evaluation host state

/// Everything the host holds open for one evaluation: the parked continuation, the ask
/// runner and its in-flight tasks, and the cancel token. Retained by the completion callback
/// (exactly-once), reachable un-retained by ask callbacks (which the completion outlives).
final class SZHostEvalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SZStepEvalResult, Never>?
    private var askTasks: [UInt64: Task<Void, Never>] = [:]
    private var nextCallID: UInt64 = 1
    private var token: UInt64 = 0
    private var cancelRequested = false
    private let ask: SZStepAskRunner
    let module: SZStepModule

    init(ask: @escaping SZStepAskRunner, module: SZStepModule) {
        self.ask = ask
        self.module = module
    }

    func arm(_ continuation: CheckedContinuation<SZStepEvalResult, Never>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
    }

    /// Resume the evaluation's continuation, once; later settles are no-ops.
    func settle(_ result: SZStepEvalResult) {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        taken?.resume(returning: result)
    }

    func noteToken(_ token: UInt64) {
        lock.lock()
        self.token = token
        let alreadyCancelled = cancelRequested
        lock.unlock()
        // Cancellation raced ahead of the token: forward it now that we can.
        if alreadyCancelled { module.cancelFn(token) }
    }

    /// Swift task cancellation, forwarded: cancel the dylib's task and answer every ask.
    func requestCancel() {
        lock.lock()
        cancelRequested = true
        let knownToken = token
        let tasks = askTasks
        lock.unlock()
        if knownToken != 0 { module.cancelFn(knownToken) }
        for task in tasks.values { task.cancel() }
    }

    /// One ask from the step. Every accepted call is answered exactly once: the runner's
    /// reply, its thrown cancellation, its thrown failure — or an immediate cancelled answer
    /// when the evaluation is already being torn down.
    func beginAsk(_ request: String, _ replyFn: @escaping SZStepAskReplyFn, _ replyCtx: UnsafeMutableRawPointer?) -> UInt64 {
        lock.lock()
        let id = nextCallID
        nextCallID += 1
        let alreadyCancelled = cancelRequested
        lock.unlock()

        /// The reply channel as one Sendable value: a C fn pointer + a dylib-owned context
        /// pointer, safe to carry across tasks because the dylib guarantees the context
        /// lives until the (exactly-once) reply.
        struct ReplyChannel: @unchecked Sendable {
            let fn: SZStepAskReplyFn
            let ctx: UnsafeMutableRawPointer?
            func deliver(status: Int32, _ payload: String) {
                if payload.isEmpty { fn(ctx, status, nil, 0) }
                else { payload.withCString { fn(ctx, status, $0, Int32(payload.utf8.count)) } }
            }
        }
        let channel = ReplyChannel(fn: replyFn, ctx: replyCtx)

        if alreadyCancelled {
            channel.deliver(status: 1, "")
            return id
        }

        let runner = ask
        let task = Task { [weak self] in
            do {
                let reply = try await runner(request)
                channel.deliver(status: 0, reply)
            } catch is CancellationError {
                channel.deliver(status: 1, "")
            } catch {
                channel.deliver(status: 2, String(describing: error))
            }
            self?.endAsk(id)
        }
        lock.lock()
        // A task that already finished gets removed by its own endAsk; tracking it briefly
        // is harmless (cancelling a finished task is a no-op), and the box dies at settle.
        askTasks[id] = task
        lock.unlock()
        return id
    }

    private func endAsk(_ id: UInt64) {
        lock.lock(); askTasks[id] = nil; lock.unlock()
    }

    func cancelRemainingAsks() {
        lock.lock()
        let tasks = askTasks
        askTasks = [:]
        lock.unlock()
        for task in tasks.values { task.cancel() }
    }
}

/// dylib → host, exactly once per started evaluation. Balances `passRetained` in `evaluate`.
private let szStepCompletionTrampoline: SZStepCompletionFn = { ctxPtr, status, bytes, len in
    guard let ctxPtr else { return }
    let box = Unmanaged<SZHostEvalBox>.fromOpaque(ctxPtr).takeRetainedValue()
    let payload = bytes.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(len)), as: UTF8.self) } ?? ""
    let result: SZStepEvalResult
    switch status {
    case 0: result = .outcome(payload)
    case 1: result = .cancelled
    default: result = .failed(payload.isEmpty ? "the step failed without a reason" : payload)
    }
    box.cancelRemainingAsks()
    box.settle(result)
    box.module.end()
}

/// dylib → host: one `askModel` call. The box is reached un-retained: the completion callback
/// still holds its retain, and the ABI orders every ask before that completion.
private let szStepAskTrampoline: SZStepAskFn = { hostCtx, bytes, len, replyFn, replyCtx in
    guard let hostCtx, let bytes, len > 0, let replyFn else { return 0 }
    let box = Unmanaged<SZHostEvalBox>.fromOpaque(hostCtx).takeUnretainedValue()
    let request = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(len)), as: UTF8.self)
    return box.beginAsk(request, replyFn, replyCtx)
}
