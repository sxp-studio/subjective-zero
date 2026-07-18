// SPDX-License-Identifier: AGPL-3.0-only
// The resource ledger's load-bearing invariants: atomic all-or-queue acquisition, FIFO +
// reservation fairness, idempotent release, cycle detection over holders ∪ reservers (including
// the reservation-induced shape a holder-only DFS misses), deadlines, and cancellation hygiene.
import Foundation
import Testing
@testable import SZCore

/// Let parked-acquire child tasks run their synchronous prefix on the main actor.
@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
@Test func atomicAcquireSuspendsHoldingNothing() async throws {
    let ledger = SZResourceLedger()
    let a = SZClaimToken(label: "a"), b = SZClaimToken(label: "b")
    let r1 = SZResourceID(key: "r1"), r2 = SZResourceID(key: "r2")

    #expect(ledger.tryAcquire([r1], as: a))
    let granted = Granted()
    let waiter = Task { @MainActor in
        try await ledger.acquire([r1, r2], as: b)
        granted.value = true
    }
    await settle()
    // b is parked wanting BOTH — and holds NEITHER: no partial hold while waiting.
    #expect(!granted.value)
    #expect(ledger.resources(heldBy: b).isEmpty)
    #expect(!ledger.isHeld(r2))
    #expect(ledger.anyWaiting)

    ledger.release([r1], by: a)
    await settle()
    #expect(granted.value)
    #expect(ledger.resources(heldBy: b) == [r1, r2])
    waiter.cancel()
}

@MainActor
@Test func reservationFairnessProtectsEarlierBigWaiter() async throws {
    let ledger = SZResourceLedger()
    let a = SZClaimToken(label: "a"), big = SZClaimToken(label: "big"), late = SZClaimToken(label: "late")
    let r1 = SZResourceID(key: "r1"), r2 = SZResourceID(key: "r2")

    #expect(ledger.tryAcquire([r1], as: a))
    let bigGranted = Granted()
    let waiter = Task { @MainActor in
        try await ledger.acquire([r1, r2], as: big)
        bigGranted.value = true
    }
    await settle()
    // r2 is free but reserved for the parked big waiter — a later tryAcquire must refuse.
    #expect(!ledger.tryAcquire([r2], as: late))
    #expect(ledger.blockers(of: [r2]).map(\.label) == ["big"])

    // A later parked acquire queues BEHIND the big waiter instead of starving it.
    let lateGranted = Granted()
    let lateWaiter = Task { @MainActor in
        try await ledger.acquire([r2], as: late)
        lateGranted.value = true
    }
    await settle()
    ledger.release([r1], by: a)
    await settle()
    #expect(bigGranted.value)
    #expect(!lateGranted.value)   // big got r2 first
    ledger.releaseAll(of: big)
    await settle()
    #expect(lateGranted.value)    // and late follows once big releases
    waiter.cancel()
    lateWaiter.cancel()
}

@MainActor
@Test func releaseIsIdempotentAndOwnerChecked() {
    let ledger = SZResourceLedger()
    let a = SZClaimToken(label: "a"), b = SZClaimToken(label: "b")
    let r = SZResourceID(key: "r")

    #expect(ledger.tryAcquire([r], as: a))
    ledger.release([r], by: b)          // not the holder — no-op
    #expect(ledger.holder(of: r) == a)
    ledger.release([r], by: a)
    ledger.release([r], by: a)          // double release — no-op, no crash
    ledger.releaseAll(of: a)            // and again via releaseAll
    #expect(!ledger.isHeld(r))
    #expect(!ledger.anyHeld)
}

@MainActor
@Test func tryAcquireIsReentrantForSameToken() {
    let ledger = SZResourceLedger()
    let a = SZClaimToken(label: "a")
    let r1 = SZResourceID(key: "r1"), r2 = SZResourceID(key: "r2")

    #expect(ledger.tryAcquire([r1], as: a))
    // Re-acquiring an already-held resource alongside a new one succeeds for the same token.
    #expect(ledger.tryAcquire([r1, r2], as: a))
    #expect(ledger.resources(heldBy: a) == [r1, r2])
}

