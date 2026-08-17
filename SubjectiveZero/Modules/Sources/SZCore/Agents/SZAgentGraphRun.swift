// SPDX-License-Identifier: AGPL-3.0-only
// One RUN of an agent graph — a single message's whole journey as a record: who received
// it, the ordered trace (entry 1 is the door visit, whose outcome says what arrived), and
// the conclusion. The record carries no kind and derives none: `thread` groups a parent
// traversal with the work children it dispatched, and everything the list needs is that
// structure. The host begins a record at delivery, feeds it trace entries, and seals it on
// the conclusion. The mutation RULES live here so they are testable without a host.
import Foundation

public struct SZAgentGraphRun: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    /// The traversing agent's pack id ("director", "coding").
    public var agent: String
    /// The build THREAD this traversal belongs to — the build traversal's own id, shared
    /// by the work children it dispatched. nil = a standalone conversation.
    public var thread: UUID?
    /// For a dispatched work child: the node id it serves.
    public var work: String?
    public var startedAt: Date
    /// nil while the traversal is under way — the record is LIVE. Live records persist too;
    /// one restored still live was interrupted (`sealInterrupted`).
    public var endedAt: Date?
    /// The executed trace, in traversal order — loops unrolled, one entry per node visit.
    public var trace: [Entry]
    /// How the traversal ended — nil while live, stamped exactly once by `seal`.
    public var conclusion: Conclusion?
    public var isLive: Bool { endedAt == nil }

    /// Whether this record LEADS its thread — the parent traversal whose own id is the
    /// thread id, which its dispatched children share. Structure, not classification:
    /// drives list ordering (the panel follows the thread's spine) and the cap budgets
    /// (children outnumber parents many to one).
    public var leadsThread: Bool { thread == id }

    public init(id: UUID, agent: String, thread: UUID? = nil, work: String? = nil,
                startedAt: Date = Date(), endedAt: Date? = nil, trace: [Entry] = [],
                conclusion: Conclusion? = nil) {
        self.id = id
        self.agent = agent
        self.thread = thread
        self.work = work
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.trace = trace
        self.conclusion = conclusion
    }

    // An absent trace decodes empty — a minimal record is legal on disk.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        agent = try c.decode(String.self, forKey: .agent)
        thread = try c.decodeIfPresent(UUID.self, forKey: .thread)
        work = try c.decodeIfPresent(String.self, forKey: .work)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        trace = try c.decodeIfPresent([Entry].self, forKey: .trace) ?? []
        conclusion = try c.decodeIfPresent(Conclusion.self, forKey: .conclusion)
    }

    private enum CodingKeys: String, CodingKey {
        case id, agent, thread, work, startedAt, endedAt, trace, conclusion
    }

    // MARK: - The trace entry

    /// One node visit. The engine reports each visit repeatedly (running, then settled)
    /// and the record replaces by `(ordinal, node)` — plus the host-stamped wall clock,
    /// which the engine's date-free notes never carry.
    public struct Entry: Sendable, Equatable, Identifiable, Codable {
        /// Position in the traversal, the engine's own numbering (1 is the door).
        public var ordinal: Int
        /// The graph node this entry is a visit OF.
        public var node: String
        public var phase: Phase
        /// The outcome the node produced, once settled.
        public var outcome: String?
        /// A failed entry's reason — agent-reported words, preserved verbatim.
        public var detail: String?
        /// A dispatch visit's fleet tally, amended on every settle WHILE the visit runs —
        /// per entry, because a retry loop visits the dispatch twice and each visit owns
        /// its own set.
        public var tally: Tally?
        /// HOST-stamped wall clock (`note` stamps on first sight / settle) — never
        /// engine-stamped. Persisted with the trace.
        public var startedAt: Date?
        public var endedAt: Date?

        public var id: Int { ordinal }

        public enum Phase: String, Sendable, Codable {
            case running, done, failed
            /// Stamped only by `seal` — the traversal ended while this entry still ran.
            case cancelled
        }

        public init(ordinal: Int, node: String, phase: Phase, outcome: String? = nil,
                    detail: String? = nil, tally: Tally? = nil,
                    startedAt: Date? = nil, endedAt: Date? = nil) {
            self.ordinal = ordinal
            self.node = node
            self.phase = phase
            self.outcome = outcome
            self.detail = detail
            self.tally = tally
            self.startedAt = startedAt
            self.endedAt = endedAt
        }

        /// Settled wall time — nil while running (a card ticks its own live elapsed instead).
        public var duration: TimeInterval? {
            guard let startedAt, let endedAt else { return nil }
            return endedAt.timeIntervalSince(startedAt)
        }

        // An absent value is NOT encoded — no key that says nothing.
        private enum CodingKeys: String, CodingKey {
            case ordinal, node, phase, outcome, detail, tally, startedAt, endedAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ordinal = try c.decode(Int.self, forKey: .ordinal)
            node = try c.decode(String.self, forKey: .node)
            // Tolerant like `trace` above: the whole-file decode is `?? []` at load, so one
            // entry missing a phase must not silently erase a project's entire run history.
            phase = try c.decodeIfPresent(Phase.self, forKey: .phase) ?? .done
            outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
            detail = try c.decodeIfPresent(String.self, forKey: .detail)
            tally = try c.decodeIfPresent(Tally.self, forKey: .tally)
            startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
            endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(ordinal, forKey: .ordinal)
            try c.encode(node, forKey: .node)
            try c.encode(phase, forKey: .phase)
            try c.encodeIfPresent(outcome, forKey: .outcome)
            try c.encodeIfPresent(detail, forKey: .detail)
            try c.encodeIfPresent(tally, forKey: .tally)
            try c.encodeIfPresent(startedAt, forKey: .startedAt)
            try c.encodeIfPresent(endedAt, forKey: .endedAt)
        }
    }

    // MARK: - Conclusion and tally

    /// How a traversal ENDED — the closed vocabulary (`SZTraversalEnding`), respelled as a
    /// Codable archive value so the sidecar's format is owned here.
    public enum Conclusion: Sendable, Equatable, Codable {
        case ended
        case failed(reason: String)
        case cancelled
        /// The graph REFUSED the work and said why — not a failure (nothing broke), not an
        /// ending (the work was deliberately not done): its own class.
        case declined(reason: String)
        /// The traversal's own integrity broke — recorded loudly rather than crashed on.
        case defect(detail: String)

        public init(_ ending: SZTraversalEnding) {
            switch ending {
            case .ended: self = .ended
            case .failed(let reason): self = .failed(reason: reason)
            case .cancelled: self = .cancelled
            case .declined(let reason): self = .declined(reason: reason)
            case .defect(let detail): self = .defect(detail: detail)
            }
        }
    }

    /// A dispatch set's settlement counts, exactly as the supervisor reports them.
    public struct Tally: Sendable, Equatable, Codable {
        public var settled: Int
        public var total: Int
        public var failed: Int
        public init(settled: Int, total: Int, failed: Int) {
            self.settled = settled
            self.total = total
            self.failed = failed
        }
    }

    // MARK: - The traversal feeding its record

    /// Fold one reported entry in. The SEALED-RECORD GUARD is the generalized zombie
    /// protection: once a record ended, nothing may write it. Same-`(ordinal, node)`
    /// reports replace, PRESERVING the stamps: first sight stamps `startedAt`; the first
    /// non-running report stamps `endedAt`; a re-emit never restamps.
    public mutating func note(_ entry: Entry, at now: Date = Date()) {
        guard endedAt == nil else { return }
        var merged = entry
        if let i = trace.firstIndex(where: { $0.ordinal == entry.ordinal && $0.node == entry.node }) {
            merged.startedAt = trace[i].startedAt
            merged.endedAt = trace[i].endedAt
            // A re-emit without a tally never erases one a progress note wrote.
            if merged.tally == nil { merged.tally = trace[i].tally }
            if merged.phase != .running, merged.endedAt == nil { merged.endedAt = now }
            trace[i] = merged
        } else {
            merged.startedAt = now
            if merged.phase != .running, merged.endedAt == nil { merged.endedAt = now }
            trace.append(merged)
        }
    }

    /// End the record: stamp the conclusion, flip a still-running last entry to `cancelled`
    /// (the eager-cancel path arrives before the traversal's own settle ever will), and
    /// close `endedAt`. IDEMPOTENT and conclusion-guarded: a record that already carries a
    /// conclusion (its task merely hasn't drained) keeps its real ending.
    public mutating func seal(conclusion: Conclusion, at now: Date = Date()) {
        guard endedAt == nil else { return }
        if self.conclusion == nil {
            if let last = trace.indices.last, trace[last].phase == .running {
                trace[last].phase = .cancelled
                if trace[last].endedAt == nil { trace[last].endedAt = now }
            }
            self.conclusion = conclusion
        }
        endedAt = now
    }

    /// The restore policy for a record that was LIVE on disk: the app closed while it ran.
    /// Sealed `.cancelled` at the trace's latest stamp (or the start), the flipped entry
    /// carrying the interrupted detail — it reads as an interrupted run, in place.
    public static let interruptedDetail = "the app closed while this run was in flight"
    public mutating func sealInterrupted() {
        guard isLive else { return }
        let latest = trace.compactMap { $0.endedAt ?? $0.startedAt }.max() ?? startedAt
        let flips = trace.last?.phase == .running
        seal(conclusion: .cancelled, at: max(latest, startedAt))
        if flips, let last = trace.indices.last { trace[last].detail = Self.interruptedDetail }
    }

    // MARK: - Reading the trace

    /// How often `node` was visited over the whole trace — any count above one puts the
    /// visit mark on ALL of that node's entries.
    public func visits(of node: String) -> Int {
        trace.lazy.filter { $0.node == node }.count
    }

    /// The 1-based visit number of one entry — "visit 2" on the loop's second pass.
    public func visitNumber(of entry: Entry) -> Int {
        trace.lazy.filter { $0.node == entry.node && $0.ordinal <= entry.ordinal }.count
    }

    // MARK: - The list's rules

    /// List order: live first, and among the live ones the thread's LEADER leads (it runs
    /// for minutes while children come and go, and the head of the list is what the panel
    /// follows); then by start, newest first.
    public static func ordered(_ runs: [SZAgentGraphRun]) -> [SZAgentGraphRun] {
        runs.sorted {
            if $0.isLive != $1.isLive { return $0.isLive }
            if $0.isLive, $0.leadsThread != $1.leadsThread { return $0.leadsThread }
            return $0.startedAt > $1.startedAt
        }
    }

    /// Cap the history (~50) — never a live record. Two budgets: thread children outnumber
    /// their leaders many to one, so a shared cap would let one busy afternoon evict every
    /// recorded thread. Order-independent: the victim is the OLDEST ENDED record of its
    /// budget by its own clock.
    public static func capped(_ runs: [SZAgentGraphRun],
                              leaders: Int = 20, others: Int = 30) -> [SZAgentGraphRun] {
        var kept = runs
        for (leads, limit) in [(true, leaders), (false, others)] {
            while kept.lazy.filter({ $0.leadsThread == leads }).count > limit,
                  let victim = oldestEnded(in: kept, leading: leads) {
                kept.remove(at: victim)
            }
        }
        return kept
    }

    private static func oldestEnded(in runs: [SZAgentGraphRun], leading: Bool) -> Int? {
        runs.indices
            .filter { !runs[$0].isLive && runs[$0].leadsThread == leading }
            .min { runs[$0].startedAt < runs[$1].startedAt }
    }
}
