// SPDX-License-Identifier: AGPL-3.0-only
// The resource ledger: the single home for "who may touch what right now". Activities (a run, one
// chat turn, one staged graph op, one queued-message delivery) claim named resources under a token;
// everything else — the UI's lock affordances, the busy flags, the mutation fence, the message
// pump's delivery gate — derives from the claims table instead of keeping its own boolean.
//
// Deadlock discipline (docs/AGENT_ORCHESTRATION.md, the future behavior-tree engine leans on this):
// - Acquisition is ATOMIC all-or-queue: a claimant declares its full set upfront and never holds a
//   partial set while waiting, so hold-and-wait between resource waiters is structurally impossible.
// - Waiters queue FIFO with reserved-for-earlier-waiter fairness: a resource wanted by an earlier
//   waiter is not grantable — not even via tryAcquire — to a later claimant, so a big multi-resource
//   acquire (a run) cannot be starved by a stream of small ones.
// - Every wait is cycle-checked AT REGISTRATION with edges resolved dynamically against the live
//   table, targeting holders AND reservers of the wanted resources (a reservation blocks exactly
//   like a hold, so it must count as an edge — see `SZResourceLedgerTests.reservationEdgeCycle`).
//   External waits (a message-ack awaiting a delivery or a consumer) register in the SAME graph, so
//   resource waits and ack waits deadlock-check together.
// - Waits carry an optional deadline and are task-cancellation-safe; both paths drop the waiter's
//   reservations and re-run the grant scan so nothing dangles.
// All state is MainActor-isolated; waits suspend as continuations and never block a thread.
import Foundation

/// A named lockable resource. String-keyed (like SZChatScope.key) so claims stay queryable and
/// loggable; the constructors below are the only key shapes in use.
public struct SZResourceID: Hashable, Sendable, CustomStringConvertible {
    public let key: String
    public init(key: String) { self.key = key }
    public var description: String { key }

    public static func transcript(_ scope: SZChatScope) -> SZResourceID {
        SZResourceID(key: "transcript/\(scope.key)")
    }
    public static func node(_ id: SZNodeID) -> SZResourceID {
        SZResourceID(key: "node/\(id.uuidString)")
    }
    /// The single staged split/merge slot.
    public static let graphOp = SZResourceID(key: "graph-op")
    /// The one-run-at-a-time slot.
    public static let run = SZResourceID(key: "run")
}

/// The identity of one activity that holds or waits on resources. The label is what every
/// diagnostic prints ("deadline exceeded … held by run 'implement graph'"), so make it a short
/// human phrase naming the activity, not a type name.
public struct SZClaimToken: Hashable, Sendable, CustomStringConvertible {
    public let id: UUID
    public let label: String
    public init(label: String) {
        self.id = UUID()
        self.label = label
    }
    public var description: String { label }
}

/// Handle for an externally-managed wait edge (a message-ack wait) registered into the ledger's
/// wait graph. The owner (SZMessageQueue) removes it when its own continuation resumes.
public struct SZWaitRegistration: Hashable, Sendable {
    public let id: UUID
}

public enum SZLedgerError: Error, Equatable, CustomStringConvertible {
    /// Registering this wait would close a cycle in the wait graph. The cycle lists token labels
    /// in path order, first == last, e.g. ["run 'director'", "chat turn 'node 3AF2'", "run 'director'"].
    case wouldDeadlock(cycle: [String])
    /// The wait's deadline passed. Names what was wanted and who held/reserved it at expiry.
    case deadlineExceeded(wanted: [String], heldBy: [String])

    public var description: String {
        switch self {
        case .wouldDeadlock(let cycle):
            "deadlock: \(cycle.joined(separator: " → "))"
        case .deadlineExceeded(let wanted, let heldBy):
            "deadline exceeded waiting for \(wanted.joined(separator: ", "))"
                + (heldBy.isEmpty ? "" : " — held by \(heldBy.joined(separator: ", "))")
        }
    }
}

@MainActor @Observable
public final class SZResourceLedger {
    /// The claims table. Exclusive claims only; a claim held by a token is reentrant for that same
    /// token (re-acquiring a resource you already hold is satisfied, without nesting — one release
    /// frees it) so composed call paths don't have to thread "did I already claim this".
    public private(set) var holders: [SZResourceID: SZClaimToken] = [:]