@MainActor
@Test func twoPartyCycleDetectedWithLabels() async throws {
    let ledger = SZResourceLedger()
    let a = SZClaimToken(label: "run 'director'"), b = SZClaimToken(label: "chat turn 'blur'")
    let r1 = SZResourceID(key: "r1"), r2 = SZResourceID(key: "r2")

    #expect(ledger.tryAcquire([r1], as: a))
    #expect(ledger.tryAcquire([r2], as: b))
    let waiter = Task { @MainActor in try await ledger.acquire([r2], as: a) }   // a: holds r1, waits r2
    await settle()

    do {
        try await ledger.acquire([r1], as: b)   // b: holds r2, would wait on r1 → cycle
        Issue.record("expected wouldDeadlock")
    } catch let SZLedgerError.wouldDeadlock(cycle) {
        #expect(cycle.first == "chat turn 'blur'")
        #expect(cycle.last == "chat turn 'blur'")
        #expect(cycle.contains("run 'director'"))
    }
    waiter.cancel()
    await settle()
}

@MainActor
@Test func threePartyCycleDetected() async throws {
    let ledger = SZResourceLedger()
    let a = SZClaimToken(label: "a"), b = SZClaimToken(label: "b"), c = SZClaimToken(label: "c")
    let r1 = SZResourceID(key: "r1"), r2 = SZResourceID(key: "r2"), r3 = SZResourceID(key: "r3")

    #expect(ledger.tryAcquire([r1], as: a))
    #expect(ledger.tryAcquire([r2], as: b))
    #expect(ledger.tryAcquire([r3], as: c))
    let w1 = Task { @MainActor in try await ledger.acquire([r2], as: a) }   // a → b
    await settle()
    let w2 = Task { @MainActor in try await ledger.acquire([r3], as: b) }   // b → c
    await settle()

    await #expect(throws: SZLedgerError.self) {
        try await ledger.acquire([r1], as: c)   // c → a closes a→b→c→a
    }
    w1.cancel()
    w2.cancel()
    await settle()
}

@MainActor
@Test func reservationEdgeCycleDetected() async throws {
    // The shape a holder-only DFS misses: B1 holds X and awaits an ack that needs a DELIVERY to N
    // (N is free). Candidate B2 wants {X, N}: it waits on B1's hold of X and would RESERVE N,
    // blocking the delivery B1 waits for. Zero holder-cycles — but a real deadlock.
    let ledger = SZResourceLedger()
    let b1 = SZClaimToken(label: "b1"), b2 = SZClaimToken(label: "b2")
    let x = SZResourceID(key: "x"), n = SZResourceID(key: "n")

    #expect(ledger.tryAcquire([x], as: b1))
    let ack = try ledger.registerExternalWait(from: b1, on: [n], label: "ack on n")

    await #expect(throws: SZLedgerError.self) {
        try await ledger.acquire([x, n], as: b2)
    }
    ledger.removeExternalWait(ack)
    // With the ack edge gone the same acquire parks fine (and resolves when b1 releases).
    let granted = Granted()
    let waiter = Task { @MainActor in
        try await ledger.acquire([x, n], as: b2)
        granted.value = true
    }
    await settle()
    ledger.releaseAll(of: b1)
    await settle()
    #expect(granted.value)
    waiter.cancel()
}

