// SPDX-License-Identifier: AGPL-3.0-only
// What a finished build says in the transcript. The host used to bookend every run with
// "Run started…" and "Run complete — N nodes implemented." — the first restating the run strip
// that was already on screen, the second restating the Director's own summary directly above it,
// both wearing the Director's violet as if the host were the agent. What survives is one receipt,
// and these pin its words and its badge.
import Foundation
import Testing
@testable import SZCore

@Suite("A build's receipt says what it did")
struct SZChatReceiptTests {

    // MARK: A run that reached its own end

    /// THE fix for the screenshot that started this: three concurrent one-node builds used to
    /// finish as "Run complete — 1 node implemented." three times, because the sentence rendered a
    /// COUNT and never the work. Naming the node is what tells three receipts apart.
    @Test func oneNodeIsNamed() {
        let receipt = SZChatReceipt.forEnding(implemented: 1, failed: 0, work: "Warm Orange")
        #expect(receipt.label == "built Warm Orange")
        #expect(receipt.conclusion == .ended)
        #expect(receipt.detail == nil)   // a run that worked owes no explanation
    }

    /// Several nodes have no one name to carry, so the count is the honest label.
    @Test func severalNodesFallBackToACount() {
        #expect(SZChatReceipt.forEnding(implemented: 3, failed: 0, work: nil).label == "built 3 nodes")
    }

    /// A one-node run whose node was merged away mid-run has no title to offer. The singular still
    /// has to read correctly — "built 1 nodes" is the classic version of this bug.
    @Test func aSingleNodeWithNoTitleStaysSingular() {
        #expect(SZChatReceipt.forEnding(implemented: 1, failed: 0, work: nil).label == "built 1 node")
        #expect(SZChatReceipt.forEnding(implemented: 1, failed: 0, work: "").label == "built 1 node")
    }

    /// Finding nothing to do is a real outcome, not an empty one — and it is what the Director
    /// itself often reports in its own words just above.
    @Test func abuildThatFoundNothingSaysSo() {
        let receipt = SZChatReceipt.forEnding(implemented: 0, failed: 0, work: nil)
        #expect(receipt.label == "nothing needed building")
        #expect(receipt.conclusion == .ended)
    }

    /// An ask that could not reach the node it was about is not an ask that found nothing to do.
    /// "nothing needed building" is a claim about the world; this is a claim about the ask.
    @Test func aBuildThatHandedItsAskOnSaysWhichNodeHasIt() {
        let receipt = SZChatReceipt.forEnding(implemented: 0, failed: 0, work: nil,
                                              busy: ["Pixel Morph"])
        #expect(receipt.label == "waiting on Pixel Morph")
        #expect(receipt.conclusion == .declined(reason: receipt.detail ?? ""))
        #expect(receipt.detail?.contains("sent to it") == true)
    }

    /// Part of the work landed and part went on: the receipt owes both halves, and a run that
    /// built something reached its ending. Declined is for the one that built nothing at all.
    @Test func aBuildThatLandedSomeWorkNamesTheBusyRemainder() {
        let receipt = SZChatReceipt.forEnding(implemented: 2, failed: 0, work: nil,
                                              busy: ["Pixel Morph"])
        #expect(receipt.label == "built 2 nodes, waiting on Pixel Morph")
        #expect(receipt.conclusion == .ended)
        #expect(receipt.detail?.contains("Pixel Morph") == true)
    }

    /// Past one node no single name is true, so it counts — the rule the built labels already use.
    @Test func severalBusyNodesFallBackToACount() {
        let receipt = SZChatReceipt.forEnding(implemented: 0, failed: 0, work: nil,
                                              busy: ["Pixel Morph", "Blur"])
        #expect(receipt.label == "waiting on 2 nodes")
    }

    /// A node that FAILED needs the user; an ask that is waiting acts on its own. The one that
    /// needs a person wins the badge.
    @Test func aShortfallOutranksABusyNode() {
        let receipt = SZChatReceipt.forEnding(implemented: 0, failed: 1, work: "Blur",
                                              busy: ["Pixel Morph"])
        #expect(receipt.conclusion == .failed(reason: "1 unfinished"))
    }

    /// The receipt reports on the WORK, not on the graph walk: a traversal can end perfectly well
    /// having left a node unimplemented, and that is a shortfall the badge must show.
    @Test func aShortfallIsBadgedFailedEvenThoughTheTraversalEnded() {
        let receipt = SZChatReceipt.forEnding(implemented: 2, failed: 1, work: "Warm Orange")
        #expect(receipt.label == "built 2 of 3")
        #expect(receipt.conclusion == .failed(reason: "1 unfinished"))
    }

    // MARK: A run someone stopped

