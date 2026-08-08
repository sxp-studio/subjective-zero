// SPDX-License-Identifier: AGPL-3.0-only
// The host-owned SDK compiled into every step dylib beside the author's `Step.swift` — the
// `SZRuntimeSupport` pattern, step tier, ABI v4.
//
// The source is ASSEMBLED, not written: the ABI prelude and the authoring surface are
// static here, and the facts land in the middle from `SZStepSDKGenerated` — the verbatim
// spec region of SZCore's SZFacts.swift plus its derived-convenience extensions, emitted by
// the SZFactGen plugin. One spec, compiled twice: the app and every step decode the same
// wire shape, and `hasWorkLeft`-style spellings exist exactly once.
//
// A step is typed to its graph kind: `SZBuildCondition { $0.hasWorkLeft }` compiles against
// SZBuildFacts, and reading a fact another kind publishes is a COMPILE error in the step —
// the gate the old vocabulary-audit machinery approximated with text scans.
import Foundation

enum SZStepSDK {
    /// Relative path the SDK file is written to inside a step's build dir.
    static let fileName = "SZStepSDK.swift"

    static var source: String {
        corePrefix + "\n\n" + SZStepSDKGenerated.factsSection + "\n\n"
            + SZStepSDKGenerated.conveniences + "\n\n" + coreSuffix
    }

    // MARK: - Static core, part 1: the ABI prelude

