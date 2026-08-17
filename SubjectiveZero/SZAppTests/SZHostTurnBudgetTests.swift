// SPDX-License-Identifier: AGPL-3.0-only
// Every agent turn — implement, node chat/edit, Director run — runs on ONE budget pair, and a
// turn that runs out of it says so in one shared sentence. Pins the accessor the request
// builders read (default + env override) and the timeout sentence's "after Nm/Ns" rendering.
import Foundation
import Testing
import SZAI
@testable import SubjectiveZero

struct SZHostTurnBudgetTests {

    @Test func theSharedBudgetIsTheCodingBudgetAndHonorsTheEnvOverride() {
        unsetenv("SZ_AGENT_TIMEOUT"); unsetenv("SZ_AGENT_INACTIVITY_TIMEOUT")
        #expect(SZAgentTurnBudgets.codingTimeout == 900)
        #expect(SZAgentTurnBudgets.codingInactivityTimeout == 120)

        setenv("SZ_AGENT_TIMEOUT", "30", 1)
        setenv("SZ_AGENT_INACTIVITY_TIMEOUT", "7", 1)
        defer { unsetenv("SZ_AGENT_TIMEOUT"); unsetenv("SZ_AGENT_INACTIVITY_TIMEOUT") }
        #expect(SZAgentTurnBudgets.codingTimeout == 30)
        #expect(SZAgentTurnBudgets.codingInactivityTimeout == 7)
    }

    @Test func theTimeoutSentenceRendersMinutesOrSeconds() {
        #expect(SZHost.timeoutDetail(budget: 900).contains("timed out after 15m without finishing"))
        #expect(SZHost.timeoutDetail(budget: 45).contains("timed out after 45s without finishing"))
        #expect(SZHost.timeoutDetail(budget: nil).hasPrefix("the agent timed out without finishing"))
    }
}
