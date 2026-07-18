// SPDX-License-Identifier: AGPL-3.0-only
// The message queue: the single home for "what is waiting to be said to whom". Every send that
// can't run its turn immediately — a composer message while the scope streams, a Director steer to
// a coding agent, a message to a node a run holds — becomes an envelope in a per-recipient FIFO
// with an explicit delivery state, instead of a rejection or a lossy single-slot dict.
//
// Intents describe DELIVERY SEMANTICS, never who the agent is (docs/AGENT_ORCHESTRATION.md):
// `.chat` is delivered by the host's pump as a real turn on the recipient scope once its resources
// free; `.steer` is never pumped — it waits for its consumer (the run's reconcile drain) to fold it
// into the recipient's next prompt. A `.control` intent is deliberately reserved, unbuilt.
//
// Ack waits (`awaitProcessed`) register edges in the SZResourceLedger's wait graph — the same graph
// resource waits live in — so a resource wait and a message wait can never silently deadlock each
// other: the cycle is caught at registration. `.chat` acks edge to the holders/reservers of the
// recipient's transcript (what blocks the delivery); `.steer` acks edge to the registered consumer
// token (what folds them), and a consumer awaiting its own steer is legal.
//
// Terminal envelopes LEAVE the FIFO on transition (a `.failed` head must never stall a scope) and
// move to a bounded in-memory tombstone list so status polling can still answer; after a restart a
// terminal message's status is honestly `unknown`.
import Foundation

public enum SZMessageDeliveryState: String, Codable, Sendable {
    case queued, delivering, processed, failed
}

public enum SZMessageIntent: String, Codable, Sendable {
    /// Deliver = run an agent turn on the recipient scope when it frees.
    case chat
    /// Fold into the recipient's next prompt; drained by its consumer, never pumped.
    case steer
}

public enum SZMessageQueueError: Error, Equatable {
    /// The awaited envelope was removed (scope cleared, project closed) before reaching a
    /// terminal state.
    case removed
    /// No live envelope or tombstone with that id (typically: enqueued before a restart).
    case unknownMessage
}

/// One queued message. `recipient`/`sender` are SZChatScope keys (or "user" for the composer) so
/// the queue stays agent-agnostic and queryable. `message` is the transcript-shaped content;
/// `transcriptMessageID` is the id of the bubble already appended to the recipient's transcript at
/// enqueue time — the redelivery-idempotence key (nil when no bubble was shown).
public struct SZMessageEnvelope: Identifiable, Sendable {
    public let id: UUID
    public let recipient: String
    public let sender: String?
    public let intent: SZMessageIntent
    public var message: SZChatMessage
    public let transcriptMessageID: UUID?
    public var state: SZMessageDeliveryState
    public var failureReason: String?
    /// Reserved for the await-the-reply pattern: a consumer may attach the reply content at
    /// `markProcessed`. Unused today; tombstone-only (never persisted).
    public var response: String?
    public let enqueuedAt: Date

    public init(id: UUID = UUID(), recipient: String, sender: String? = nil,
                intent: SZMessageIntent, message: SZChatMessage,
                transcriptMessageID: UUID? = nil, state: SZMessageDeliveryState = .queued,
                failureReason: String? = nil, enqueuedAt: Date = Date()) {
        self.id = id
        self.recipient = recipient
        self.sender = sender
        self.intent = intent
        self.message = message
        self.transcriptMessageID = transcriptMessageID
        self.state = state
        self.failureReason = failureReason
        self.enqueuedAt = enqueuedAt
    }
}

extension SZMessageEnvelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, recipient, sender, intent, message, transcriptMessageID, state, failureReason,
             response, enqueuedAt
    }

    // Append-tolerant like SZChatMessage: only `recipient` and `message` are hard-required — an
    // envelope missing either is undeliverable, so a partial entry fails decode and is skipped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        recipient = try c.decode(String.self, forKey: .recipient)
        sender = try c.decodeIfPresent(String.self, forKey: .sender)
        intent = try c.decodeIfPresent(SZMessageIntent.self, forKey: .intent) ?? .chat
        message = try c.decode(SZChatMessage.self, forKey: .message)
        transcriptMessageID = try c.decodeIfPresent(UUID.self, forKey: .transcriptMessageID)
        // A `.delivering` envelope saved mid-crash reloads as `.queued`: at-least-once redelivery.
        let raw = try c.decodeIfPresent(SZMessageDeliveryState.self, forKey: .state) ?? .queued
        state = raw == .delivering ? .queued : raw
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
        response = try c.decodeIfPresent(String.self, forKey: .response)
        enqueuedAt = try c.decodeIfPresent(Date.self, forKey: .enqueuedAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(recipient, forKey: .recipient)
        try c.encodeIfPresent(sender, forKey: .sender)
        try c.encode(intent, forKey: .intent)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(transcriptMessageID, forKey: .transcriptMessageID)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(failureReason, forKey: .failureReason)
        try c.encodeIfPresent(response, forKey: .response)
        try c.encode(enqueuedAt, forKey: .enqueuedAt)
    }
}

