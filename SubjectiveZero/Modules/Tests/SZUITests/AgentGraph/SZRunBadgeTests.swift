// SPDX-License-Identifier: AGPL-3.0-only
// The ending vocabulary the RUNS list and the canvas terminal share: one word per
// conclusion class, and — the thing this pins — a run the app closed on says so instead of
// borrowing the user's "stopped".
import Foundation
import Testing
import SZCore
@testable import SZUI

@Test func everyConclusionGetsItsOwnWord() {
    #expect(SZRunBadge.style(for: .ended).label == "end")
    #expect(SZRunBadge.style(for: .failed(reason: "the turn threw")).label == "failed")
    #expect(SZRunBadge.style(for: .defect(detail: "unknown node")).label == "failed")
    #expect(SZRunBadge.style(for: .cancelled).label == "stopped")
    #expect(SZRunBadge.style(for: .declined(reason: "no camera")).label == "declined")
    // A record with no conclusion cannot come out of the host's seal; drawn, not blank.
    #expect(SZRunBadge.style(for: nil).label == "end")
}

@Test func anInterruptedRunReadsApartFromAUserStop() {
    #expect(SZRunBadge.style(for: .interrupted).label == "interrupted")
    #expect(SZRunBadge.style(for: .interrupted).label != SZRunBadge.style(for: .cancelled).label)
    // Neither a failure nor a verdict: the neutral capsule, like a Stop and a refusal.
    #expect(SZRunBadge.style(for: .interrupted).colour == SZAgentGraphStyle.neutral)
}

@Test func theRestorePolicysRecordCarriesTheInterruptedCapsule() {
    // End to end through the model: a record found live on disk seals interrupted, and the
    // panel draws that word.
    var record = SZAgentGraphRun(id: UUID(), agent: "director",
                                 startedAt: Date(timeIntervalSinceReferenceDate: 100))
    record.note(.init(ordinal: 1, node: "send", phase: .running),
                at: Date(timeIntervalSinceReferenceDate: 101))
    record.sealInterrupted()
    #expect(SZRunBadge.style(for: record.conclusion).label == "interrupted")
}
