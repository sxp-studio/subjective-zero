// SPDX-License-Identifier: AGPL-3.0-only
// The learn-gesture election rules (keys are opaque strings; MIDI-shaped here), driven with injected clocks: the control moving at arm time is
// excluded while its gesture continues, a different control wins immediately, and a quiet gap
// releases the excluded control so a deliberate re-twist of the same knob can win.
import Foundation
import Testing
@testable import SZCore

private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

@Test func armTimeControlIsExcludedOnlyWithinTheCap() {
    // cc21 was mid-twist when learn armed (its event IS the arm sample). While its gesture keeps
    // going INSIDE the cap it stays out — but a control still emitting past the cap is the user's
    // deliberate choice (the natural gesture: arm, then twist the knob you last touched — without
    // the cap that read as seconds of dead air, the hardware-checkpoint finding).
    var model = SZBindingLearnModel(armEvent: (seq: 10, key: "ch0/cc21"), at: t0)
    for i in 1...7 {   // 0.1 … 0.7s: sub-quiet steps inside the 0.8s cap
        let changed1 = model.observe(seq: 10 + i, key: "ch0/cc21", value01: 0.5, at: at(0.1 * Double(i)))
        #expect(changed1 == false)
    }
    #expect(model.candidate == nil)
    #expect(model.excluded == "ch0/cc21")
    // 0.85s: past the cap, still twisting — it competes and wins.
    let changed2 = model.observe(seq: 18, key: "ch0/cc21", value01: 0.6, at: at(0.85))
    #expect(changed2)
    #expect(model.candidate == SZBindingLearnModel.Candidate(key: "ch0/cc21", value01: 0.6))
    #expect(model.excluded == nil)
}

@Test func aStaleArmSampleCannotBlockPastTheCap() {
    // The arm sample may be MINUTES old (lastEvent has no timestamp): the user twisted cc21 long
    // ago, arms learn, and twists cc21 again starting inside the quiet window. The chain must not
    // outlive the cap.
    var model = SZBindingLearnModel(armEvent: (seq: 10, key: "ch0/cc21"), at: t0)
    var elected: Date?
    for i in 1...30 {   // continuous 30 Hz-ish twisting from 0.1s on
        let time = 0.1 + 0.05 * Double(i - 1)
        if model.observe(seq: 10 + i, key: "ch0/cc21", value01: 0.5, at: at(time)), elected == nil {
            elected = at(time)
        }
    }
    let waited = elected.map { $0.timeIntervalSince(t0) }
    #expect(waited != nil && waited! <= 0.9)   // recognized within ~the cap, not "a few seconds"
}

@Test func secondControlWinsWhileFirstIsStillMoving() {
    var model = SZBindingLearnModel(armEvent: (seq: 10, key: "ch0/cc21"), at: t0)
    let changed2 = model.observe(seq: 11, key: "ch0/cc21", value01: 0.5, at: at(0.1))
    #expect(changed2 == false)
    // The user twists the knob they actually want.
    let changed3 = model.observe(seq: 12, key: "ch0/cc22", value01: 0.3, at: at(0.2))
    #expect(changed3)
    #expect(model.candidate == SZBindingLearnModel.Candidate(key: "ch0/cc22", value01: 0.3))
    // The settling knob keeps emitting inside its quiet window — it must not steal the election.
    let changed4 = model.observe(seq: 13, key: "ch0/cc21", value01: 0.6, at: at(0.3))
    #expect(changed4 == false)
    #expect(model.candidate?.key == "ch0/cc22")
}

@Test func exclusionLiftsAfterAQuietGap() {
    var model = SZBindingLearnModel(armEvent: (seq: 10, key: "ch0/cc21"), at: t0)
    let changed5 = model.observe(seq: 11, key: "ch0/cc21", value01: 0.5, at: at(0.1))
    #expect(changed5 == false)
    // cc21 goes quiet for 450 ms (> 400 ms default), then is deliberately twisted again.
    let changed6 = model.observe(seq: 12, key: "ch0/cc21", value01: 0.7, at: at(0.55))
    #expect(changed6)
    #expect(model.candidate == SZBindingLearnModel.Candidate(key: "ch0/cc21", value01: 0.7))
    #expect(model.excluded == nil)
}

@Test func noArmEventMeansFirstEventWinsImmediately() {
    var model = SZBindingLearnModel(armEvent: nil, at: t0)
    #expect(model.excluded == nil)
    let changed7 = model.observe(seq: 1, key: "ch2/cc40", value01: 0.9, at: at(0.01))
    #expect(changed7)
    #expect(model.candidate == SZBindingLearnModel.Candidate(key: "ch2/cc40", value01: 0.9))
}

@Test func electionIsLastWinsAndTracksTheCandidatesValue() {
    var model = SZBindingLearnModel(armEvent: nil, at: t0)
    model.observe(seq: 1, key: "ch0/cc30", value01: 0.1, at: at(0.1))
    model.observe(seq: 2, key: "ch0/cc30", value01: 0.4, at: at(0.2))
    #expect(model.candidate == SZBindingLearnModel.Candidate(key: "ch0/cc30", value01: 0.4))
    // A different control moving later takes over — the user corrected their pick.
    model.observe(seq: 3, key: "ch1/cc31", value01: 0.8, at: at(0.3))
    #expect(model.candidate == SZBindingLearnModel.Candidate(key: "ch1/cc31", value01: 0.8))
}

@Test func staleOrRepeatedSeqIsANoOp() {
    var model = SZBindingLearnModel(armEvent: (seq: 10, key: "ch0/cc21"), at: t0)
    // Polls re-reading the arm sample (or older) change nothing — even from another control's id.
    let changed8 = model.observe(seq: 10, key: "ch0/cc22", value01: 0.5, at: at(0.1))
    #expect(changed8 == false)
    let changed9 = model.observe(seq: 9, key: "ch0/cc22", value01: 0.5, at: at(0.2))
    #expect(changed9 == false)
    #expect(model.candidate == nil)
    // The excluded control's quiet chain was NOT refreshed by stale reads: 0.55 is a lift.
    let changed10 = model.observe(seq: 11, key: "ch0/cc21", value01: 0.7, at: at(0.55))
    #expect(changed10)
    #expect(model.candidate?.key == "ch0/cc21")
}