    /// Fired once (MainActor, after the grant rescan) whenever resources or reservations free up —
    /// the message pump's hook to retry deliveries. Never fired while a mutation is mid-flight.
    @ObservationIgnored public var onAvailabilityChanged: (() -> Void)?

    private struct Waiter {
        let id: UUID
        let token: SZClaimToken
        let wanted: Set<SZResourceID>
        let continuation: CheckedContinuation<Void, any Error>
        var deadlineTask: Task<Void, Never>?
    }

    private struct ExternalWait {
        enum Target {
            case resources(Set<SZResourceID>)
            case consumer(SZClaimToken)
        }
        let id: UUID
        let from: SZClaimToken
        let target: Target
        let label: String
    }

    @ObservationIgnored private var waiters: [Waiter] = []
    @ObservationIgnored private var externalWaits: [ExternalWait] = []

    public init() {}

    // MARK: - Queries

    public func isHeld(_ resource: SZResourceID) -> Bool { holders[resource] != nil }

    public func holder(of resource: SZResourceID) -> SZClaimToken? { holders[resource] }

    public func resources(heldBy token: SZClaimToken) -> Set<SZResourceID> {
        Set(holders.filter { $0.value == token }.keys)
    }

    public var anyHeld: Bool { !holders.isEmpty }

    /// The tokens currently standing between a claimant and this set: holders plus reservers
    /// (earlier waiters wanting any of the resources). For composing refusal reasons.
    public func blockers(of resources: Set<SZResourceID>) -> [SZClaimToken] {
        var seen = Set<SZClaimToken>()
        var out: [SZClaimToken] = []
        for r in resources {
            if let h = holders[r], seen.insert(h).inserted { out.append(h) }
        }
        for w in waiters where !w.wanted.isDisjoint(with: resources) {
            if seen.insert(w.token).inserted { out.append(w.token) }
        }
        return out
    }

    /// True while any waiter or external wait is parked. `clearPerProjectState` asserts this is
    /// false alongside `!anyHeld` — a dangling wait edge is as much a leak as a dangling hold.
    public var anyWaiting: Bool { !waiters.isEmpty || !externalWaits.isEmpty }

    // MARK: - Acquisition

    /// Claim the set if every resource is free (or already ours) and none is reserved by a parked
    /// waiter. Never suspends; returns false without side effects when blocked.
    @discardableResult
    public func tryAcquire(_ resources: Set<SZResourceID>, as token: SZClaimToken) -> Bool {
        guard grantable(resources, to: token, beforeWaiterIndex: waiters.count) else { return false }
        grant(resources, to: token)
        return true
    }

