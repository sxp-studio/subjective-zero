// SPDX-License-Identifier: AGPL-3.0-only
// The host-owned kit compiled into every step dylib beside the author's Step.swift (ABI
// v5). Assembled: the ABI prelude + the spliced SZFacts spec + the authoring surface.
// One way to write a step — `let step = SZStep(outcomes: [...]) { ctx in … }` — and ctx is
// the delivery's facts plus one capability, `ask`. No kind anywhere.
import Foundation

enum SZStepKit {
    /// Relative path the kit file is written to inside a step's build dir.
    static let fileName = "SZStepKit.swift"

    static var source: String {
        corePrefix + "\n\n" + SZStepKitGenerated.factsSection + "\n\n"
            + SZStepKitGenerated.conveniences + "\n\n" + coreSuffix
    }

    // MARK: - Static core, part 1: the ABI prelude

    private static let corePrefix = """
    // HOST-OWNED. Assembled by SZRuntime (step kit, ABI v5). Do not edit in a step.
    import Foundation

    // MARK: - ABI (must byte-match SZStepABI.swift in the host)

    public typealias SZStepCompletionFn = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, Int32) -> Void
    public typealias SZStepAskReplyFn = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, Int32) -> Void
    public typealias SZStepAskFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32, SZStepAskReplyFn?, UnsafeMutableRawPointer?) -> UInt64

    struct SZStepEvalRequestRaw {
        var apiVersion: Int32
        var factsJSON: UnsafePointer<CChar>?
        var factsLen: Int32
        var hostContext: UnsafeMutableRawPointer?
        var askFn: SZStepAskFn?
    }
    """

    // MARK: - Static core, part 2: the authoring surface + entry points

