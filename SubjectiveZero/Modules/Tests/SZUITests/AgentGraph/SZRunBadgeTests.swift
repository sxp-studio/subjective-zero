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
    #expect(SZRunBadge.style(for: .ended).label == "complete")
    #expect(SZRunBadge.style(for: .failed(reason: "the turn threw")).label == "failed")
    #expect(SZRunBadge.style(for: .defect(detail: "unknown node")).label == "failed")
    #expect(SZRunBadge.style(for: .cancelled).label == "stopped")
    #expect(SZRunBadge.style(for: .declined(reason: "no camera")).label == "declined")
    // A record with no conclusion cannot come out of the host's seal; drawn, not blank.
    #expect(SZRunBadge.style(for: nil).label == "complete")
}

@Test func inFlightIsSpokenInTheSameTenseAsTheEndings() {
    // "live" was a broadcast word among build words; every other badge is a plain outcome.
    #expect(SZRunBadge.running().label == "running")
    #expect(!SZRunBadge.style(for: .ended).label.contains("live"))
}

@Test func stillGoingAndFinishedWearTheCardsOwnColours() {
    // The two states a healthy run passes through, each matching the CARD that says the same
    // thing: a traversing card pulses `running` blue, a settled one wears the `done` green
    // checkmark. The badges used to say orange and blue for those two, which left the same
    // fact wearing different colours a few points apart on screen.
    #expect(SZRunBadge.running().colour == SZAgentGraphStyle.running)
    #expect(SZRunBadge.style(for: .ended).colour == SZAgentGraphStyle.done)
    #expect(SZRunBadge.running().colour != SZRunBadge.style(for: .ended).colour)
    // Green means an ending that worked, so no other ending may borrow it.
    #expect(SZRunBadge.style(for: .failed(reason: "the turn threw")).colour != SZAgentGraphStyle.done)
    #expect(SZRunBadge.style(for: .cancelled).colour != SZAgentGraphStyle.done)
}

@Test func anEndingOffAnUnhandledErrorPortIsNotDrawnAsSuccess() {
    // The engine seals THIS `.ended`: nothing threw, the traversal simply had nowhere to go from
    // an error port. The canvas already drew that capsule orange while the row called the same run
    // a clean exit — a split the rename made loud, since the row now says "complete" in green.
    // One table classifies it now, so both surfaces say the same word in the same colour.
    #expect(SZRunBadge.style(for: .ended, endedOn: "error").label == "failed")
    #expect(SZRunBadge.style(for: .ended, endedOn: "error").colour == SZAgentGraphStyle.failed)
    #expect(SZRunBadge.style(for: .ended, endedOn: "error: no camera").label == "failed")
    // Only a CLEAN ending is reclassified: every other conclusion is its own verdict, whatever
    // port the last node happened to answer.
    #expect(SZRunBadge.style(for: .declined(reason: "x"), endedOn: "error").colour == SZEdgeStyle.intentViolet)
    #expect(SZRunBadge.style(for: .cancelled, endedOn: "error").label == "stopped")
    // And an ordinary ending is untouched, with or without a port to read.
    #expect(SZRunBadge.style(for: .ended, endedOn: "ok").label == "complete")
    #expect(SZRunBadge.style(for: .ended, endedOn: nil).colour == SZAgentGraphStyle.done)
}

@Test func aRecordsBadgeReadsItsOwnLastOutcome() {
    // The record carries what the conclusion drops, so the badge takes the RUN where one exists.
    var record = SZAgentGraphRun(id: UUID(), agent: "director",
                                 startedAt: Date(timeIntervalSinceReferenceDate: 100))
    record.note(.init(ordinal: 1, node: "send", phase: .done, outcome: "error"),
                at: Date(timeIntervalSinceReferenceDate: 101))
    record.seal(conclusion: .ended)
    #expect(SZRunBadge.forRun(record).label == "failed")
    #expect(SZRunBadge.forRun(record).colour == SZAgentGraphStyle.failed)
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