    /// Atomic multi-acquire: the full set is claimed in one step, or the caller suspends as ONE
    /// waiter for the whole set — never a partial hold. FIFO with reservation fairness. Throws
    /// `.wouldDeadlock` instead of parking a wait that would close a cycle, `.deadlineExceeded`
    /// when the optional deadline passes first, `CancellationError` on task cancellation.
    public func acquire(_ resources: Set<SZResourceID>, as token: SZClaimToken,
                        deadline: ContinuousClock.Instant? = nil) async throws {
        try Task.checkCancellation()
        if tryAcquire(resources, as: token) { return }
        if let cycle = cycleClosed(by: token, waitingOn: .resources(resources), reserves: true) {
            throw SZLedgerError.wouldDeadlock(cycle: cycle)
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: waiterID, token: token, wanted: resources,
                                      continuation: cont, deadlineTask: nil))
                if let deadline {
                    let racer = Task { [weak self] in
                        try? await ContinuousClock().sleep(until: deadline)
                        guard !Task.isCancelled else { return }
                        self?.expireWaiter(waiterID)
                    }
                    if let i = waiters.firstIndex(where: { $0.id == waiterID }) {
                        waiters[i].deadlineTask = racer
                    }
                }
            }
        } onCancel: {
            // Hops back to the MainActor; resolves correctly in either order relative to parking
            // (an already-parked waiter is removed and resumed; a not-yet-parked one was caught by
            // the Task.isCancelled check above).
            Task { @MainActor [weak self] in self?.cancelWaiter(waiterID) }
        }
    }

    /// Idempotent: resources not held by `token` are skipped, so the eager release in `cancelRun`
    /// plus the zombie task's deferred release settle cleanly (the drainPendingGraphOp pattern).
    public func release(_ resources: Set<SZResourceID>, by token: SZClaimToken) {
        var freed = false
        for r in resources where holders[r] == token {
            holders[r] = nil
            freed = true
        }
        guard freed else { return }
        rescanWaiters()
        onAvailabilityChanged?()
    }

    public func releaseAll(of token: SZClaimToken) {
        release(resources(heldBy: token), by: token)
    }

    // MARK: - External waits (message-ack edges)

    /// Register a wait edge for an ack that resolves when a DELIVERY to these resources runs —
    /// edges target their holders ∪ reservers, re-resolved dynamically on every later check.
    public func registerExternalWait(from token: SZClaimToken, on resources: Set<SZResourceID>,
                                     label: String) throws -> SZWaitRegistration {
        try registerExternalWait(from: token, target: .resources(resources), label: label)
    }

    /// Register a wait edge for an ack that resolves when a specific CONSUMER drains it (a `.steer`
    /// folded by the run). A direct self-edge is deliberately legal — a consumer awaiting its own
    /// steer is a fold in its own control flow, not a lock — but the edge still participates in
    /// transitive cycle checks for everyone else.
    public func registerExternalWait(from token: SZClaimToken, onConsumer consumer: SZClaimToken,
                                     label: String) throws -> SZWaitRegistration {
        try registerExternalWait(from: token, target: .consumer(consumer), label: label)
    }

    public func removeExternalWait(_ registration: SZWaitRegistration) {
        externalWaits.removeAll { $0.id == registration.id }
    }

    private func registerExternalWait(from token: SZClaimToken, target: ExternalWait.Target,
                                      label: String) throws -> SZWaitRegistration {
        if case .consumer(let consumer) = target, consumer == token {
            // Legal self-edge: skip the origin cycle check entirely (it would trivially flag).
        } else if let cycle = cycleClosed(by: token, waitingOn: target, reserves: false) {
            throw SZLedgerError.wouldDeadlock(cycle: cycle)
        }
        let wait = ExternalWait(id: UUID(), from: token, target: target, label: label)
        externalWaits.append(wait)
        return SZWaitRegistration(id: wait.id)
    }

    // MARK: - Grants

    /// A set is grantable to `token` when every resource is free (or held by `token` itself —
    /// reentrant) and no waiter parked before `beforeWaiterIndex` wants it (the reservation rule).
    private func grantable(_ resources: Set<SZResourceID>, to token: SZClaimToken,
                           beforeWaiterIndex bound: Int) -> Bool {
        for r in resources {
            if let h = holders[r], h != token { return false }
        }
        for (i, w) in waiters.enumerated() where i < bound && w.token != token {
            if !w.wanted.isDisjoint(with: resources) { return false }
        }
        return true
    }

    private func grant(_ resources: Set<SZResourceID>, to token: SZClaimToken) {
        for r in resources { holders[r] = token }
    }

    /// FIFO scan with reservation fairness: waiter i is granted only when its whole set is free
    /// and unwanted by waiters 0..<i. Restart after every grant — a grant never frees anything,
    /// but a removal-driven rescan can unblock multiple waiters in one pass.
    private func rescanWaiters() {
        var granted = true
        while granted {
            granted = false
            for (i, w) in waiters.enumerated() {
                guard grantable(w.wanted, to: w.token, beforeWaiterIndex: i) else { continue }
                waiters.remove(at: i)
                grant(w.wanted, to: w.token)
                w.deadlineTask?.cancel()
                w.continuation.resume()
                granted = true
                break
            }
        }
    }

    /// One-shot by construction: expiry, cancellation, and grant all remove the waiter from the
    /// list before resuming, and every path looks the waiter up in the list first — whoever wins
    /// the race resumes; everyone else finds nothing.
    private func expireWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        let w = waiters.remove(at: i)
        w.deadlineTask?.cancel()
        let wanted = w.wanted.map(\.key).sorted()
        let heldBy = blockers(of: w.wanted).map(\.label)
        w.continuation.resume(throwing: SZLedgerError.deadlineExceeded(wanted: wanted, heldBy: heldBy))
        // The dead waiter's reservations are gone — later waiters may now be grantable.
        rescanWaiters()
        onAvailabilityChanged?()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        let w = waiters.remove(at: i)
        w.deadlineTask?.cancel()
        w.continuation.resume(throwing: CancellationError())
        rescanWaiters()
        onAvailabilityChanged?()
    }

    // MARK: - Cycle detection

    /// A hypothetical reservation in force only while a cycle check runs: an `acquire` candidate
    /// would park at the FIFO tail and reserve its wanted set against everything that comes LATER —
    /// which includes every external delivery's future tryAcquire. Without modeling it, the
    /// reservation-induced cycle (B1 awaits a delivery to N; the candidate B2 waits on B1's hold
    /// AND reserves N) passes the check and deadlocks after parking.
    @ObservationIgnored private var probeWait: (token: SZClaimToken, wanted: Set<SZResourceID>)?

    /// Would parking `token` on `target` close a cycle? Edges are resolved against the LIVE table
    /// at call time (never snapshotted): a wait's blockers are the holders ∪ reservers of what it
    /// wants, so hand-offs and reservations are always current. Returns the cycle as token labels
    /// in path order (first == last) for the diagnostic, or nil when the wait is safe.
    private func cycleClosed(by token: SZClaimToken, waitingOn target: ExternalWait.Target,
                             reserves: Bool) -> [String]? {
        if reserves, case .resources(let wanted) = target {
            probeWait = (token, wanted)
        }
        defer { probeWait = nil }
        var path: [SZClaimToken] = [token]
        var visited = Set<SZClaimToken>()

        func dfs(_ current: SZClaimToken) -> Bool {
            for next in blockerTokens(of: current) {
                if next == token {
                    path.append(next)
                    return true
                }
                guard visited.insert(next).inserted else { continue }
                path.append(next)
                if dfs(next) { return true }
                path.removeLast()
            }
            return false
        }

        for start in targets(of: target, from: token, excludingOwnHolds: reserves) {
            if start == token { return [token.label, token.label] }
            guard visited.insert(start).inserted else { continue }
            path.append(start)
            if dfs(start) { return path.map(\.label) }
            path.removeLast()
        }
        return nil
    }

    /// Every token the given wait target is blocked by right now. `excludingOwnHolds` is true only
    /// for an ACQUIRE candidate's own edges: its holds are reentrant-satisfiable, so they don't
    /// block it. An EXTERNAL wait resolves via a third party (the pump's delivery under its own
    /// token), so the origin's own hold blocks it like anyone else's — a token holding the very
    /// resource its ack needs is a direct self-deadlock and must flag.
    private func targets(of target: ExternalWait.Target, from: SZClaimToken,
                         excludingOwnHolds: Bool = false) -> [SZClaimToken] {
        switch target {
        case .consumer(let consumer):
            return [consumer]
        case .resources(let resources):
            // Holders, plus every parked waiter wanting any of them: a reservation blocks a
            // delivery/tryAcquire exactly like a hold does.
            var seen = Set<SZClaimToken>()
            var out: [SZClaimToken] = []
            for r in resources {
                guard let h = holders[r], !(excludingOwnHolds && h == from) else { continue }
                if seen.insert(h).inserted { out.append(h) }
            }
            for w in waiters where w.token != from && !w.wanted.isDisjoint(with: resources) {
                if seen.insert(w.token).inserted { out.append(w.token) }
            }
            if let probe = probeWait, probe.token != from,
               !probe.wanted.isDisjoint(with: resources), seen.insert(probe.token).inserted {
                out.append(probe.token)
            }
            return out
        }
    }

    /// Union of blockers across every wait (parked acquire or external) currently owned by `token`.
    private func blockerTokens(of token: SZClaimToken) -> [SZClaimToken] {
        var seen = Set<SZClaimToken>()
        var out: [SZClaimToken] = []
        for (i, w) in waiters.enumerated() where w.token == token {
            for r in w.wanted {
                if let h = holders[r], h != token, seen.insert(h).inserted { out.append(h) }
            }
            for (j, earlier) in waiters.enumerated() where j < i && earlier.token != token {
                if !earlier.wanted.isDisjoint(with: w.wanted), seen.insert(earlier.token).inserted {
                    out.append(earlier.token)
                }
            }
        }
        for ext in externalWaits where ext.from == token {
            for t in targets(of: ext.target, from: token) where seen.insert(t).inserted {
                out.append(t)
            }
        }
        return out
    }
}