    /// A Stop is nobody's failure, so it keeps the neutral badge whatever it left behind. What
    /// changes is whether there is a shortfall worth naming.
    @Test func aStopNamesWhatItLeftUnfinished() {
        let receipt = SZChatReceipt.forStop(implemented: 1, unfinished: 2, work: nil)
        #expect(receipt.label == "2 nodes unfinished")
        #expect(receipt.conclusion == .cancelled)
    }

    @Test func aStopWithNothingLeftReportsWhatItBuilt() {
        let receipt = SZChatReceipt.forStop(implemented: 1, unfinished: 0, work: "Deep Blue")
        #expect(receipt.label == "built Deep Blue")
        #expect(receipt.conclusion == .cancelled)   // still a stop: that is how the run ended
    }

    @Test func aStopSingularizesItsShortfall() {
        #expect(SZChatReceipt.forStop(implemented: 0, unfinished: 1, work: nil).label
                == "1 node unfinished")
    }

    // MARK: A run that threw

    /// The reason rides ON the receipt rather than in a second line, because nothing else in the
    /// transcript will say it: a dead CLI or a spent budget is the run's own news, not a node's.
    /// And a one-node failure is NAMED — a dead CLI takes down whichever builds were in flight, so
    /// three of them all reading "built 0 of 1" under the same reason would be exactly the
    /// indistinguishability this change exists to remove.
    @Test func aFailureCarriesItsReasonAndNamesASingleNode() {
        let receipt = SZChatReceipt.forFailure(implemented: 0, unfinished: 1, work: "Warm Orange",
                                               reason: "the provider died")
        #expect(receipt.label == "Warm Orange unfinished")
        #expect(receipt.conclusion == .failed(reason: "the provider died"))
        #expect(receipt.detail == "the provider died")
    }

    /// Several nodes have no one name that would be true, so the count carries it.
    @Test func aMultiNodeFailureCounts() {
        #expect(SZChatReceipt.forFailure(implemented: 1, unfinished: 2, work: nil,
                                         reason: "budget spent").label == "built 1 of 3")
    }

    /// The same naming rule on the settle path's shortfall branch.
    @Test func aSingleUnfinishedNodeIsNamedOnTheSettlePathToo() {
        #expect(SZChatReceipt.forEnding(implemented: 0, failed: 1, work: "Deep Blue").label
                == "Deep Blue unfinished")
    }
}

/// The decode hazard that made `SZChatReceipt`'s Codable hand-written. `conclusion` is an enum with
/// associated values: on synthesized Codable an unrecognized case THROWS rather than decoding to
/// nil, and `decodeIfPresent` does not absorb it. One throw unwinds the whole `messages` array →
/// `SZChatTranscriptIO.load`'s `try?` → the scope loads with no history → the next flush writes
/// that emptiness back. A conversation would be lost to something as ordinary as adding a case to
/// `SZTraversalEnding` and reopening the project under an older build.
@Suite("A receipt degrades; the message survives")
struct SZChatReceiptToleranceTests {

    private func decode(_ json: String) throws -> SZChatMessage {
        try JSONDecoder().decode(SZChatMessage.self, from: Data(json.utf8))
    }

    /// THE case. An ending this build has never heard of must not cost the reader their transcript.
    @Test func anUnknownConclusionFallsBackInsteadOfThrowing() throws {
        let m = try decode(#"""
        {"role":"assistant","text":"built Warm Orange",
         "receipt":{"label":"built Warm Orange","conclusion":{"vaporized":{"how":"badly"}}}}
        """#)
        #expect(m.text == "built Warm Orange")          // the durable fact is intact
        #expect(m.receipt?.label == "built Warm Orange")
        #expect(m.receipt?.conclusion == .ended)        // the ending degraded, nothing else
    }

    @Test func aReceiptMissingItsLabelStillDecodes() throws {
        let m = try decode(#"{"role":"assistant","text":"x","receipt":{"conclusion":{"ended":{}}}}"#)
        #expect(m.receipt?.label == "")
    }

    /// A whole receipt of the wrong SHAPE degrades to no receipt — the message still loads.
    @Test func aMalformedReceiptDoesNotTakeTheMessageWithIt() throws {
        let m = try decode(#"{"role":"assistant","text":"built it","receipt":"not an object"}"#)
        #expect(m.text == "built it")
        #expect(m.receipt == nil)
    }

    /// Round trip, so the tolerant decoder is still a faithful one on well-formed input.
    @Test func aFailureRoundTripsWithItsReasonAndDetail() throws {
        let original = SZChatMessage(role: .assistant, text: "built 0 of 1", duration: 12,
                                     receipt: .forFailure(implemented: 0, unfinished: 1,
                                                          work: "Warm Orange",
                                                          reason: "the provider died"))
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(SZChatMessage.self, from: data)
        #expect(back.receipt == original.receipt)
        #expect(back.receipt?.conclusion == .failed(reason: "the provider died"))
    }
}
