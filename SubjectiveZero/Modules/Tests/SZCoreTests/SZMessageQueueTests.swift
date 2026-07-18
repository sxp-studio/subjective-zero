// SPDX-License-Identifier: AGPL-3.0-only
// The message queue's invariants: per-recipient FIFO, the no-overwrite regression (the old
// pendingDirectorMessages dict silently dropped a second steer to the same node), terminal
// envelopes leaving the FIFO, ack waits resolving on terminal transitions and joining the
// ledger's wait graph for cross-type deadlock detection.
import Foundation
import Testing
@testable import SZCore

@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

private func chatEnvelope(to recipient: String, text: String, sender: String? = "user",
                          intent: SZMessageIntent = .chat) -> SZMessageEnvelope {
    SZMessageEnvelope(recipient: recipient, sender: sender, intent: intent,
                      message: SZChatMessage(role: .user, text: text))
}

@MainActor
@Test func perRecipientFIFOWithInterleavedRecipients() {
    let queue = SZMessageQueue()
    queue.enqueue(chatEnvelope(to: "a", text: "a1"))
    queue.enqueue(chatEnvelope(to: "b", text: "b1"))
    queue.enqueue(chatEnvelope(to: "a", text: "a2"))
    queue.enqueue(chatEnvelope(to: "b", text: "b2"))

    #expect(queue.pending(for: "a").map(\.message.text) == ["a1", "a2"])
    #expect(queue.pending(for: "b").map(\.message.text) == ["b1", "b2"])
    #expect(queue.next(for: "a")?.message.text == "a1")
    #expect(Set(queue.recipientsWithPending) == ["a", "b"])

    // Delivering a's head keeps b's order untouched and a's next behind it.
    let a1 = queue.next(for: "a")!
    queue.markDelivering(a1.id)
    #expect(queue.next(for: "a")?.message.text == "a2")
    #expect(queue.next(for: "b")?.message.text == "b1")
}

@MainActor
@Test func twoSteersToOneNodeAreTwoEnvelopes() {
    // The pendingDirectorMessages regression: the dict overwrote; the queue must not.
    let queue = SZMessageQueue()
    let node = SZNodeID().uuidString
    queue.enqueue(chatEnvelope(to: node, text: "use a gaussian kernel", sender: "director",
                               intent: .steer))
    queue.enqueue(chatEnvelope(to: node, text: "and clamp the radius", sender: "director",
                               intent: .steer))

    let steers = queue.pending(for: node).filter { $0.intent == .steer }
    #expect(steers.map(\.message.text) == ["use a gaussian kernel", "and clamp the radius"])
}

@MainActor
@Test func terminalEnvelopesLeaveTheFIFO() {
    // A .failed head must not stall the scope's queue.
    let queue = SZMessageQueue()
    let first = chatEnvelope(to: "a", text: "first")
    queue.enqueue(first)
    queue.enqueue(chatEnvelope(to: "a", text: "second"))

    queue.markDelivering(first.id)
    queue.markFailed(first.id, reason: "provider exploded")
    #expect(queue.next(for: "a")?.message.text == "second")     // head advanced
    #expect(queue.state(of: first.id) == .failed)               // still answerable via tombstone
    #expect(queue.envelope(for: first.id)?.failureReason == "provider exploded")
    #expect(queue.envelopes.count == 1)                         // live FIFO holds only the second
}

@MainActor
@Test func requeueRevivesATombstoneOnce() {
    let queue = SZMessageQueue()
    let e = chatEnvelope(to: "a", text: "retry me")
    queue.enqueue(e)
    queue.markDelivering(e.id)
    queue.markFailed(e.id, reason: "stale session")

    queue.requeue(e.id)
    #expect(queue.state(of: e.id) == .queued)
    #expect(queue.envelope(for: e.id)?.failureReason == nil)
    #expect(queue.next(for: "a")?.id == e.id)
    queue.requeue(UUID())   // unknown id — no-op, no crash
}

