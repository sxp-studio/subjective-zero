// SPDX-License-Identifier: AGPL-3.0-only
// The adapter's payload split: a compiled step's success payload arrives as either the bare
// outcome string (unchanged forever) or the additive `{"effects", "outcome"}` envelope —
// this is the ONE place the wire convention becomes an SZStepReport, so its edges get pinned
// here: envelope keys are both required, and JSON-looking outcomes that aren't the envelope
// stay bare.
import Foundation
import Testing
import SZAI
@testable import SubjectiveZero

@MainActor
struct SZHostStepReportTests {

    @Test func aBareOutcomeRidesThroughUntouched() {
        let report = SZHostStepRunning.report(payload: "yes")
        #expect(report.outcome == "yes")
        #expect(report.effects.isEmpty)
    }

    @Test func theEffectEnvelopeSplitsIntoOutcomeAndEffects() {
        let report = SZHostStepRunning.report(
            payload: #"{"effects":["requestBuild"],"outcome":"build"}"#)
        #expect(report.outcome == "build")
        #expect(report.effects == ["requestBuild"])
    }

    @Test func jsonThatIsNotTheEnvelopeStaysABareOutcome() {
        // Both keys are required — a JSON-shaped payload missing either is NOT the
        // envelope, and the honest reading is "this string is the outcome".
        for payload in [#"{"outcome":"build"}"#, #"{"effects":["x"]}"#, #"{"kind":"build"}"#] {
            let report = SZHostStepRunning.report(payload: payload)
            #expect(report.outcome == payload)
            #expect(report.effects.isEmpty)
        }
    }
}