    private static let corePrefix = """
    // HOST-OWNED. Assembled by SZRuntime (step SDK, ABI v4). Do not edit in a step.
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
    // MARK: - Kinds

    /// A facts struct a step may be typed against. The four conformances below are
    /// architectural — one per graph kind — and the name is what the step's declaration
    /// reports so the pack gate can refuse a step wired into the wrong kind's graph.
    public protocol SZFactsKind: Codable, Sendable {
        static var kindName: String { get }
    }
    extension SZBuildFacts: SZFactsKind { public static var kindName: String { "build" } }
    extension SZChatFacts: SZFactsKind { public static var kindName: String { "chat" } }
    extension SZItemFacts: SZFactsKind { public static var kindName: String { "item" } }
    extension SZRequestFacts: SZFactsKind { public static var kindName: String { "request" } }

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

    /// What one evaluation may touch: its kind's facts snapshot — pinned at evaluate-start;
    /// a step that awaits and then reads a fact sees the world as it was when evaluation
    /// began — and one question-asking capability. Facts read directly off the context:
    /// `$0.hasWorkLeft`, `$0.nodeStatuses`. `@unchecked Sendable`: the pointers are
    /// host-owned and outlive the evaluation by the ABI's settle contract.
    @dynamicMemberLookup
    public struct SZContext<Facts: SZFactsKind>: @unchecked Sendable {
        public let facts: Facts
        let host: UnsafeMutableRawPointer?
        let askFn: SZStepAskFn?

        public subscript<Value>(dynamicMember keyPath: KeyPath<Facts, Value>) -> Value {
            facts[keyPath: keyPath]
        }

        /// Render `template` (a `.md.mustache` the host resolves against THIS evaluation's
        /// facts), run ONE stateless model completion, decode the reply into `T`. On a
        /// shape mismatch the host is asked again with the decode error attached
        /// (`repair`), up to `retries` more times. The step never names a model — routing
        /// is the host's.
        public func askModel<T: Decodable>(template: String, as type: T.Type, retries: Int = 1) async throws -> T {
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

    /// What a step answers with, and which kind's facts it compiled against — what the
    /// panel draws as the card's ports and the pack gate validates edges and wiring with.
    public struct SZStepDeclaration: Encodable {
        public var outcomes: [String]
        public var facts: String
        public init(outcomes: [String], facts: String) {
            self.outcomes = outcomes
            self.facts = facts
        }
    }

    /// A step's full answer: the outcome the graph routes on, plus EFFECTS — named host
    /// actions the step requests. The host runs them AFTER the step returns and BEFORE edge
    /// routing; an effect outside the kind's declared set is a traversal defect. A bare
    /// string is a plain effect-less outcome, so today's spellings need no ceremony.
    public struct SZAnswer: Sendable, ExpressibleByStringLiteral {
        public var outcome: String
        public var effects: [String]

        public init(outcome: String, effects: [String] = []) {
            self.outcome = outcome
            self.effects = effects
        }

        public init(stringLiteral value: String) { self.init(outcome: value) }

        /// The spelled-out factory: `return .outcome("build", effects: ["requestBuild"])`.
        public static func outcome(_ outcome: String, effects: [String] = []) -> SZAnswer {
            SZAnswer(outcome: outcome, effects: effects)
        }
    }

    /// The step contract: one kind's facts in, one declared outcome out. A body may
    /// `await` — and may `askModel` — but it cannot mutate the host; anything it wants
    /// done travels back as its outcome (and, for a host action, as a requested effect).
    public protocol SZStep: Sendable {
        associatedtype Facts: SZFactsKind
        var declaration: SZStepDeclaration { get }
        func evaluate(_ ctx: SZContext<Facts>) async throws -> String
        /// The full answer, effects included. Defaulted onto `evaluate`, so a plain step
        /// never spells it; `SZRouter` forwards its closure's whole answer through here.
        func answer(_ ctx: SZContext<Facts>) async throws -> SZAnswer
        func teardown()
    }
    public extension SZStep {
        func teardown() {}
        var declaration: SZStepDeclaration { SZStepDeclaration(outcomes: [], facts: Facts.kindName) }
        func answer(_ ctx: SZContext<Facts>) async throws -> SZAnswer {
            SZAnswer(outcome: try await evaluate(ctx))
        }
    }

    /// A yes/no question — the ordinary step, still one line, typed to its kind:
    ///
    ///     let step = SZBuildCondition { $0.hasWorkLeft }
    ///
    /// A synchronous closure converts implicitly; `try await` inside is equally at home.
    public struct SZCondition<Facts: SZFactsKind>: SZStep {
        let body: @Sendable (SZContext<Facts>) async throws -> Bool
        public init(_ body: @escaping @Sendable (SZContext<Facts>) async throws -> Bool) { self.body = body }
        public var declaration: SZStepDeclaration { SZStepDeclaration(outcomes: ["yes", "no"], facts: Facts.kindName) }
        public func evaluate(_ ctx: SZContext<Facts>) async throws -> String { try await body(ctx) ? "yes" : "no" }
    }

    /// A question whose answer IS data — one outcome per branch, named up front because the
    /// graph draws an edge from each:
    ///
    ///     let step = SZChatRouter("answer", "build") {
    ///         try await $0.askModel(template: "classify-reply", as: Ruling.self).kind
    ///     }
    public struct SZRouter<Facts: SZFactsKind>: SZStep {
        let outcomes: [String]
        let body: @Sendable (SZContext<Facts>) async throws -> SZAnswer
        public init(_ outcomes: String..., answer: @escaping @Sendable (SZContext<Facts>) async throws -> String) {
            self.outcomes = outcomes
            self.body = { SZAnswer(outcome: try await answer($0)) }
        }
        /// The effect-emitting spelling, still one line:
        ///
        ///     let step = SZChatRouter("answer", "build") { _ in
        ///         .outcome("build", effects: ["requestBuild"])
        ///     }
        ///
        /// Disfavored so a body that answers plain strings keeps resolving to the String
        /// overload (bit-stable wire for every existing step); this one wins exactly when
        /// the body actually speaks `SZAnswer`.
        @_disfavoredOverload
        public init(_ outcomes: String..., answer: @escaping @Sendable (SZContext<Facts>) async throws -> SZAnswer) {
            self.outcomes = outcomes
            self.body = answer
        }
        public var declaration: SZStepDeclaration { SZStepDeclaration(outcomes: outcomes, facts: Facts.kindName) }
        public func evaluate(_ ctx: SZContext<Facts>) async throws -> String { try await body(ctx).outcome }
        public func answer(_ ctx: SZContext<Facts>) async throws -> SZAnswer { try await body(ctx) }
    }

    /// One spelling per kind — the graph kind is part of the step's name, nothing else.
    public typealias SZBuildCondition = SZCondition<SZBuildFacts>
    public typealias SZChatCondition = SZCondition<SZChatFacts>
    public typealias SZItemCondition = SZCondition<SZItemFacts>
    public typealias SZRequestCondition = SZCondition<SZRequestFacts>
    public typealias SZBuildRouter = SZRouter<SZBuildFacts>
    public typealias SZChatRouter = SZRouter<SZChatFacts>
    public typealias SZItemRouter = SZRouter<SZItemFacts>
    public typealias SZRequestRouter = SZRouter<SZRequestFacts>

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
    /// the bare outcome string exactly as it always was; only an answer carrying effects
    /// rides the JSON envelope (which no bare outcome can be mistaken for — outcomes are
    /// names, not JSON objects).
    private func szWirePayload(_ answer: SZAnswer) -> String {
        guard !answer.effects.isEmpty else { return answer.outcome }
        struct Envelope: Encodable {
            var outcome: String
            var effects: [String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Envelope(outcome: answer.outcome, effects: answer.effects)) else {
            return answer.outcome
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Generic over the authored step's kind, so the facts document decodes into exactly
    /// the struct the body was compiled against — an off-kind document fails to start.
    private func szStartEvaluation<S: SZStep>(_ authored: S, _ request: SZStepEvalRequestRaw,
                                              _ done: @escaping SZStepCompletionFn,
                                              _ doneCtx: UnsafeMutableRawPointer?) -> UInt64 {
        guard let factsPtr = request.factsJSON, request.factsLen > 0,
              let facts = try? JSONDecoder().decode(S.Facts.self, from: Data(bytes: factsPtr, count: Int(request.factsLen)))
        else { return 0 }   // could not start; the completion is never called

        let ctx = SZContext<S.Facts>(facts: facts, host: request.hostContext, askFn: request.askFn)
        let token = szEvalTable.mint()
        let task = Task {
            var status: Int32 = 0
            var payload = ""
            do { payload = szWirePayload(try await authored.answer(ctx)) }
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
    public func SZStepAPIVersion() -> Int32 { 4 }

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
        guard let out, !step.declaration.outcomes.isEmpty else { return 0 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(step.declaration) else { return 0 }
        let bytes = Array(data)
        let n = min(bytes.count, Int(cap))
        for i in 0..<n { out[i] = CChar(bitPattern: bytes[i]) }
        return Int32(bytes.count)
    }

    @_cdecl("SZStepTeardown")
    public func SZStepTeardown() { step.teardown() }
    """
}