@MainActor @Observable
public final class SZMessageQueue {
    /// The live FIFO: `.queued` and `.delivering` envelopes only, in enqueue order (which is also
    /// per-recipient order). Terminal envelopes move to `tombstones` on transition. Public so the
    /// host (pump, reconcile drain, run-end sweep) can query without bespoke accessors; mutate
    /// only through the methods below.
    public private(set) var envelopes: [SZMessageEnvelope] = []

    /// Recently-terminal envelopes, newest last, for status polling. Bounded; memory-only.
    public private(set) var tombstones: [SZMessageEnvelope] = []
    private let tombstoneCap = 128

    /// The token that drains `.steer` envelopes right now (the run), registered by the host at
    /// run start and cleared at run end. `.steer` ack waits edge to it; nil (no run) parks the
    /// wait edge-less — only its deadline can end it early.
    @ObservationIgnored public var steerConsumer: SZClaimToken?

    /// Fired after any state change worth persisting (enqueue, mark*, removal) — the host's
    /// flush + pump hook.
    @ObservationIgnored public var onChange: (() -> Void)?

    private struct AckWaiter {
        let id: UUID
        let messageID: UUID
        let continuation: CheckedContinuation<SZMessageDeliveryState, any Error>
        var deadlineTask: Task<Void, Never>?
        let cleanup: () -> Void
    }

    @ObservationIgnored private var ackWaiters: [AckWaiter] = []

    public init() {}

    // MARK: - Queries

    public func pending(for recipientKey: String) -> [SZMessageEnvelope] {
        envelopes.filter { $0.recipient == recipientKey && $0.state == .queued }
    }

    /// Head of the recipient's FIFO — what the pump delivers next.
    public func next(for recipientKey: String) -> SZMessageEnvelope? {
        envelopes.first { $0.recipient == recipientKey && $0.state == .queued }
    }

    /// Delivery state across live queue + tombstones; nil = unknown (e.g. pre-restart id).
    public func state(of id: UUID) -> SZMessageDeliveryState? {
        envelope(for: id)?.state
    }

    public func envelope(for id: UUID) -> SZMessageEnvelope? {
        envelopes.first { $0.id == id } ?? tombstones.first { $0.id == id }
    }

    /// Recipient keys that currently have a queued head — the pump's scan set.
    public var recipientsWithPending: [String] {
        var seen = Set<String>()
        return envelopes.compactMap { e in
            guard e.state == .queued, seen.insert(e.recipient).inserted else { return nil }
            return e.recipient
        }
    }

    // MARK: - Mutations

    public func enqueue(_ envelope: SZMessageEnvelope) {
        envelopes.append(envelope)
        onChange?()
    }

    public func markDelivering(_ id: UUID) {
        guard let i = envelopes.firstIndex(where: { $0.id == id }) else { return }
        envelopes[i].state = .delivering
        onChange?()
    }

    /// `response` is the reserved reply-content slot (see header); pass nothing today.
    public func markProcessed(_ id: UUID, response: String? = nil) {
        finish(id) { envelope in
            envelope.state = .processed
            envelope.response = response
        }
    }

    public func markFailed(_ id: UUID, reason: String) {
        finish(id) { envelope in
            envelope.state = .failed
            envelope.failureReason = reason
        }
    }

    /// Requeue a terminal envelope for one more delivery attempt (the probation-retry path).
    /// No-op unless the id is a tombstone.
    public func requeue(_ id: UUID) {
        guard let i = tombstones.firstIndex(where: { $0.id == id }) else { return }
        var envelope = tombstones.remove(at: i)
        envelope.state = .queued
        envelope.failureReason = nil
        envelopes.append(envelope)
        onChange?()
    }

    /// Remove every envelope (live AND tombstoned) for a recipient — the scope was cleared or its
    /// node deleted. Removal is a terminal event: parked ack waiters resume throwing `.removed`.
    public func removeAll(for recipientKey: String) {
        let removedIDs = Set(envelopes.filter { $0.recipient == recipientKey }.map(\.id))
        guard !removedIDs.isEmpty || tombstones.contains(where: { $0.recipient == recipientKey })
        else { return }
        envelopes.removeAll { $0.recipient == recipientKey }
        tombstones.removeAll { $0.recipient == recipientKey }
        resumeWaiters(for: removedIDs) { $0.resume(throwing: SZMessageQueueError.removed) }
        onChange?()
    }

