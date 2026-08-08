// SPDX-License-Identifier: AGPL-3.0-only
// THE thread supervisor — one pure value machine owning a thread's whole lifecycle. The
// previous architecture split this across four owners (a thread struct, the dispatch sets,
// the envelope states, and the ledger claim), derived termination from three of them, and
// used a nil task handle as a mutex; every confirmed bug of that campaign lived in the
// seams between those owners, and its tests drove a replica of the supervisor rather than
// the supervisor. Never again: this machine is the single home, hosts are its motor (they
// run traversals, deliver items, arm timers — and report back as events), and tests drive
// THE REAL THING with event lists.
//
// The model, stated once:
//  - ONE open dispatch set at a time, by construction. Dispatch is send-and-conclude (a
//    dispatch node has no out-edges), orders are minted only when the sending traversal
//    concludes, and the settled re-entry starts only when the set closes — so a set can
//    never overlap a traversal, and two sets can never overlap each other. The previous
//    architecture kept ≤1 operationally (a dictionary plus discipline, which is how the
//    serialization races existed at all); here it is structural.
//  - Exactly one settled reply per set: collected from item outcomes when the last lands,
//    or synthesized when the watchdog fires with stragglers marked timed-out. A closed
//    set drops every later event — keyed by set id, never node id, which is ambiguous
//    the moment a re-dispatch puts the same node in a younger set.
//  - Termination is structural and absorbing: a traversal concluding with no orders while
//    nothing is outstanding IS the ending, and `.concluded` answers every later event
//    with no commands — idempotent termination by construction, not by guard.
//  - All bounds are injected once (`Bounds`); the machine never reads an environment
//    variable. The host resolves those, exactly once, at its own boundary.
import Foundation

/// One dispatched work item as the machine orders it delivered: the node, which attempt
/// this delivery is (stamped from the machine's own per-item count, so no other agent's
/// step ordering can reframe an item's briefing), and the sender's note when there is one.
public struct SZDispatchOrder: Sendable, Equatable {
    public var node: String
    public var attempt: Int
    public var senderNote: String?
    public init(node: String, attempt: Int, senderNote: String? = nil) {
        self.node = node
        self.attempt = attempt
        self.senderNote = senderNote
    }
}

/// A concluding traversal's dispatch decision — WHO (a seat name) and WHAT (node ids),
/// exactly what the graph's dispatch step decided. Content, never engine knowledge: the
/// machine stamps attempts, mints the set, and orders delivery; it never second-guesses
/// the target or the items.
public struct SZDispatchIntent: Sendable, Equatable {
    public var target: String
    public var items: [String]
    /// Per-item sender notes, keyed by node id.
    public var notes: [String: String]
    public init(target: String, items: [String], notes: [String: String] = [:]) {
        self.target = target
        self.items = items
        self.notes = notes
    }
}

/// The one settled reply a dispatch set produces — collected or synthesized, never
/// neither and never both.
public struct SZSettledSummary: Sendable, Equatable {
    public var setID: Int
    /// The seat the items were dispatched to — the reply's sender.
    public var from: String
    /// Terminal outcome per node id, verbatim as settled or synthesized. An outcome not
    /// prefixed "ok" reads as a failure (the dispatch card's rule, kept in one place).
    public var outcomes: [String: String]
    /// The 1-based settled re-entry this reply triggers.
    public var round: Int
    public init(setID: Int, from: String, outcomes: [String: String], round: Int) {
        self.setID = setID
        self.from = from
        self.outcomes = outcomes
        self.round = round
    }
}

/// How one graph traversal ended, as the motor reports it — the machine's own dumb
/// vocabulary; the engine's conclusion type adapts to this at the host seam.
public enum SZTraversalEnding: Sendable, Equatable {
    case ended
    case failed(reason: String)
    case cancelled
    /// The graph REFUSED the work and said why — its own class, so a refusal never
    /// reads as a failure (nothing broke) nor as "complete" (the work was not done).
    case declined(reason: String)
    /// The traversal's own integrity broke (unknown step mid-flight).
    case defect(detail: String)
}