@MainActor
@Test func externalWaitEdgesResolveAgainstLiveHolders() async throws {
    // Edges are never snapshotted: the same registration is safe or unsafe depending on who holds
    // the awaited resource AT REGISTRATION TIME after a hand-off.
    let ledger = SZResourceLedger()
    let a = SZClaimToken(label: "a"), b = SZClaimToken(label: "b")
    let r1 = SZResourceID(key: "r1"), r2 = SZResourceID(key: "r2")

    #expect(ledger.tryAcquire([r1], as: a))
    #expect(ledger.tryAcquire([r2], as: b))
    // a awaits an ack needing r2 (held by b) — fine, no cycle yet.
    let ack = try ledger.registerExternalWait(from: a, on: [r2], label: "ack")
    // b awaiting an ack needing r1 (held by a) WOULD close a→b→a. Dynamic edges catch it.
    #expect(throws: SZLedgerError.self) {
        _ = try ledger.registerExternalWait(from: b, on: [r1], label: "counter-ack")
    }
    ledger.removeExternalWait(ack)
    // After a releases r1, the same registration is safe.
    ledger.releaseAll(of: a)
    let ok = try ledger.registerExternalWait(from: b, on: [r1], label: "counter-ack")
    ledger.removeExternalWait(ok)
}

@MainActor
@Test func consumerSelfEdgeIsLegal() throws {
    // A consumer awaiting its own steer is a fold in its own control flow, not a lock.
    let ledger = SZResourceLedger()
    let run = SZClaimToken(label: "run")
    let reg = try ledger.registerExternalWait(from: run, onConsumer: run, label: "own steer")
    ledger.removeExternalWait(reg)
    #expect(!ledger.anyWaiting)
}

@MainActor
@Test func consumerEdgeParticipatesTransitively() async throws {
    // a → consumer b (ack), b → a (resource) must still be caught.
    let ledger = SZResourceLedger()
    let a = SZClaimToken(label: "a"), b = SZClaimToken(label: "b")
    let r = SZResourceID(key: "r")

    #expect(ledger.tryAcquire([r], as: a))
    let ack = try ledger.registerExternalWait(from: a, onConsumer: b, label: "steer to b")
    await #expect(throws: SZLedgerError.self) {
        try await ledger.acquire([r], as: b)
    }
    ledger.removeExternalWait(ack)
}

@MainActor
@Test func deadlineFiresNamingWantedAndHolders() async throws {
    let ledger = SZResourceLedger()
    let holder = SZClaimToken(label: "run 'implement graph'"), waiter = SZClaimToken(label: "w")
    let r = SZResourceID(key: "transcript/blur")

    #expect(ledger.tryAcquire([r], as: holder))
    do {
        try await ledger.acquire([r], as: waiter, deadline: .now + .milliseconds(40))
        Issue.record("expected deadlineExceeded")
    } catch let SZLedgerError.deadlineExceeded(wanted, heldBy) {
        #expect(wanted == ["transcript/blur"])
        #expect(heldBy == ["run 'implement graph'"])
    }
    // The expired waiter is fully removed — nothing dangles, nothing is reserved.
    #expect(!ledger.anyWaiting)
    #expect(ledger.tryAcquire([SZResourceID(key: "other")], as: waiter))
}

@MainActor
@Test func deadlineVersusGrantRaceIsOneShot() async throws {
    let ledger = SZResourceLedger()
    let a = SZClaimToken(label: "a"), b = SZClaimToken(label: "b")
    let r = SZResourceID(key: "r")

    #expect(ledger.tryAcquire([r], as: a))
    let granted = Granted()
    let waiter = Task { @MainActor in
        try await ledger.acquire([r], as: b, deadline: .now + .milliseconds(50))
        granted.value = true
    }
    await settle()
    ledger.release([r], by: a)   // grant wins the race
    await settle()
    #expect(granted.value)
    // Let the deadline racer fire after the grant — it must find nothing to resume (no crash).
    try await ContinuousClock().sleep(for: .milliseconds(80))
    #expect(ledger.holder(of: r) == b)
    waiter.cancel()
}

