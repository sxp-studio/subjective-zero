// SPDX-License-Identifier: AGPL-3.0-only
// One RUN of an agent graph — a single message's whole journey, as a record: which agent
// received which kind, when, the ordered trace of everything it did (a dispatch visit
// carries its fleet's tally ON the entry, live while the set works), and how it concluded.
// The Agent Graph panel's RUNS list is `[SZAgentGraphRun]`; the host begins a record as a
// delivery starts, feeds it trace entries from the engine's notes, and seals it on the
// conclusion. The RULES live here as mutations so they are testable without a host: the
// sealed-record guard, the stamp-preserving merge, and the idempotent seal. Nothing writes
// a sealed record — the dispatch now waits inside its traversal, so the tally lands before
// the seal, and the post-seal amend the old send-and-conclude model needed is gone.
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
    /// For a `.work` traversal: the dispatched node id it handles.
    public var work: String?
    public var startedAt: Date
    /// nil while the traversal is still under way — the record is LIVE. Live records are
    /// never persisted (a crash mid-traversal loses the record; the transcript survives).
    public var endedAt: Date?
    /// The executed trace, in traversal order — loops unrolled, one entry per node visit.
    public var trace: [Entry]
    /// How the traversal ended — nil while live, stamped exactly once by `seal`.
    public var conclusion: Conclusion?
    public var isLive: Bool { endedAt == nil }

    public init(id: UUID, agent: String, graphName: String, kind: SZMessageKind,
                thread: UUID? = nil, work: String? = nil, startedAt: Date = Date(),
                endedAt: Date? = nil, trace: [Entry] = [], conclusion: Conclusion? = nil) {
        self.id = id
        self.agent = agent
        self.graphName = graphName
        self.kind = kind
        self.thread = thread
        self.work = work
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.trace = trace
        self.conclusion = conclusion
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
        /// A dispatch visit's fleet tally, amended on every settle WHILE the visit runs —
        /// per entry, because a retry loop visits the dispatch twice and each visit owns
        /// its own set.
        public var tally: Tally?
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

        // Tolerant both ways: an entry written before an optional field decodes with its
        // default, and an absent value is NOT encoded — no key that says nothing.
        private enum CodingKeys: String, CodingKey {
            case ordinal, node, phase, outcome, detail, tally, startedAt, endedAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ordinal = try c.decode(Int.self, forKey: .ordinal)
            node = try c.decode(String.self, forKey: .node)
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
        case id, agent, graphName, kind, thread, work, startedAt, endedAt, trace, conclusion
        /// The field's pre-rename spelling — read for tolerance, never written.
        case item
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        agent = try c.decode(String.self, forKey: .agent)
        graphName = try c.decode(String.self, forKey: .graphName)
        // Tolerant of retired kinds, by their old spellings: a pre-rename archive reads as
        // what it WAS ("chat" was prose, "item" was work, "settled" was the build's reply)
        // rather than sinking the whole sidecar or mislabeling its history.
        let rawKind = try c.decodeIfPresent(String.self, forKey: .kind)
        kind = rawKind.flatMap(SZMessageKind.init(rawValue:))
            ?? ["chat": .message, "item": .work, "settled": .build][rawKind ?? ""]
            ?? .build
        thread = try c.decodeIfPresent(UUID.self, forKey: .thread)
        work = try c.decodeIfPresent(String.self, forKey: .work)
            ?? c.decodeIfPresent(String.self, forKey: .item)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        trace = try c.decodeIfPresent([Entry].self, forKey: .trace) ?? []
        conclusion = try c.decodeIfPresent(Conclusion.self, forKey: .conclusion)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(agent, forKey: .agent)
        try c.encode(graphName, forKey: .graphName)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(thread, forKey: .thread)
        try c.encodeIfPresent(work, forKey: .work)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encode(trace, forKey: .trace)
        try c.encodeIfPresent(conclusion, forKey: .conclusion)
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
    /// runs for minutes while work comes and goes, and the head of the list is what the panel
    /// follows — an item starting mid-build must not take the canvas off the thread's spine.
    public static func ordered(_ runs: [SZAgentGraphRun]) -> [SZAgentGraphRun] {
        runs.sorted {
            if $0.isLive != $1.isLive { return $0.isLive }
            if $0.isLive, ($0.kind == .build) != ($1.kind == .build) { return $0.kind == .build }
            return $0.startedAt > $1.startedAt
        }
    }

    /// Cap the history (~50) — never a live record, whatever the burst. Two budgets rather
    /// than one: work traversals outnumber build traversals many to one, so a shared cap
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