/// How the whole THREAD ended — what the conclude command carries and `.concluded` holds.
public enum SZThreadConclusion: Sendable, Equatable {
    case ended
    case failed(reason: String)
    case cancelled
    /// A refusal is its own ending — never a failure, never "run complete".
    case declined(reason: String)
    /// The leash a graph cannot remove, hit: reported loudly so a graph that ships
    /// without its own rounds gate never re-dispatches (and spends) forever.
    case roundCeiling(round: Int)
    case defect(detail: String)
}

/// One pure value-type state machine owning thread lifecycle. Feed it events, execute the
/// commands it returns, in order — that is the entire contract.
public struct SZThreadMachine: Sendable {
    /// Every bound the machine obeys, injected once at construction.
    public struct Bounds: Sendable, Equatable {
        /// The host leash a graph cannot remove: no thread survives past this many
        /// settled re-entries, whatever its graph declares.
        public var roundCeiling: Int
        /// The per-set watchdog delay — after this, a set that has not fully settled
        /// gets its reply synthesized. The guarantee, not an optimization.
        public var dispatchDeadline: Duration
        /// What a graph that declares no rounds cap buys.
        public var defaultRounds: Int
        public init(roundCeiling: Int, dispatchDeadline: Duration, defaultRounds: Int) {
            self.roundCeiling = roundCeiling
            self.dispatchDeadline = dispatchDeadline
            self.defaultRounds = defaultRounds
        }
    }

    public enum State: Sendable, Equatable {
        /// Constructed, not yet opened.
        case opening
        /// One director traversal in flight, entered at `kind`.
        case traversing(kind: SZMessageKind)
        /// The open set's items are out with the fleet; no traversal runs.
        case awaitingFleet
        /// Stopped mid-traversal: the ending already shipped with the stop's commands,
        /// and the cancelled traversal still owes its own conclusion (cancellation is
        /// cooperative — the motor's task unwinds and reports late). Absorbing,
        /// command-wise; the late conclusion graduates this to `.concluded` silently.
        case concluding
        /// Over. Absorbing: every later event is a no-op command-wise.
        case concluded(SZThreadConclusion)
    }

    /// Host → machine. The host observes; the machine decides.
    public enum Event: Sendable, Equatable {
        /// The thread opened. `graphRounds` is the graph's declared rounds cap (nil →
        /// `bounds.defaultRounds`); `handlesSettled` is whether the graph declares a
        /// settled entry — keyed on the DECLARATION, never on a graph's name.
        case opened(kind: SZMessageKind, graphRounds: Int?, handlesSettled: Bool)
        /// The in-flight traversal ended, with the dispatch its graph decided on
        /// (nil or empty items = none). Send-and-conclude: orders arrive WITH the
        /// conclusion, which is what makes one-set-at-a-time structural.
        case traversalConcluded(SZTraversalEnding, dispatch: SZDispatchIntent?)
        /// One item's work actually began (its member traversal opened).
        case itemDelivered(node: String, setID: Int)
        /// One item's terminal outcome, keyed to ITS OWN set — never matched by node
        /// id, which a re-dispatch makes ambiguous.
        case itemSettled(node: String, setID: Int, outcome: String)
        /// The watchdog the machine armed for this set fired.
        case watchdogFired(setID: Int)
        /// A steering note to fold into the NEXT traversal's brief.
        case absorbSteer(String)
        /// The user (or the host's teardown) wants the thread over, now.
        case stopRequested
    }

    /// Machine → host, returned from `handle` in execution order.
    public enum Command: Sendable, Equatable {
        /// Begin a director traversal entering at `kind`, carrying the steers drained
        /// so far. The ONLY way a traversal ever starts.
        case startTraversal(kind: SZMessageKind, round: Int, steers: [String])
        /// Deliver these orders to the target seat as one supervised set.
        case deliverItems(setID: Int, target: String, orders: [SZDispatchOrder])
        /// Arm the set's watchdog. The host MAY cancel the timer when the set closes —
        /// a fired watchdog on a closed set is absorbed either way, so correctness
        /// never depends on the cancel landing.
        case armWatchdog(setID: Int, after: Duration)
        /// Cancel these items' work — exactly what a timeout timed out (a straggler
        /// allowed to run on would later settle a set that isn't its own), or what a
        /// stop sweeps.
        case cancelItems(setID: Int, nodes: [String])
        /// The set's live tally for the dispatch card — on every settle AND every
        /// timeout, so the card counts up while items land.
        case amendTally(setID: Int, settled: Int, total: Int, failed: Int)
        /// The set's one settled reply — always immediately followed by the settled
        /// re-entry's `startTraversal` in the same command list.
        case deliverSettled(SZSettledSummary)
        /// Cancel the in-flight traversal (the stop path).
        case cancelTraversal
        /// The thread's ending — the host's ceremony (narration, sweeps, claim release)
        /// hangs off this, exactly once per thread. Steers nothing consumed ride it so
        /// the ceremony can report them.
        case conclude(SZThreadConclusion, unconsumedSteers: [String])
    }