@MainActor
@Test func stateOfUnknownMessageIsNilAndAwaitThrows() async {
    let queue = SZMessageQueue()
    let ledger = SZResourceLedger()
    #expect(queue.state(of: UUID()) == nil)
    await #expect(throws: SZMessageQueueError.unknownMessage) {
        _ = try await queue.awaitProcessed(UUID(), as: SZClaimToken(label: "w"), ledger: ledger)
    }
}

@MainActor
@Test func awaitProcessedResumesOnTerminalTransition() async throws {
    let queue = SZMessageQueue()
    let ledger = SZResourceLedger()
    let e = chatEnvelope(to: SZChatScope.directorKey, text: "hello")
    queue.enqueue(e)

    let result = Box<SZMessageDeliveryState?>(nil)
    let waiter = Task { @MainActor in
        result.value = try await queue.awaitProcessed(e.id, as: SZClaimToken(label: "w"),
                                                      ledger: ledger)
    }
    await settle()
    #expect(result.value == nil)
    #expect(queue.anyAwaiting)
    queue.markDelivering(e.id)
    queue.markProcessed(e.id)
    await settle()
    #expect(result.value == .processed)
    #expect(!queue.anyAwaiting)
    #expect(!ledger.anyWaiting)      // the ack edge was unregistered on resume
    waiter.cancel()

    // Awaiting an already-terminal envelope returns immediately.
    let done = try await queue.awaitProcessed(e.id, as: SZClaimToken(label: "w2"), ledger: ledger)
    #expect(done == .processed)
}

@MainActor
@Test func awaitProcessedFailureReturnsFailedState() async throws {
    let queue = SZMessageQueue()
    let ledger = SZResourceLedger()
    let e = chatEnvelope(to: SZChatScope.directorKey, text: "doomed")
    queue.enqueue(e)

    let waiter = Task { @MainActor in
        try await queue.awaitProcessed(e.id, as: SZClaimToken(label: "w"), ledger: ledger)
    }
    await settle()
    queue.markFailed(e.id, reason: "run ended before the steer was consumed")
    let state = try await waiter.value
    #expect(state == .failed)
    #expect(queue.envelope(for: e.id)?.failureReason == "run ended before the steer was consumed")
}

@MainActor
@Test func removeAllResumesWaitersThrowingRemoved() async throws {
    let queue = SZMessageQueue()
    let ledger = SZResourceLedger()
    let node = SZNodeID().uuidString
    let e = chatEnvelope(to: node, text: "orphaned")
    queue.enqueue(e)

    let waiter = Task { @MainActor in
        try await queue.awaitProcessed(e.id, as: SZClaimToken(label: "w"), ledger: ledger)
    }
    await settle()
    queue.removeAll(for: node)   // node deleted / transcript cleared
    await #expect(throws: SZMessageQueueError.removed) { try await waiter.value }
    #expect(queue.envelope(for: e.id) == nil)   // gone from live AND tombstones
    #expect(!ledger.anyWaiting)                 // no dangling wait edge
    #expect(!queue.anyAwaiting)
}

@MainActor
@Test func resetResumesEverythingAndClearsState() async throws {
    let queue = SZMessageQueue()
    let ledger = SZResourceLedger()
    let e = chatEnvelope(to: SZChatScope.directorKey, text: "swept")
    queue.enqueue(e)
    queue.markDelivering(e.id)
    let waiter = Task { @MainActor in
        try await queue.awaitProcessed(e.id, as: SZClaimToken(label: "w"), ledger: ledger)
    }
    await settle()

    queue.reset()
    await #expect(throws: SZMessageQueueError.removed) { try await waiter.value }
    #expect(queue.envelopes.isEmpty)
    #expect(queue.tombstones.isEmpty)
    #expect(!queue.anyAwaiting)
}