    private static let coreSuffix = """
    // MARK: - Errors

    public enum SZStepError: Error, CustomStringConvertible {
        /// The host offered no model capability to this evaluation.
        case modelUnavailable
        /// The host ran the completion and it failed (provider error, timeout).
        case modelFailed(String)
        /// The reply never decoded into the requested type, after every repair attempt.
        case schemaMismatch(template: String, detail: String)

        public var description: String {
            switch self {
            case .modelUnavailable: return "no model is available to this step"
            case .modelFailed(let reason): return "the model call failed: \\(reason)"
            case .schemaMismatch(let template, let detail):
                return "the reply to '\\(template)' never matched the expected shape: \\(detail)"
            }
        }
    }

    // MARK: - The context

    /// What one evaluation may touch: the delivery's facts snapshot — pinned at
    /// evaluate-start; a step that awaits and then reads a fact sees the world as it was
    /// when evaluation began — and one question-asking capability. Facts read directly off
    /// the context: `ctx.message`, `ctx.resuming`, `ctx.run`, `ctx.assignment`,
    /// `ctx.hasWorkLeft`. `@unchecked Sendable`: the pointers are
    /// host-owned and outlive the evaluation by the ABI's settle contract.
    @dynamicMemberLookup
    public struct SZContext: @unchecked Sendable {
        public let facts: SZFacts
        let host: UnsafeMutableRawPointer?
        let askFn: SZStepAskFn?

        public subscript<Value>(dynamicMember keyPath: KeyPath<SZFacts, Value>) -> Value {
            facts[keyPath: keyPath]
        }

        /// Ask the model ONE question: render the pack template named `template` (a stem —
        /// `prompts/<template>.md.mustache`) against THIS evaluation's facts, run one
        /// stateless completion, decode the reply into `T`. On a shape mismatch the host is
        /// asked again with the decode error and the previous reply attached (the repair
        /// loop), up to `retries` more times, then the step throws honestly. The step never
        /// names a model — routing is the host's.
        public func ask<T: Decodable>(_ template: String, as type: T.Type, retries: Int = 1) async throws -> T {
            var repair: SZAskRepair? = nil
            var lastDetail = "no reply"
            for attempt in 0...max(0, retries) {
                let reply = try await hostCompletion(SZAskRequest(template: template, attempt: attempt, repair: repair))
                do { return try SZJSONExtract.decode(type, from: reply) }
                catch {
                    lastDetail = String(describing: error)
                    repair = SZAskRepair(error: lastDetail, previousReply: reply)
                }
            }
            throw SZStepError.schemaMismatch(template: template, detail: lastDetail)
        }

        private func hostCompletion(_ request: SZAskRequest) async throws -> String {
            guard let askFn else { throw SZStepError.modelUnavailable }
            let json: String
            do {
                let data = try JSONEncoder().encode(request)
                json = String(decoding: data, as: UTF8.self)
            } catch { throw SZStepError.modelFailed("could not encode the ask request") }

            let box = SZReplyBox()
            // NOTE: no cancellation handler here — the ABI contract is that the HOST
            // answers every accepted call exactly once (status 1 when it cancels), so this
            // continuation always resolves. Cancellation needs no dylib-side plumbing.
            return try await withCheckedThrowingContinuation { continuation in
                box.continuation = continuation
                let boxPtr = Unmanaged.passRetained(box).toOpaque()
                let callID = json.withCString { bytes in
                    askFn(host, bytes, Int32(json.utf8.count), szReplyRelay, boxPtr)
                }
                if callID == 0 {
                    // Rejected: the reply will never fire; release our retain and settle.
                    Unmanaged<SZReplyBox>.fromOpaque(boxPtr).release()
                    box.take()?.resume(throwing: SZStepError.modelUnavailable)
                }
            }
        }
    }

    /// The ask request as the host receives it. Facts never travel back — the host renders
    /// the template against the same snapshot it handed this evaluation.
    public struct SZAskRequest: Codable, Sendable {
        public var template: String
        public var attempt: Int
        public var repair: SZAskRepair?
    }
    public struct SZAskRepair: Codable, Sendable {
        public var error: String
        public var previousReply: String
    }

    /// Tolerant decoding for CLI-shaped replies: try the bytes as-is, then every balanced
    /// JSON object/array inside them (fences, preambles, trailing prose), string-literal
    /// aware — a brace inside a quoted value neither closes nor opens anything. A candidate
    /// that fails keeps the scan moving to the next opener: models love restating the
    /// requested format ("answer in the form {json}") before the real answer.
    enum SZJSONExtract {
        static func decode<T: Decodable>(_ type: T.Type, from reply: String) throws -> T {
            let decoder = JSONDecoder()
            let whole = try? decoder.decode(type, from: Data(reply.utf8))
            if let whole { return whole }
            var bestError: Error?
            var searchStart = reply.startIndex
            while let start = reply[searchStart...].firstIndex(where: { $0 == "{" || $0 == "[" }) {
                if let end = balancedEnd(in: reply, from: start) {
                    let slice = Data(reply[start...end].utf8)
                    do { return try decoder.decode(type, from: slice) }
                    catch {
                        // A slice that PARSED as JSON but mismatched the shape is the useful
                        // diagnosis — prefer it over any prose-level parse error.
                        if bestError == nil,
                           (try? JSONSerialization.jsonObject(with: slice, options: [.fragmentsAllowed])) != nil {
                            bestError = error
                        }
                    }
                }
                searchStart = reply.index(after: start)
            }
            if let bestError { throw bestError }
            return try decoder.decode(type, from: Data(reply.utf8))   // throw the real error
        }

        /// The index of the closer balancing the opener at `start`, skipping string
        /// literals (with escape handling). nil if the reply never balances.
        static func balancedEnd(in reply: String, from start: String.Index) -> String.Index? {
            let opener = reply[start]
            let closer: Character = opener == "{" ? "}" : "]"
            var depth = 0
            var inString = false
            var escaped = false
            var index = start
            while index < reply.endIndex {
                let ch = reply[index]
                if inString {
                    if escaped { escaped = false }
                    else if ch == "\\\\" { escaped = true }
                    else if ch == "\\"" { inString = false }
                } else if ch == "\\"" {
                    inString = true
                } else if ch == opener {
                    depth += 1
                } else if ch == closer {
                    depth -= 1
                    if depth == 0 { return index }
                }
                index = reply.index(after: index)
            }
            return nil
        }
    }

    /// The parked ask: holds the continuation between the outbound call and the host's one
    /// guaranteed reply. The take() dance makes resumption idempotent by construction.
    final class SZReplyBox: @unchecked Sendable {
        let lock = NSLock()
        var continuation: CheckedContinuation<String, Error>?
        func take() -> CheckedContinuation<String, Error>? {
            lock.lock(); defer { lock.unlock() }
            let taken = continuation; continuation = nil; return taken
        }
    }

    private let szReplyRelay: SZStepAskReplyFn = { replyCtx, status, bytes, len in
        guard let replyCtx else { return }
        let box = Unmanaged<SZReplyBox>.fromOpaque(replyCtx).takeRetainedValue()
        let payload = bytes.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(len)), as: UTF8.self) } ?? ""
        switch status {
        case 0: box.take()?.resume(returning: payload)
        case 1: box.take()?.resume(throwing: CancellationError())
        default: box.take()?.resume(throwing: SZStepError.modelFailed(payload.isEmpty ? "unspecified" : payload))
        }
    }

    // MARK: - The authoring surface

    /// A step's full answer: the outcome the graph routes on, plus EFFECTS — the typed host
    /// actions the step requests. The host runs them AFTER the step returns and BEFORE edge
    /// routing. A bare string is a plain effect-less outcome, so ordinary spellings need no
    /// ceremony.
    public struct SZAnswer: Sendable, ExpressibleByStringLiteral {
        public var outcome: String
        public var effects: [SZEffect]

        public init(outcome: String, effects: [SZEffect] = []) {
            self.outcome = outcome
            self.effects = effects
        }

        public init(stringLiteral value: String) { self.init(outcome: value) }

        /// The spelled-out factory: `return .outcome("implement", effects: [.requestBuild])`.
        public static func outcome(_ outcome: String, effects: [SZEffect] = []) -> SZAnswer {
            SZAnswer(outcome: outcome, effects: effects)
        }
    }

    /// THE step — the one authoring construct. Declare the outcomes (the card's ports; the
    /// pack gate checks the graph's edges against them), write the body:
    ///
    ///     let step = SZStep(outcomes: ["yes", "no"]) { $0.hasWorkLeft ? "yes" : "no" }
    ///
    /// The body reads `ctx` (the facts, `ask`) and answers an outcome — or a full
    /// `SZAnswer` when it requests effects. It may `await`; it cannot mutate the host:
    /// anything it wants done travels back as its outcome (or a requested effect).
    public struct SZStep: Sendable {
        public let outcomes: [String]
        let body: @Sendable (SZContext) async throws -> SZAnswer

        public init(outcomes: [String], _ body: @escaping @Sendable (SZContext) async throws -> String) {
            self.outcomes = outcomes
            self.body = { SZAnswer(outcome: try await body($0)) }
        }

        /// The effect-emitting spelling, same shape. Disfavored so a body answering plain
        /// strings resolves to the String overload; this one wins exactly when the body
        /// actually speaks `SZAnswer`.
        @_disfavoredOverload
        public init(outcomes: [String], _ body: @escaping @Sendable (SZContext) async throws -> SZAnswer) {
            self.outcomes = outcomes
            self.body = body
        }
    }

    // MARK: - Entry points

    private final class SZEvalTable: @unchecked Sendable {
        let lock = NSLock()
        var tasks: [UInt64: Task<Void, Never>] = [:]
        /// Tokens whose remove() beat their set() — a body that finished before
        /// SZStepEvaluate stored it. set() consumes the tombstone instead of resurrecting
        /// a finished entry, so the set stays ~empty.
        var orphaned: Set<UInt64> = []
        var nextToken: UInt64 = 1
        func mint() -> UInt64 { lock.lock(); defer { lock.unlock() }; let t = nextToken; nextToken += 1; return t }
        func set(_ token: UInt64, _ task: Task<Void, Never>) {
            lock.lock()
            if orphaned.remove(token) == nil { tasks[token] = task }
            lock.unlock()
        }
        func remove(_ token: UInt64) {
            lock.lock()
            if tasks.removeValue(forKey: token) == nil { orphaned.insert(token) }
            lock.unlock()
        }
        func cancel(_ token: UInt64) { lock.lock(); let task = tasks[token]; lock.unlock(); task?.cancel() }
    }
    private let szEvalTable = SZEvalTable()

    private func szDeliver(_ done: SZStepCompletionFn, _ ctx: UnsafeMutableRawPointer?, status: Int32, _ payload: String) {
        payload.withCString { done(ctx, status, $0, Int32(payload.utf8.count)) }
    }

    /// The success payload on the wire, ADDITIVE by construction: an effect-less answer is
    /// the bare outcome string; only an answer carrying effects rides the JSON envelope
    /// (which no bare outcome can be mistaken for — outcomes are names, not JSON objects).
    private func szWirePayload(_ answer: SZAnswer) -> String {
        guard !answer.effects.isEmpty else { return answer.outcome }
        struct Envelope: Encodable {
            var outcome: String
            var effects: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Envelope(outcome: answer.outcome, effects: answer.effects.map(\\.rawValue))) else {
            return answer.outcome
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func szStartEvaluation(_ authored: SZStep, _ request: SZStepEvalRequestRaw,
                                   _ done: @escaping SZStepCompletionFn,
                                   _ doneCtx: UnsafeMutableRawPointer?) -> UInt64 {
        guard let factsPtr = request.factsJSON, request.factsLen > 0,
              let facts = try? JSONDecoder().decode(SZFacts.self, from: Data(bytes: factsPtr, count: Int(request.factsLen)))
        else { return 0 }   // could not start; the completion is never called

        let ctx = SZContext(facts: facts, host: request.hostContext, askFn: request.askFn)
        let token = szEvalTable.mint()
        let task = Task {
            var status: Int32 = 0
            var payload = ""
            do { payload = szWirePayload(try await authored.body(ctx)) }
            catch is CancellationError { status = 1 }
            catch { status = 2; payload = String(describing: error) }
            // The table entry dies BEFORE the completion: once done() fires the host may
            // begin tearing this module down, so delivery is the body's last act.
            szEvalTable.remove(token)
            szDeliver(done, doneCtx, status: status, payload)         // exactly once, by construction
        }
        szEvalTable.set(token, task)
        return token
    }

    @_cdecl("SZStepAPIVersion")
    public func SZStepAPIVersion() -> Int32 { 5 }

    @_cdecl("SZStepEvaluate")
    public func SZStepEvaluate(_ raw: UnsafeRawPointer?, _ done: SZStepCompletionFn?, _ doneCtx: UnsafeMutableRawPointer?) -> UInt64 {
        guard let raw, let done else { return 0 }
        let request = raw.assumingMemoryBound(to: SZStepEvalRequestRaw.self).pointee
        return szStartEvaluation(step, request, done, doneCtx)
    }

    @_cdecl("SZStepCancel")
    public func SZStepCancel(_ token: UInt64) { szEvalTable.cancel(token) }

    @_cdecl("SZStepDeclare")
    public func SZStepDeclare(_ out: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
        guard let out, !step.outcomes.isEmpty else { return 0 }
        struct Declaration: Encodable { var outcomes: [String] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Declaration(outcomes: step.outcomes)) else { return 0 }
        let bytes = Array(data)
        let n = min(bytes.count, Int(cap))
        for i in 0..<n { out[i] = CChar(bitPattern: bytes[i]) }
        return Int32(bytes.count)
    }
    """
}
