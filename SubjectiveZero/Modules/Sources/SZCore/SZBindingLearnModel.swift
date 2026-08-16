// SPDX-License-Identifier: AGPL-3.0-only
// The learn-gesture state machine: fed (seq, key, value01) samples from a controller node's
// `lastEvent`/`lastKey` outputs, it elects the control the user moves AFTER arming. The control that
// was already moving at arm time is excluded — a learn armed mid-gesture must not catch the previous
// knob still settling — and exclusion lifts once that control stays quiet for `exclusionQuiet`
// (a deliberate re-twist of the same knob can then win). Pure value logic: the caller owns time
// and polling, so every rule here is testable with injected clocks. Keys are opaque strings.
import Foundation

public struct SZBindingLearnModel: Equatable, Sendable {
    /// The control currently elected by the gesture, tracking its latest value. Last-wins across
    /// controls: moving the wrong control then the right one leaves the right one elected.
    public struct Candidate: Equatable, Sendable {
        public let key: String
        public var value01: Double
        public init(key: String, value01: Double) { self.key = key; self.value01 = value01 }
    }

    public let armedAt: Date
    /// How long the arm-time control must stay quiet before it may compete again.
    public let exclusionQuiet: TimeInterval
    /// The exclusion's hard deadline after arm. The arm-time rule protects against a knob still
    /// SETTLING when learn arms — a brief tail, not a performance. Without a cap, the natural
    /// gesture (arm, then immediately twist the knob you last touched — which IS the excluded one)
    /// extends the quiet-chain forever and reads as seconds of "nothing happens" until the user
    /// pauses, baffled (the hardware-checkpoint finding). Past the cap, a still-emitting excluded
    /// control is plainly the user's deliberate choice: it competes.
    public let exclusionCap: TimeInterval
    /// The control seen moving at arm time, while it is still held out of the election.
    public private(set) var excluded: String?
    public private(set) var candidate: Candidate?

    private var excludedLastSeen: Date
    private var lastSeq: Int

    /// `armEvent` is the source's last event at arm time (nil when the source has never emitted) —
    /// its control starts excluded, and only events with a LATER seq count at all.
    public init(armEvent: (seq: Int, key: String)?, at now: Date,
                exclusionQuiet: TimeInterval = 0.4, exclusionCap: TimeInterval = 0.8) {
        self.armedAt = now
        self.exclusionQuiet = exclusionQuiet
        self.exclusionCap = exclusionCap
        self.excluded = armEvent?.key
        self.excludedLastSeen = now
        self.lastSeq = armEvent?.seq ?? 0
    }

    /// Feed one observed sample; returns whether the candidate changed. Callers pass every poll — a
    /// seq at or below the last one fed is a stale read and a no-op. Polling sees only the latest
    /// event between ticks (seq may jump), which is fine: a moving control emits continuously, so it
    /// cannot hide between polls.
    @discardableResult
    public mutating func observe(seq: Int, key: String, value01: Double, at now: Date) -> Bool {
        guard seq > lastSeq else { return false }
        lastSeq = seq

        if let excluded, excluded == key {
            if now.timeIntervalSince(armedAt) < exclusionCap,
               now.timeIntervalSince(excludedLastSeen) < exclusionQuiet {
                // Still plausibly the arm-time gesture settling — keep it out and extend the chain
                // (but only inside the cap: a settle is a tail, not a performance).
                excludedLastSeen = now
                return false
            }
            // Quiet-then-back OR still going past the cap: a deliberate move. It competes.
            self.excluded = nil
        }

        if var current = candidate, current.key == key {
            current.value01 = value01
            candidate = current
        } else {
            candidate = Candidate(key: key, value01: value01)
        }
        return true
    }
}