@MainActor
@Test func chatAckJoinsLedgerWaitGraph() async throws {
    // Cross-type deadlock: token A holds the director transcript and awaits an ack on a message
    // TO the director scope — the delivery needs the very resource A holds. The registration
    // itself must throw, not park a wait that can never resolve.
    let queue = SZMessageQueue()
    let ledger = SZResourceLedger()
    let a = SZClaimToken(label: "director turn")
    #expect(ledger.tryAcquire([.transcript(.director)], as: a))

    let e = chatEnvelope(to: SZChatScope.directorKey, text: "to myself")
    queue.enqueue(e)
    await #expect(throws: SZLedgerError.self) {
        _ = try await queue.awaitProcessed(e.id, as: a, ledger: ledger)
    }

    // A DIFFERENT waiter is fine — its edge targets A, no cycle.
    let other = SZClaimToken(label: "other")
    let waiter = Task { @MainActor in
        try await queue.awaitProcessed(e.id, as: other, ledger: ledger)
    }
    await settle()
    queue.markProcessed(e.id)
    #expect(try await waiter.value == .processed)
}

@MainActor
@Test func runAwaitsItsOwnSteerLegally() async throws {
    // The consumer self-edge: a Director/BT leaf under the run token awaits a steer the run
    // itself will fold at reconcile. Legal — resolves on drain, fails on the run-end sweep.
    let queue = SZMessageQueue()
    let ledger = SZResourceLedger()
    let run = SZClaimToken(label: "run")
    // The steer consumer IS whoever holds `.run` — no mirror state to register.
    #expect(ledger.tryAcquire([.run, .transcript(.director)], as: run))

    let node = SZNodeID().uuidString
    let steer = chatEnvelope(to: node, text: "steer", sender: "director", intent: .steer)
    queue.enqueue(steer)

    let result = Box<SZMessageDeliveryState?>(nil)
    let waiter = Task { @MainActor in
        result.value = try await queue.awaitProcessed(steer.id, as: run, ledger: ledger)
    }
    await settle()
    #expect(result.value == nil)          // parked, not deadlock-refused
    queue.markProcessed(steer.id)         // the reconcile drain
    await settle()
    #expect(result.value == .processed)
    waiter.cancel()

    // The sweep shape: an unconsumed steer failed at run end resumes waiters with .failed.
    let orphan = chatEnvelope(to: node, text: "late steer", sender: "director", intent: .steer)
    queue.enqueue(orphan)
    let sweepResult = Box<SZMessageDeliveryState?>(nil)
    let sweepWaiter = Task { @MainActor in
        sweepResult.value = try await queue.awaitProcessed(orphan.id, as: run, ledger: ledger)
    }
    await settle()
    queue.markFailed(orphan.id, reason: "run ended before the steer was consumed")
    await settle()
    #expect(sweepResult.value == .failed)
    sweepWaiter.cancel()
}

@MainActor
@Test func steerAckEdgesToConsumerDetectsCounterCycle() async throws {
    // Transitive shape: the run awaits a resource a chat turn holds, while the chat turn awaits
    // a steer only the run can consume → cycle through the consumer edge.
    let queue = SZMessageQueue()
    let ledger = SZResourceLedger()
    let run = SZClaimToken(label: "run"), chat = SZClaimToken(label: "chat turn")
    let node = SZNodeID()
    #expect(ledger.tryAcquire([.run], as: run))   // the consumer edge derives from the .run holder
    #expect(ledger.tryAcquire([.node(node)], as: chat))

    let steer = chatEnvelope(to: node.uuidString, text: "steer", sender: "director", intent: .steer)
    queue.enqueue(steer)
    let ackWaiter = Task { @MainActor in
        try await queue.awaitProcessed(steer.id, as: chat, ledger: ledger)   // chat → run edge
    }
    await settle()

    await #expect(throws: SZLedgerError.self) {
        try await ledger.acquire([.node(node)], as: run)   // run → chat closes the cycle
    }
    queue.markProcessed(steer.id)
    _ = try await ackWaiter.value
}

@MainActor
@Test func onChangeFiresForPersistableTransitions() {
    let queue = SZMessageQueue()
    var count = 0
    queue.onChange = { count += 1 }

    let e = chatEnvelope(to: "a", text: "m")
    queue.enqueue(e)            // 1
    queue.markDelivering(e.id)  // 2
    queue.markProcessed(e.id)   // 3
    queue.removeAll(for: "a")   // 4 (tombstone dropped)
    queue.removeAll(for: "a")   // nothing left — no fire
    #expect(count == 4)
}

/// Boxed value for observing async results without data-race warnings.
@MainActor
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
