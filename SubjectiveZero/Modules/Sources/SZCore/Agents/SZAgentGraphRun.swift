// SPDX-License-Identifier: AGPL-3.0-only
// One RUN of an agent graph — a single graph traversal, as a record: which agent traversed
// which graph on which delivered kind, when, the ordered trace of what it did, how it
// concluded, and (for a traversal that dispatched) how its set settled. The Agent Graph
// panel's RUNS list is `[SZAgentGraphRun]`; the host begins a record as a traversal starts,
// feeds it trace entries from the engine's notes, and seals it on the traversal's conclusion.
// The RULES live here as mutations so they are testable without a host: the sealed-record
// guard, the stamp-preserving merge, the idempotent seal, and `amendDispatchTally` — the ONE
// sanctioned post-seal write.
//
// The trace entry is deliberately this module's OWN value: the engine's note type lives in
// SZAI, which neither SZCore nor SZUI may import — the host maps one onto the other at its
// seam, and the record stays drawable by the panel and archivable by the sidecar.
import Foundation

public struct SZAgentGraphRun: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    /// The traversing agent's pack id ("director", "coding") — enough to resolve the drawn
    /// graph through a host closure; an archive whose library moved on degrades to an honest
    /// empty canvas rather than a stale picture.
    public var agent: String
    public var graphName: String
    /// The delivered kind that entered the graph (`build`, `settled`, `item`, …).
    public var kind: SZMessageKind
    /// The dispatch THREAD this traversal belongs to — one Build press and every traversal
    /// it causes, across every agent, share one id; the RUNS list groups by it. nil = a
    /// standalone traversal.
    public var thread: UUID?
    /// For an `.item` traversal: the dispatched work item (a node id) it handles.
    public var item: String?
    public var startedAt: Date
    /// nil while the traversal is still under way — the record is LIVE. Live records are
    /// never persisted (a crash mid-traversal loses the record; the transcript survives).
    public var endedAt: Date?
    /// The executed trace, in traversal order — loops unrolled, one entry per node visit.
    public var trace: [Entry]
    /// How the traversal ended — nil while live, stamped exactly once by `seal`.
    public var conclusion: Conclusion?
    /// A dispatching traversal's settlement tally. The traversal that SENT seals seconds
    /// later; its set settles minutes after that — `amendDispatchTally` keeps this current
    /// so the record reads "3/4 · 1 failed" rather than "0/4" forever.
    public var tally: Tally?

    public var isLive: Bool { endedAt == nil }

    public init(id: UUID, agent: String, graphName: String, kind: SZMessageKind,
                thread: UUID? = nil, item: String? = nil, startedAt: Date = Date(),
                endedAt: Date? = nil, trace: [Entry] = [], conclusion: Conclusion? = nil,
                tally: Tally? = nil) {
        self.id = id
        self.agent = agent
        self.graphName = graphName
        self.kind = kind
        self.thread = thread
        self.item = item
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.trace = trace
        self.conclusion = conclusion
        self.tally = tally
    }

    // MARK: - The trace entry

    /// One node visit as the record keeps it: the engine reports each visit repeatedly
    /// (running, then settled) and the record replaces by `(ordinal, node)` — plus the
    /// host-stamped wall clock, which the engine's date-free notes never carry.
    public struct Entry: Sendable, Equatable, Identifiable, Codable {
        /// Position in the traversal, the engine's own numbering (1 is the entry).
        public var ordinal: Int
        /// The graph node this entry is a visit OF.
        public var node: String
        public var phase: Phase
        /// The outcome the node produced, once settled.
        public var outcome: String?
        /// A failed entry's reason — agent-reported words, preserved verbatim.
        public var detail: String?
        /// HOST-stamped wall clock (`note` stamps on first sight / settle) — never
        /// engine-stamped, so SZAI's outputs stay date-free. Persisted with the trace.
        public var startedAt: Date?
        public var endedAt: Date?

        public var id: Int { ordinal }

        public enum Phase: String, Sendable, Codable {
            case running, done, failed
            /// Stamped only by `seal` — the traversal ended while this entry still ran.
            case cancelled
        }

        public init(ordinal: Int, node: String, phase: Phase, outcome: String? = nil,
                    detail: String? = nil, startedAt: Date? = nil, endedAt: Date? = nil) {
            self.ordinal = ordinal
            self.node = node
            self.phase = phase
            self.outcome = outcome
            self.detail = detail
            self.startedAt = startedAt
            self.endedAt = endedAt
        }

        /// Settled wall time — nil while running (a card ticks its own live elapsed instead).
        public var duration: TimeInterval? {
            guard let startedAt, let endedAt else { return nil }
            return endedAt.timeIntervalSince(startedAt)
        }

        // Tolerant both ways: an entry written before an optional field decodes with its
        // default, and an absent value is NOT encoded — no key that says nothing.
        private enum CodingKeys: String, CodingKey {
            case ordinal, node, phase, outcome, detail, startedAt, endedAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ordinal = try c.decode(Int.self, forKey: .ordinal)
            node = try c.decode(String.self, forKey: .node)
            phase = try c.decodeIfPresent(Phase.self, forKey: .phase) ?? .done
            outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
            detail = try c.decodeIfPresent(String.self, forKey: .detail)
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
            try c.encodeIfPresent(startedAt, forKey: .startedAt)
            try c.encodeIfPresent(endedAt, forKey: .endedAt)
        }
    }

    // MARK: - Conclusion and tally

    /// How a traversal ENDED — the machine's closed vocabulary (`SZTraversalEnding`),
    /// respelled as a Codable archive value so the sidecar's format is owned here.
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

    /// A dispatch set's settlement counts, exactly as the thread machine reports them.
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

    // MARK: - Codable (tolerant like the entry)

    private enum CodingKeys: String, CodingKey {
        case id, agent, graphName, kind, thread, item, startedAt, endedAt, trace, conclusion, tally
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        agent = try c.decode(String.self, forKey: .agent)
        graphName = try c.decode(String.self, forKey: .graphName)
        kind = try c.decodeIfPresent(SZMessageKind.self, forKey: .kind) ?? .build
        thread = try c.decodeIfPresent(UUID.self, forKey: .thread)
        item = try c.decodeIfPresent(String.self, forKey: .item)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        trace = try c.decodeIfPresent([Entry].self, forKey: .trace) ?? []
        conclusion = try c.decodeIfPresent(Conclusion.self, forKey: .conclusion)
        tally = try c.decodeIfPresent(Tally.self, forKey: .tally)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(agent, forKey: .agent)
        try c.encode(graphName, forKey: .graphName)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(thread, forKey: .thread)
        try c.encodeIfPresent(item, forKey: .item)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encode(trace, forKey: .trace)
        try c.encodeIfPresent(conclusion, forKey: .conclusion)
        try c.encodeIfPresent(tally, forKey: .tally)
    }

    // MARK: - The traversal feeding its record

    /// Fold one reported entry in. The SEALED-RECORD GUARD is the generalized zombie
    /// protection: once a record ended, nothing may write it (a cancelled traversal's late
    /// reports drop here even if a caller's own guards slipped). Same-`(ordinal, node)`
    /// reports replace, PRESERVING the stamps: first sight stamps `startedAt`; the first
    /// non-running report stamps `endedAt`; a re-emit never restamps.
    public mutating func note(_ entry: Entry, at now: Date = Date()) {
        guard endedAt == nil else { return }
        var merged = entry
        if let i = trace.firstIndex(where: { $0.ordinal == entry.ordinal && $0.node == entry.node }) {
            merged.startedAt = trace[i].startedAt
            merged.endedAt = trace[i].endedAt
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

    /// Amend the dispatch settlement tally — the ONE sanctioned post-seal write. The
    /// traversal that sent the set ends and seals; its items settle long after, and the
    /// counts must keep up. Counts only: trace, conclusion and stamps stay exactly as the
    /// traversal sealed them.
    public mutating func amendDispatchTally(settled: Int, total: Int, failed: Int) {
        tally = Tally(settled: settled, total: total, failed: failed)
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

    /// List order: live first (a traversing record is what the panel should be showing),
    /// then by start, newest first. Among the LIVE ones a BUILD traversal leads: a build
    /// runs for minutes while items come and go, and the head of the list is what the panel
    /// follows — an item starting mid-build must not take the canvas off the thread's spine.
    public static func ordered(_ runs: [SZAgentGraphRun]) -> [SZAgentGraphRun] {
        runs.sorted {
            if $0.isLive != $1.isLive { return $0.isLive }
            if $0.isLive, ($0.kind == .build) != ($1.kind == .build) { return $0.kind == .build }
            return $0.startedAt > $1.startedAt
        }
    }

    /// Cap the history (~50) — never a live record, whatever the burst. Two budgets rather
    /// than one: item traversals outnumber build traversals many to one, so a shared cap
    /// would let one busy afternoon evict every recorded build from the list AND from
    /// `runs.json`. Order-independent: the victim is the OLDEST ENDED record of its budget
    /// by its own clock, so the cap holds whatever list it is handed.
    public static func capped(_ runs: [SZAgentGraphRun],
                              builds: Int = 20, others: Int = 30) -> [SZAgentGraphRun] {
        var kept = runs
        for (isBuild, limit) in [(true, builds), (false, others)] {
            while kept.lazy.filter({ ($0.kind == .build) == isBuild }).count > limit,
                  let victim = oldestEnded(in: kept, isBuild: isBuild) {
                kept.remove(at: victim)
            }
        }
        return kept
    }

    /// The eviction victim within one budget: the oldest ENDED record, or nil when every
    /// record over the limit is still live.
    private static func oldestEnded(in runs: [SZAgentGraphRun], isBuild: Bool) -> Int? {
        runs.indices
            .filter { !runs[$0].isLive && (runs[$0].kind == .build) == isBuild }
            .min { runs[$0].startedAt < runs[$1].startedAt }
    }
}
