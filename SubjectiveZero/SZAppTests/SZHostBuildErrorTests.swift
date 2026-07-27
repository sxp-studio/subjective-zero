// SPDX-License-Identifier: AGPL-3.0-only
// `SZHost.firstErrorLine(in:)` — the one line of a node build log that reaches the card's error pill.
// The full log stays copyable in the popover, so this only has to pick the line a user can act on.
import Testing
@testable import SubjectiveZero

@Test @MainActor func picksTheFirstSwiftcErrorLine() {
    let log = """
    warning: 'foo' is deprecated
    /tmp/Node.swift:12:9: error: cannot find 'bar' in scope
    /tmp/Node.swift:20:1: error: expected '}'
    """
    #expect(SZHost.firstErrorLine(in: log) == "/tmp/Node.swift:12:9: error: cannot find 'bar' in scope")
}

@Test @MainActor func trimsSurroundingWhitespace() {
    #expect(SZHost.firstErrorLine(in: "   Node.swift:1:1: error: boom   ") == "Node.swift:1:1: error: boom")
}

@Test @MainActor func ignoresLinesWhoseErrorIsNotSwiftcDiagnostic() {
    // The match is on " error:" — a leading-word "error:" or a bare mention is not a diagnostic line.
    let log = """
    error: this is not a compiler diagnostic
    note: errors happen
    Node.swift:3:5: error: real one
    """
    #expect(SZHost.firstErrorLine(in: log) == "Node.swift:3:5: error: real one")
}

@Test @MainActor func fallsBackToABoundedPrefixWhenNothingMatches() {
    let log = String(repeating: "x", count: 400)
    let line = SZHost.firstErrorLine(in: log)
    #expect(line.count == 160)
    #expect(line.allSatisfy { $0 == "x" })
}

@Test @MainActor func fallsBackToTheWholeLogWhenItIsShortAndErrorless() {
    #expect(SZHost.firstErrorLine(in: "linker command failed") == "linker command failed")
}

@Test @MainActor func handlesAnEmptyLog() {
    #expect(SZHost.firstErrorLine(in: "") == "")
}