    public private(set) var state: State = .opening
    /// Which settled re-entry the NEXT delivery is, 1-based; 0 while the opening
    /// traversal runs.
    public private(set) var round = 0
    /// Node id → dispatch attempts. Per-item by construction: stamped into each order
    /// as it is minted, accumulated across sets.
    public private(set) var attempts: [String: Int] = [:]

    private let bounds: Bounds
    /// min(graph's rounds cap, host ceiling), resolved once at `opened`.
    private var maxRounds = 0
    private var handlesSettled = true
    /// The last traversal's conclusion — what a retry-less thread's ending maps from.
    private var lastConclusion: SZTraversalEnding?
    private var openSet: DispatchSet?
    private var nextSetID = 1
    private var pendingSteers: [String] = []

    /// The one in-flight dispatch set. Everything here is machine bookkeeping — member
    /// traversal records, envelopes and timers stay host-side, keyed by `id`.
    private struct DispatchSet: Sendable {
        let id: Int
        let target: String
        /// The dispatched node ids, in order, deduplicated — the tally's total.
        let members: [String]
        var outstanding: Set<String>
        var delivered: Set<String> = []
        var outcomes: [String: String] = [:]
    }

    public init(bounds: Bounds) {
        self.bounds = bounds
    }

    /// Feed one event; execute the returned commands in order. Events a state declares
    /// no entry for — late settles against closed sets, zombie conclusions, foreign set
    /// ids, anything after conclusion — return no commands and change nothing.
    public mutating func handle(_ event: Event) -> [Command] {
        switch event {
        case .absorbSteer(let text):
            // Queued for the NEXT traversal in any live state; after the ending the
            // machine is absorbing (the conclude command already swept what it held).
            switch state {
            case .concluding, .concluded: break
            default: pendingSteers.append(text)
            }
            return []

        case .opened(let kind, let graphRounds, let handlesSettled):
            guard case .opening = state else { return [] }
            maxRounds = min(graphRounds ?? bounds.defaultRounds, bounds.roundCeiling)
            self.handlesSettled = handlesSettled
            state = .traversing(kind: kind)
            return [.startTraversal(kind: kind, round: round, steers: drainSteers())]

        case .traversalConcluded(let conclusion, let dispatch):
            switch state {
            case .traversing:
                lastConclusion = conclusion
                let members = dedupe(dispatch?.items ?? [])
                guard let dispatch, !members.isEmpty, case .ended = conclusion else {
                    // No orders, nothing outstanding (structural: a set never overlaps a
                    // traversal) — this conclusion IS the thread's ending. A dispatch
                    // riding a failed/cancelled conclusion is refused the same way: only
                    // an .ended traversal opens a set, so a failure can never park the
                    // thread awaiting a fleet it should not have sent.
                    return concludeNow(threadEnding(of: conclusion))
                }
                let set = DispatchSet(id: nextSetID, target: dispatch.target,
                                      members: members, outstanding: Set(members))
                nextSetID += 1
                openSet = set
                var orders: [SZDispatchOrder] = []
                for node in members {
                    let attempt = (attempts[node] ?? 0) + 1
                    attempts[node] = attempt
                    orders.append(.init(node: node, attempt: attempt,
                                        senderNote: dispatch.notes[node]))
                }
                state = .awaitingFleet
                return [.deliverItems(setID: set.id, target: set.target, orders: orders),
                        .armWatchdog(setID: set.id, after: bounds.dispatchDeadline)]
            case .concluding:
                // The cancelled traversal's owed conclusion: graduate, resurrect nothing
                // — whatever the zombie claims to have concluded or dispatched.
                state = .concluded(.cancelled)
                return []
            default:
                return []
            }

        case .itemDelivered(let node, let setID):
            guard case .awaitingFleet = state, var set = openSet, set.id == setID,
                  set.members.contains(node) else { return [] }
            set.delivered.insert(node)
            openSet = set
            return []

        case .itemSettled(let node, let setID, let outcome):
            // Keyed by set id, and only while the item is genuinely outstanding: a
            // late outcome against a closed set, a foreign set, or an already settled
            // member is dropped — exactly one outcome per item, one reply per set.
            guard case .awaitingFleet = state, var set = openSet, set.id == setID,
                  set.outstanding.contains(node) else { return [] }
            set.outstanding.remove(node)
            set.outcomes[node] = outcome
            openSet = set
            var commands = [tally(of: set)]
            if set.outstanding.isEmpty { commands += closeSet(set) }
            return commands

        case .watchdogFired(let setID):
            guard case .awaitingFleet = state, var set = openSet, set.id == setID
            else { return [] }
            let stragglers = set.outstanding.sorted()
            let seconds = bounds.dispatchDeadline.components.seconds
            for node in stragglers {
                set.outcomes[node] = "timedOut: no terminal report within \(seconds)s"
            }
            set.outstanding = []
            openSet = set
            // Cancel BEFORE the reply ships — a straggler allowed to run on would
            // later settle a set that isn't its own.
            return [.cancelItems(setID: set.id, nodes: stragglers), tally(of: set)]
                + closeSet(set)

        case .stopRequested:
            switch state {
            case .opening:
                return concludeNow(.cancelled)
            case .traversing:
                // Conclude immediately; the cancelled traversal's own conclusion is
                // still owed and `.concluding` absorbs it when (if ever) it lands.
                state = .concluding
                return [.cancelTraversal,
                        .conclude(.cancelled, unconsumedSteers: drainSteers())]
            case .awaitingFleet:
                var commands: [Command] = []
                if let set = openSet {
                    commands.append(.cancelItems(setID: set.id,
                                                 nodes: set.outstanding.sorted()))
                    openSet = nil
                }
                // No settled summary is synthesized — a stopped conversation just ends.
                return commands + concludeNow(.cancelled)
            case .concluding, .concluded:
                return []
            }
        }
    }