    /// Full in-memory reset (project switch/close). Never writes anything itself — the caller
    /// decides whether disk is touched (clearPerProjectState deliberately must NOT flush).
    public func reset() {
        let ids = Set(envelopes.map(\.id))
        envelopes.removeAll()
        tombstones.removeAll()
        resumeWaiters(for: ids) { $0.resume(throwing: SZMessageQueueError.removed) }
    }

    /// True while any ack waiter is parked — checked alongside the ledger's wait-graph-empty
    /// assertion at project teardown.
    public var anyAwaiting: Bool { !ackWaiters.isEmpty }

    // MARK: - Ack waits

    /// Suspend until the envelope reaches a terminal state, and return it (`.processed`/`.failed`
    /// — inspect `failureReason` via `envelope(for:)`). The wait registers an edge in `ledger`'s
    /// wait graph so it deadlock-checks against resource waits: `.chat` → the recipient
    /// transcript's holders/reservers, `.steer` → the current `steerConsumer` (self-edge legal).
    /// Throws `.wouldDeadlock` at registration, `.deadlineExceeded` when the optional deadline
    /// passes, `.removed` if the envelope is removed, `CancellationError` on task cancellation.
    public func awaitProcessed(_ id: UUID, as token: SZClaimToken, ledger: SZResourceLedger,
                               deadline: ContinuousClock.Instant? = nil) async throws
        -> SZMessageDeliveryState {
        guard let envelope = envelope(for: id) else { throw SZMessageQueueError.unknownMessage }
        if envelope.state == .processed || envelope.state == .failed { return envelope.state }
        try Task.checkCancellation()

        // Join the shared wait graph BEFORE parking — a cycle must fail the wait, not hang it.
        var registration: SZWaitRegistration?
        let ackLabel = "ack on message \(id.uuidString.prefix(8)) to \(envelope.recipient)"
        switch envelope.intent {
        case .chat:
            if let scope = SZChatScope(key: envelope.recipient) {
                registration = try ledger.registerExternalWait(
                    from: token, on: [.transcript(scope)], label: ackLabel)
            }
        case .steer:
            if let consumer = steerConsumer {
                registration = try ledger.registerExternalWait(
                    from: token, onConsumer: consumer, label: ackLabel)
            }
        }
        let cleanup: () -> Void = { [weak ledger] in
            if let registration { ledger?.removeExternalWait(registration) }
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                if Task.isCancelled {
                    cleanup()
                    cont.resume(throwing: CancellationError())
                    return
                }
                ackWaiters.append(AckWaiter(id: waiterID, messageID: id, continuation: cont,
                                            deadlineTask: nil, cleanup: cleanup))
                if let deadline {
                    let recipient = envelope.recipient
                    let racer = Task { [weak self, weak ledger] in
                        try? await ContinuousClock().sleep(until: deadline)
                        guard !Task.isCancelled else { return }
                        let heldBy: [String] =
                            if let ledger, let scope = SZChatScope(key: recipient) {
                                ledger.blockers(of: [.transcript(scope)]).map(\.label)
                            } else { [] }
                        self?.resumeWaiter(waiterID) {
                            $0.resume(throwing: SZLedgerError.deadlineExceeded(
                                wanted: ["message \(id.uuidString.prefix(8)) to \(recipient)"],
                                heldBy: heldBy))
                        }
                    }
                    if let i = ackWaiters.firstIndex(where: { $0.id == waiterID }) {
                        ackWaiters[i].deadlineTask = racer
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resumeWaiter(waiterID) { $0.resume(throwing: CancellationError()) }
            }
        }
    }

    // MARK: - Internals

    private func finish(_ id: UUID, _ transition: (inout SZMessageEnvelope) -> Void) {
        guard let i = envelopes.firstIndex(where: { $0.id == id }) else { return }
        var envelope = envelopes.remove(at: i)
        transition(&envelope)
        tombstones.append(envelope)
        if tombstones.count > tombstoneCap { tombstones.removeFirst(tombstones.count - tombstoneCap) }
        let state = envelope.state
        resumeWaiters(for: [id]) { $0.resume(returning: state) }
        onChange?()
    }

    /// One-shot by construction (the ledger's pattern): every resume path removes the waiter from
    /// the list first and looks it up before acting — the race loser finds nothing.
    private func resumeWaiter(_ waiterID: UUID,
                              _ resume: (CheckedContinuation<SZMessageDeliveryState, any Error>) -> Void) {
        guard let i = ackWaiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let w = ackWaiters.remove(at: i)
        w.deadlineTask?.cancel()
        w.cleanup()
        resume(w.continuation)
    }

    private func resumeWaiters(for messageIDs: Set<UUID>,
                               _ resume: (CheckedContinuation<SZMessageDeliveryState, any Error>) -> Void) {
        let matching = ackWaiters.filter { messageIDs.contains($0.messageID) }
        for w in matching {
            resumeWaiter(w.id, resume)
        }
    }
}
