// SPDX-License-Identifier: AGPL-3.0-only
// THE dispatch-set supervisor — one pure value machine owning the fleet's lifecycle while
// a traversal's dispatch node waits. It used to own the whole thread (rounds, settled
// re-entries, the thread's conclusion) back when a dispatch concluded on send and the
// reply re-entered the graph as a new message; a dispatch now WAITS inside its own
// traversal, so the journey's shape belongs to the graph again (a retry round is a leashed
// edge, an ending is the traversal's own conclusion) and what remains here is exactly the
// part that must never be reinvented per host: set supervision. Hosts are its motor — they
// deliver items, arm timers, and report back as events — and tests drive THE REAL THING
// with event lists.
//
// The model, stated once:
//  - ONE open set at a time, structurally: the engine is sequential and a dispatch node
//    holds the traversal until its set closes, so a second set cannot be minted while one
//    is open. The machine still refuses one defensively.
//  - Exactly one settled summary per set: collected from item outcomes when the last
//    lands, or synthesized when the watchdog fires with stragglers marked timed-out. A
//    closed set drops every later event — keyed by set id, never node id, which is
//    ambiguous the moment a re-dispatch puts the same node in a younger set.
//  - Attempts accumulate per item ACROSS sets (a retry loop re-dispatches the same node),
//    stamped into each order as it is minted, so no other agent's step ordering can
//    reframe an item's briefing.
//  - All bounds are injected once (`Bounds`); the machine never reads an environment
//    variable. The host resolves those, exactly once, at its own boundary.
import Foundation

/// One dispatched work item as the machine orders it delivered: the node, which attempt
/// this delivery is (stamped from the machine's own per-item count), and the sender's
/// note when there is one.
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

/// A dispatch node's decision — WHO (a seat name) and WHAT (node ids), exactly what the
/// graph declared. Content, never engine knowledge: the machine stamps attempts, mints
/// the set, and orders delivery; it never second-guesses the target or the items.
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

/// The one settled summary a dispatch set produces — collected or synthesized, never
/// neither and never both. This is what the waiting dispatch node's `settled` outcome
/// carries back into the traversal.
public struct SZSettledSummary: Sendable, Equatable {
    public var setID: Int
    /// The seat the items were dispatched to.
    public var from: String
    /// Terminal outcome per node id, verbatim as settled or synthesized. An outcome not
    /// prefixed "ok" reads as a failure (the dispatch card's rule, kept in one place).
    public var outcomes: [String: String]
    /// Which set of the traversal this was, 1-based — round 2 is the retry loop's second
    /// pass, and the reconcile brief's `{{round}}` reads it.
    public var round: Int
    public init(setID: Int, from: String, outcomes: [String: String], round: Int) {
        self.setID = setID
        self.from = from
        self.outcomes = outcomes
        self.round = round
    }

    /// The card's counts, derived once here so every reader agrees.
    public var failedCount: Int {
        outcomes.values.count { !($0 == "ok" || $0.hasPrefix("ok:")) }
    }
}

/// How one graph traversal ended, as the motor reports it — the record seam's dumb
/// vocabulary; the engine's conclusion type adapts to this at the host boundary.
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

/// One pure value-type state machine owning dispatch-set lifecycle. Feed it events,
/// execute the commands it returns, in order — that is the entire contract.
public struct SZThreadMachine: Sendable {
    /// Every bound the machine obeys, injected once at construction.
    public struct Bounds: Sendable, Equatable {
        /// The per-set watchdog delay — after this, a set that has not fully settled
        /// gets its summary synthesized. The guarantee, not an optimization.
        public var dispatchDeadline: Duration
        public init(dispatchDeadline: Duration) {
            self.dispatchDeadline = dispatchDeadline
        }
    }

    public enum State: Sendable, Equatable {
        /// No set open — between dispatches, or before the first.
        case idle
        /// The open set's items are out with the fleet.
        case awaitingFleet
        /// Stopped. Absorbing: every later event is a no-op command-wise.
        case stopped
    }

    /// Host → machine. The host observes; the machine decides.
    public enum Event: Sendable, Equatable {
        /// A dispatch node fired: mint the set and order delivery.
        case dispatched(SZDispatchIntent)
        /// One item's work actually began (its member traversal opened).
        case itemDelivered(node: String, setID: Int)
        /// One item's terminal outcome, keyed to ITS OWN set — never matched by node
        /// id, which a re-dispatch makes ambiguous.
        case itemSettled(node: String, setID: Int, outcome: String)
        /// The watchdog the machine armed for this set fired.
        case watchdogFired(setID: Int)
        /// The user (or the host's teardown) wants everything over, now.
        case stopRequested
    }