    // MARK: - Transitions

    /// The set is fully settled (collected or synthesized): ship the one reply and
    /// re-enter — or end, when the graph declares no settled entry or the leash is hit.
    private mutating func closeSet(_ set: DispatchSet) -> [Command] {
        openSet = nil
        round += 1
        guard handlesSettled else {
            // Declaration-keyed, like the retry hint: no settled entry means the set's
            // close ends the thread on the dispatching traversal's own conclusion.
            return concludeNow(threadEnding(of: lastConclusion ?? .ended))
        }
        guard round <= maxRounds else {
            return concludeNow(.roundCeiling(round: round))
        }
        let summary = SZSettledSummary(setID: set.id, from: set.target,
                                       outcomes: set.outcomes, round: round)
        state = .traversing(kind: .settled)
        return [.deliverSettled(summary),
                .startTraversal(kind: .settled, round: round, steers: drainSteers())]
    }

    private mutating func concludeNow(_ conclusion: SZThreadConclusion) -> [Command] {
        state = .concluded(conclusion)
        return [.conclude(conclusion, unconsumedSteers: drainSteers())]
    }

    // MARK: - Small pieces

    private func tally(of set: DispatchSet) -> Command {
        .amendTally(setID: set.id,
                    settled: set.outcomes.count,
                    total: set.members.count,
                    failed: set.outcomes.values.count { !($0 == "ok" || $0.hasPrefix("ok:")) })
    }

    private func threadEnding(of conclusion: SZTraversalEnding) -> SZThreadConclusion {
        switch conclusion {
        case .ended: .ended
        case .failed(let reason): .failed(reason: reason)
        case .cancelled: .cancelled
        case .declined(let reason): .declined(reason: reason)
        case .defect(let detail): .defect(detail: detail)
        }
    }

    private mutating func drainSteers() -> [String] {
        let drained = pendingSteers
        pendingSteers = []
        return drained
    }

    private func dedupe(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0).inserted }
    }
}
