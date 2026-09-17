// SPDX-License-Identifier: AGPL-3.0-only
// The ending vocabulary the RUNS list and the canvas terminal share. Two things it pins: which
// endings collapse into one word (stopped and interrupted are the same class — unfinished, nothing
// broken — and cannot co-occur), and which one must NOT (a refusal is a decision, not an accident,
// so it leaves the neutral capsule the other two share).
import Foundation
import SwiftUI
import Testing
import SZCore
@testable import SZUI

// Named reads: Swift 6.4 cannot type-check `label(.x) == "…"` inside #expect
// in reasonable time, and a plain String or Color comparison it can.
private func label(_ conclusion: SZAgentGraphRun.Conclusion?, endedOn: String? = nil) -> String {
    label(conclusion, endedOn: endedOn)
}
private func colour(_ conclusion: SZAgentGraphRun.Conclusion?, endedOn: String? = nil) -> Color {
    colour(conclusion, endedOn: endedOn)
}

@Test func everyConclusionClassGetsItsOwnWord() {
    #expect(label(.ended) == "complete")
    #expect(label(.failed(reason: "the turn threw")) == "failed")
    #expect(label(.defect(detail: "unknown node")) == "failed")
    #expect(label(.cancelled) == "stopped")
    #expect(label(.declined(reason: "no camera")) == "declined")
    // A record with no conclusion cannot come out of the host's seal; drawn, not blank.
    #expect(label(nil) == "complete")
}

@Test func inFlightIsSpokenInTheSameTenseAsTheEndings() {
    // "live" was a broadcast word among build words; every other badge is a plain outcome.
    #expect(SZRunBadge.running().label == "running")
    #expect(!label(.ended).contains("live"))
}

@Test func stillGoingAndFinishedWearTheCardsOwnColours() {
    // The two states a healthy run passes through, each matching the CARD that says the same
    // thing: a traversing card pulses `running` blue, a settled one wears the `done` green
    // checkmark. The badges used to say orange and blue for those two, which left the same
    // fact wearing different colours a few points apart on screen.
    #expect(SZRunBadge.running().colour == SZAgentGraphStyle.running)
    #expect(colour(.ended) == SZAgentGraphStyle.done)
    #expect(SZRunBadge.running().colour != colour(.ended))
    // Green means an ending that worked, so no other ending may borrow it.
    #expect(colour(.failed(reason: "the turn threw")) != SZAgentGraphStyle.done)
    #expect(colour(.cancelled) != SZAgentGraphStyle.done)
}

@Test func anEndingOffAnUnhandledErrorPortIsNotDrawnAsSuccess() {
    // The engine seals THIS `.ended`: nothing threw, the traversal simply had nowhere to go from
    // an error port. The canvas already drew that capsule orange while the row called the same run
    // a clean exit — a split the rename made loud, since the row now says "complete" in green.
    // One table classifies it now, so both surfaces say the same word in the same colour.
    #expect(label(.ended, endedOn: "error") == "failed")
    #expect(colour(.ended, endedOn: "error") == SZAgentGraphStyle.failed)
    #expect(label(.ended, endedOn: "error: no camera") == "failed")
    // Only a CLEAN ending is reclassified: every other conclusion is its own verdict, whatever
    // port the last node happened to answer.
    #expect(colour(.declined(reason: "x"), endedOn: "error") == SZEdgeStyle.intentViolet)
    #expect(label(.cancelled, endedOn: "error") == "stopped")
    // And an ordinary ending is untouched, with or without a port to read.
    #expect(label(.ended, endedOn: "ok") == "complete")
    #expect(colour(.ended, endedOn: nil) == SZAgentGraphStyle.done)
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
    #expect(label(.interrupted) == "stopped")
    #expect(label(.interrupted) == label(.cancelled))
    #expect(colour(.interrupted) == SZAgentGraphStyle.neutral)
}

@Test func aRefusalIsNotDrawnLikeAnAccident() {
    // `declined` used to wear the same grey as "the app crashed under this". It is a DECISION —
    // the agents' own violet, the colour a step's ruling wears on the canvas.
    #expect(colour(.declined(reason: "no camera")) == SZEdgeStyle.intentViolet)
    #expect(colour(.declined(reason: "x")) != colour(.cancelled))
    // And still not a failure, which is the distinction the whole vocabulary exists to keep.
    #expect(colour(.declined(reason: "x")) != SZAgentGraphStyle.failed)
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
    #expect(label(record.conclusion) == "stopped")
    #expect(record.trace.contains { $0.detail == SZAgentGraphRun.interruptedDetail })
}
