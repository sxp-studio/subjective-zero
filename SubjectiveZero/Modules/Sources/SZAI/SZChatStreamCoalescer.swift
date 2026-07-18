// SPDX-License-Identifier: AGPL-3.0-only
// Rate-limits a streaming agent turn's transcript writes. Provider stdout arrives in per-chunk
// bursts; sinking every burst straight into the observable store re-evaluated the whole chat panel
// at chunk rate for the life of the turn. This coalesces the two text lanes (reply / thinking —
// separate message fields, so buffering them independently preserves per-field order) and flushes
// at most ~15 Hz, with a short trailing flush so a burst-then-silence never sits unpainted.
//
// MainActor-isolated by design: it sits between the MainActor stream consumer and the MainActor
// store, so buffers need no locking and `finish()` is a plain synchronous final flush — a caller
// that awaits the consumer task is guaranteed the full text has been flushed.
import Foundation

@MainActor
public final class SZChatStreamCoalescer {
    private let flushInterval: Duration
    private let trailingDelay: Duration
    private let onReply: (String) -> Void
    private let onThinking: (String) -> Void

    private var pendingReply = ""
    private var pendingThinking = ""
    private var lastFlush: ContinuousClock.Instant
    private var trailing: Task<Void, Never>?
    private var finished = false

    public init(
        flushInterval: Duration = .milliseconds(66),
        trailingDelay: Duration = .milliseconds(80),
        onReply: @escaping (String) -> Void,
        onThinking: @escaping (String) -> Void
    ) {
        self.flushInterval = flushInterval
        self.trailingDelay = trailingDelay
        self.onReply = onReply
        self.onThinking = onThinking
        // Backdate so the very first chunk paints immediately — a turn's opening words matter most.
        self.lastFlush = .now - flushInterval
    }

    public func addReply(_ text: String) {
        guard !finished else { return }
        pendingReply += text
        flushOrArm()
    }

    public func addThinking(_ text: String) {
        guard !finished else { return }
        pendingThinking += text
        flushOrArm()
    }

    /// Final flush. Synchronous and idempotent; cancels any armed trailing flush so nothing can
    /// write after the caller has treated the turn as delivered.
    public func finish() {
        flush()
        finished = true
    }

    private func flushOrArm() {
        if ContinuousClock.now - lastFlush >= flushInterval {
            flush()
        } else if trailing == nil {
            // Armed at the FIRST unflushed data, not re-armed per chunk: the deadline stays
            // ≤ trailingDelay after that data arrived even under a steady sub-interval trickle.
            trailing = Task { [trailingDelay] in
                try? await Task.sleep(for: trailingDelay)
                guard !Task.isCancelled else { return }
                self.flush()
            }
        }
    }

    private func flush() {
        trailing?.cancel()
        trailing = nil
        if !pendingReply.isEmpty {
            onReply(pendingReply)
            pendingReply = ""
        }
        if !pendingThinking.isEmpty {
            onThinking(pendingThinking)
            pendingThinking = ""
        }
        lastFlush = .now
    }
}
