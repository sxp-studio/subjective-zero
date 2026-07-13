// SPDX-License-Identifier: AGPL-3.0-only
// The chat caption's compact token formatter — the k→M boundary sits below 1,000,000 so `%.1f`
// rounding can never print "1000.0k".
import Testing
@testable import SZUI

@Test func tokenCompactFormatting() {
    #expect(szFormatTokensCompact(0) == "0")
    #expect(szFormatTokensCompact(999) == "999")
    #expect(szFormatTokensCompact(1000) == "1.0k")
    #expect(szFormatTokensCompact(21507) == "21.5k")
    #expect(szFormatTokensCompact(999_949) == "999.9k")
    #expect(szFormatTokensCompact(999_950) == "1.0M")   // would read "1000.0k" with a 1_000_000 boundary
    #expect(szFormatTokensCompact(1_000_000) == "1.0M")
    #expect(szFormatTokensCompact(1_234_000) == "1.2M")
}
