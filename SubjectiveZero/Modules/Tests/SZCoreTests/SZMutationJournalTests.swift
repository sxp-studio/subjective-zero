// SPDX-License-Identifier: AGPL-3.0-only
// The mutation journal's window + cursor arithmetic: bounded to `capacity`, the running count
// keeps an absolute cursor honest across aged-out entries, and a reset zeroes both.
import Foundation
import Testing
@testable import SZCore

private func entry(_ n: Int) -> SZGraphMutation {
    SZGraphMutation(actor: .user, kind: "connected", subjects: ["e\(n)"])
}

@Test func journalKeepsOnlyTheNewestCapacityEntries() {
    var journal = SZMutationJournal(capacity: 3)
    for n in 0..<5 { journal.append(entry(n)) }
    #expect(journal.entries.map(\.subjects) == [["e2"], ["e3"], ["e4"]])
    #expect(journal.count == 5)
}

@Test func entriesSinceACursorAreOldestFirstAndClampedToTheWindow() {
    var journal = SZMutationJournal(capacity: 3)
    for n in 0..<2 { journal.append(entry(n)) }
    let cursor = journal.count                       // a Director turn starts here
    #expect(journal.entries(since: cursor).isEmpty)
    for n in 2..<4 { journal.append(entry(n)) }
    #expect(journal.entries(since: cursor).map(\.subjects) == [["e2"], ["e3"]])
    // The cursor falls behind the window: the whole window is what remains to report.
    for n in 4..<9 { journal.append(entry(n)) }
    #expect(journal.entries(since: cursor).map(\.subjects) == [["e6"], ["e7"], ["e8"]])
    #expect(journal.entries(since: 0).count == 3)
}

@Test func removeAllResetsTheCursorSpace() {
    var journal = SZMutationJournal(capacity: 3)
    journal.append(entry(0))
    journal.removeAll()
    #expect(journal.entries.isEmpty)
    #expect(journal.count == 0)
    #expect(journal.entries(since: 0).isEmpty)
}