    /// Machine → host, returned from `handle` in execution order.
    public enum Command: Sendable, Equatable {
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
        /// The set's one summary — what the waiting dispatch node resumes with. A
        /// stopped set ships none: the traversal's cancellation is the ending.
        case settled(SZSettledSummary)
    }

    public private(set) var state: State = .idle
    /// How many sets have closed, 1-based on the summary — the retry loop's "round".
    public private(set) var round = 0
    /// Node id → dispatch attempts. Per-item by construction: stamped into each order
    /// as it is minted, accumulated across sets.
    public private(set) var attempts: [String: Int] = [:]

    private let bounds: Bounds
    private var openSet: DispatchSet?
    private var nextSetID = 1

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
    /// no entry for — late settles against closed sets, foreign set ids, anything after
    /// a stop — return no commands and change nothing.
    public mutating func handle(_ event: Event) -> [Command] {
        switch event {
        case .dispatched(let intent):
            // Sequential by construction (a dispatch node holds its traversal), refused
            // defensively: a second set while one is open would orphan the first.
            guard case .idle = state else { return [] }
            let members = dedupe(intent.items)
            guard !members.isEmpty else { return [] }
            let set = DispatchSet(id: nextSetID, target: intent.target,
                                  members: members, outstanding: Set(members))
            nextSetID += 1
            openSet = set
            var orders: [SZDispatchOrder] = []
            for node in members {
                let attempt = (attempts[node] ?? 0) + 1
                attempts[node] = attempt
                orders.append(.init(node: node, attempt: attempt,
                                    senderNote: intent.notes[node]))
            }
            state = .awaitingFleet
            return [.deliverItems(setID: set.id, target: set.target, orders: orders),
                    .armWatchdog(setID: set.id, after: bounds.dispatchDeadline)]

        case .itemDelivered(let node, let setID):
            guard case .awaitingFleet = state, var set = openSet, set.id == setID,
                  set.members.contains(node) else { return [] }
            set.delivered.insert(node)
            openSet = set
            return []

        case .itemSettled(let node, let setID, let outcome):
            // Keyed by set id, and only while the item is genuinely outstanding: a
            // late outcome against a closed set, a foreign set, or an already settled
            // member is dropped — exactly one outcome per item, one summary per set.
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
            for node in stragglers {
                set.outcomes[node] = "timedOut: no terminal report within \(deadlineText)"
            }
            set.outstanding = []
            openSet = set
            // Cancel BEFORE the summary ships — a straggler allowed to run on would
            // later settle a set that isn't its own.
            return [.cancelItems(setID: set.id, nodes: stragglers), tally(of: set)]
                + closeSet(set)

        case .stopRequested:
            switch state {
            case .awaitingFleet:
                var commands: [Command] = []
                if let set = openSet {
                    commands.append(.cancelItems(setID: set.id,
                                                 nodes: set.outstanding.sorted()))
                    openSet = nil
                }
                // No summary is synthesized — the waiting traversal is being cancelled,
                // and a stopped conversation just ends.
                state = .stopped
                return commands
            case .idle:
                state = .stopped
                return []
            case .stopped:
                return []
            }
        }
    }

    // MARK: - Transitions

    /// The set is fully settled (collected or synthesized): ship the one summary the
    /// waiting dispatch node resumes with.
    private mutating func closeSet(_ set: DispatchSet) -> [Command] {
        openSet = nil
        round += 1
        state = .idle
        return [.settled(SZSettledSummary(setID: set.id, from: set.target,
                                          outcomes: set.outcomes, round: round))]
    }

    // MARK: - Small pieces

    /// The dispatch deadline as the synthesized outcome states it — millisecond precision,
    /// so a sub-second bound reads "250ms", a fractional one "1.5s", never a truncated "0s".
    private var deadlineText: String {
        let components = bounds.dispatchDeadline.components
        let milliseconds = components.seconds * 1000
            + components.attoseconds / 1_000_000_000_000_000
        if milliseconds % 1000 == 0 { return "\(milliseconds / 1000)s" }
        if milliseconds < 1000 { return "\(milliseconds)ms" }
        return "\(Double(milliseconds) / 1000)s"
    }

    private func tally(of set: DispatchSet) -> Command {
        .amendTally(setID: set.id,
                    settled: set.outcomes.count,
                    total: set.members.count,
                    failed: set.outcomes.values.count { !($0 == "ok" || $0.hasPrefix("ok:")) })
    }

    private func dedupe(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0).inserted }
    }
}