@MainActor
@Test func cancelledWaiterDropsReservationsAndRescans() async throws {
    let ledger = SZResourceLedger()
    let a = SZClaimToken(label: "a"), big = SZClaimToken(label: "big"), late = SZClaimToken(label: "late")
    let r1 = SZResourceID(key: "r1"), r2 = SZResourceID(key: "r2")

    #expect(ledger.tryAcquire([r1], as: a))
    let bigTask = Task { @MainActor in try await ledger.acquire([r1, r2], as: big) }
    await settle()
    let lateGranted = Granted()
    let lateTask = Task { @MainActor in
        try await ledger.acquire([r2], as: late)   // parked behind big's reservation
        lateGranted.value = true
    }
    await settle()
    #expect(!lateGranted.value)

    bigTask.cancel()   // big's reservation on r2 must die with it and the rescan must run
    await settle()
    #expect(lateGranted.value)
    #expect(await bigTask.result.isFailure)
    ledger.releaseAll(of: a)
    ledger.releaseAll(of: late)
    #expect(!ledger.anyWaiting)
    lateTask.cancel()
}

@MainActor
@Test func tryAcquireAfterReleaseAllDoesNotResurrect() {
    let ledger = SZResourceLedger()
    let run = SZClaimToken(label: "run")
    let r1 = SZResourceID(key: "r1"), r2 = SZResourceID(key: "r2")

    #expect(ledger.tryAcquire([r1, r2], as: run))
    ledger.releaseAll(of: run)                       // the eager cancelRun release
    #expect(!ledger.anyHeld)
    // A zombie-path tryAcquire under the dead token re-holds — and a second releaseAll settles it.
    #expect(ledger.tryAcquire([r1], as: run))
    ledger.releaseAll(of: run)                       // the zombie task's deferred release
    #expect(!ledger.anyHeld)
}

@MainActor
@Test func runShapedScenarioHoldsOnlyDeclaredResources() async throws {
    // A run claims [.run, director transcript, work-set node pairs]; an unrelated node's
    // transcript stays acquirable concurrently — "a run holds only the resources it touches".
    let ledger = SZResourceLedger()
    let run = SZClaimToken(label: "run"), chat = SZClaimToken(label: "chat turn")
    let nodeA = SZNodeID(), nodeB = SZNodeID()
    let runSet: Set<SZResourceID> = [
        .run, .transcript(.director), .node(nodeA), .transcript(.node(nodeA)),
    ]

    #expect(ledger.tryAcquire(runSet, as: run))
    #expect(ledger.isHeld(.run))
    #expect(ledger.holder(of: .transcript(.director)) == run)
    // Node B was never claimed — a chat turn takes it while the run is live.
    #expect(ledger.tryAcquire([.transcript(.node(nodeB)), .node(nodeB)], as: chat))
    // But the run's own node refuses a foreign claim.
    #expect(!ledger.tryAcquire([.node(nodeA)], as: chat))

    ledger.releaseAll(of: run)
    #expect(ledger.tryAcquire([.node(nodeA)], as: chat))
}

@MainActor
@Test func availabilityHookFiresOncePerRelease() async throws {
    let ledger = SZResourceLedger()
    let a = SZClaimToken(label: "a")
    let r1 = SZResourceID(key: "r1"), r2 = SZResourceID(key: "r2"), r3 = SZResourceID(key: "r3")
    let fired = Granted()
    var count = 0
    ledger.onAvailabilityChanged = { count += 1; fired.value = true }

    #expect(ledger.tryAcquire([r1, r2, r3], as: a))
    #expect(count == 0)          // acquiring frees nothing
    ledger.releaseAll(of: a)     // three resources drop → ONE notification
    #expect(count == 1)
    ledger.releaseAll(of: a)     // idempotent second release → nothing freed → no notification
    #expect(count == 1)
    #expect(fired.value)
}

/// Boxed flag for observing grants from child tasks without data-race warnings.
@MainActor
private final class Granted {
    var value = false
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}
