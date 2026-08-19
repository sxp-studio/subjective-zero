// SPDX-License-Identifier: AGPL-3.0-only
// The ending vocabulary the RUNS list and the canvas terminal share. Two things it pins: which
// endings collapse into one word (stopped and interrupted are the same class — unfinished, nothing
// broken — and cannot co-occur), and which one must NOT (a refusal is a decision, not an accident,
// so it leaves the neutral capsule the other two share).
import Foundation
import Testing
import SZCore
@testable import SZUI

@Test func everyConclusionClassGetsItsOwnWord() {
    #expect(SZRunBadge.style(for: .ended).label == "end")
    #expect(SZRunBadge.style(for: .failed(reason: "the turn threw")).label == "failed")
    #expect(SZRunBadge.style(for: .defect(detail: "unknown node")).label == "failed")
    #expect(SZRunBadge.style(for: .cancelled).label == "stopped")
    #expect(SZRunBadge.style(for: .declined(reason: "no camera")).label == "declined")
    // A record with no conclusion cannot come out of the host's seal; drawn, not blank.
    #expect(SZRunBadge.style(for: nil).label == "end")
}

@Test func inFlightIsSpokenInTheSameTenseAsTheEndings() {
    // "live" was a broadcast word among build words; every other badge is a plain outcome.
    #expect(SZRunBadge.running().label == "running")
    #expect(!SZRunBadge.style(for: .ended).label.contains("live"))
}

@Test func anInterruptedRunSharesTheUserStopsBadge() {
    // Folded deliberately: both mean unfinished with nothing to fix, and `.interrupted` is only
    // ever stamped restoring a session that died — so it is never something you watch happen.
    #expect(SZRunBadge.style(for: .interrupted).label == "stopped")
    #expect(SZRunBadge.style(for: .interrupted).label == SZRunBadge.style(for: .cancelled).label)
    #expect(SZRunBadge.style(for: .interrupted).colour == SZAgentGraphStyle.neutral)
}

@Test func aRefusalIsNotDrawnLikeAnAccident() {
    // `declined` used to wear the same grey as "the app crashed under this". It is a DECISION —
    // the agents' own violet, the colour a step's ruling wears on the canvas.
    #expect(SZRunBadge.style(for: .declined(reason: "no camera")).colour == SZEdgeStyle.intentViolet)
    #expect(SZRunBadge.style(for: .declined(reason: "x")).colour != SZRunBadge.style(for: .cancelled).colour)
    // And still not a failure, which is the distinction the whole vocabulary exists to keep.
    #expect(SZRunBadge.style(for: .declined(reason: "x")).colour != SZAgentGraphStyle.failed)
}

@Test func theRestorePolicysRecordStillCarriesItsReason() {
    // The badge folds, the FACT does not: a record found live on disk seals interrupted, and the
    // detail that says why rides on the entries the seal flipped.
    var record = SZAgentGraphRun(id: UUID(), agent: "director",
                                 startedAt: Date(timeIntervalSinceReferenceDate: 100))
    record.note(.init(ordinal: 1, node: "send", phase: .running),
                at: Date(timeIntervalSinceReferenceDate: 101))
    record.sealInterrupted()
    #expect(record.conclusion == .interrupted)
    #expect(SZRunBadge.style(for: record.conclusion).label == "stopped")
    #expect(record.trace.contains { $0.detail == SZAgentGraphRun.interruptedDetail })
}
