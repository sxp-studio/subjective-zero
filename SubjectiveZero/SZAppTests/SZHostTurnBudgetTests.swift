// SPDX-License-Identifier: AGPL-3.0-only
// Every agent turn — implement, node chat/edit, Director run — runs on ONE budget pair, and a
// turn that runs out of it says so in one shared sentence. Pins the accessor the request builders
// read (default + env override) and both timeout sentences (wall clock vs silence).
// `.serialized`: the env-override case mutates the process environment, which every other test in
// the run would otherwise see.
import Foundation
import Testing
import SZAI
@testable import SubjectiveZero

@Suite(.serialized)
struct SZHostTurnBudgetTests {

    @Test func theSharedBudgetIsTheCodingBudgetAndHonorsTheEnvOverride() {
        unsetenv("SZ_AGENT_TIMEOUT"); unsetenv("SZ_AGENT_INACTIVITY_TIMEOUT")
        defer { unsetenv("SZ_AGENT_TIMEOUT"); unsetenv("SZ_AGENT_INACTIVITY_TIMEOUT") }
        #expect(SZAgentTurnBudgets.codingTimeout == 900)
        #expect(SZAgentTurnBudgets.codingInactivityTimeout == 120)

        setenv("SZ_AGENT_TIMEOUT", "30", 1)
        setenv("SZ_AGENT_INACTIVITY_TIMEOUT", "7", 1)
        #expect(SZAgentTurnBudgets.codingTimeout == 30)
        #expect(SZAgentTurnBudgets.codingInactivityTimeout == 7)
    }

    @Test func theTimeoutSentenceSaysWhichDeadlineFired() {
        let request = Self.request(timeout: 900, inactivityTimeout: 120)
        #expect(SZHost.timeoutDetail(.wallClock, request: request)
            .contains("timed out after 15m without finishing"))
        #expect(SZHost.timeoutDetail(.silence, request: request)
            .contains("went silent for 2m"))
        // A silence kill must never be reported as the wall clock's story.
        #expect(!SZHost.timeoutDetail(.silence, request: request).contains("15m"))
    }

    @Test func theTimeoutSentenceRendersMinutesOrSecondsAndSurvivesAMissingBudget() {
        #expect(SZHost.timeoutDetail(.wallClock, request: Self.request(timeout: 45))
            .contains("timed out after 45s without finishing"))
        #expect(SZHost.timeoutDetail(.silence, request: Self.request(inactivityTimeout: 30))
            .contains("went silent for 30s"))
        #expect(SZHost.timeoutDetail(.wallClock, request: Self.request())
            .hasPrefix("the agent timed out without finishing"))
        #expect(SZHost.timeoutDetail(.silence, request: Self.request())
            .hasPrefix("the agent went silent and was stopped"))
    }

    /// A timed-out turn's reason is the timeout sentence — what the RUNS record, the node pill and
    /// the run narration all read (`deliver` stamps it onto the outcome).
    @Test func aTimedOutTurnReportsItsSentenceAsTheFailureReason() {
        let detail = SZHost.timeoutDetail(.wallClock, request: Self.request(timeout: 900))
        let result = SZAgentRunResult(
            process: SZProcessResult(exitCode: 124, output: "", timeout: .wallClock),
            outcome: SZAgentOutcome(sessionID: nil, failed: true, message: detail))
        #expect(SZHost.turnFailureDetail(result) == detail)
        // A failure with no message at all still reads as something, never an empty reason.
        let mute = SZAgentRunResult(process: SZProcessResult(exitCode: 1, output: ""),
                                    outcome: SZAgentOutcome(sessionID: nil, failed: true))
        #expect(!SZHost.turnFailureDetail(mute).isEmpty)
    }

    private static func request(timeout: TimeInterval? = nil,
                                inactivityTimeout: TimeInterval? = nil) -> SZAgentRunRequest {
        SZAgentRunRequest(prompt: "", workingDirectory: URL(fileURLWithPath: "/tmp"),
                          cacheDirectory: URL(fileURLWithPath: "/tmp"),
                          timeout: timeout, inactivityTimeout: inactivityTimeout)
    }
}
