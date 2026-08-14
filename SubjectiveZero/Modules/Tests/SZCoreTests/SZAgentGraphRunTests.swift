// SPDX-License-Identifier: AGPL-3.0-only
// The run record's rules, host-free: list ordering (live first, the build leads), the caps
// that never evict a live record, the sealed-record guard, the stamp-preserving merge, the
// idempotent seal, and the one sanctioned post-seal write (the dispatch-tally amend).
import Foundation
import Testing
@testable import SZCore

private func run(_ started: TimeInterval, live: Bool = false,
                 kind: SZMessageKind = .build, thread: UUID? = nil) -> SZAgentGraphRun {
    SZAgentGraphRun(id: UUID(), agent: "director", graphName: "build", kind: kind,
                    thread: thread,
                    startedAt: Date(timeIntervalSinceReferenceDate: started),
                    endedAt: live ? nil : Date(timeIntervalSinceReferenceDate: started + 10))
}

private func entry(_ ordinal: Int, node: String = "step",
                   phase: SZAgentGraphRun.Entry.Phase = .running,
                   outcome: String? = nil,
                   tally: SZAgentGraphRun.Tally? = nil) -> SZAgentGraphRun.Entry {
    SZAgentGraphRun.Entry(ordinal: ordinal, node: node, phase: phase, outcome: outcome,
                          tally: tally)
}

// MARK: - Ordering and the caps

@Test func orderedPutsLiveFirstThenNewest() {
    let live = run(50, live: true)
    let old = run(10)
    let new = run(90)
    let ordered = SZAgentGraphRun.ordered([old, new, live])
    #expect(ordered.map(\.id) == [live.id, new.id, old.id])
}

@Test func orderedLeadsWithTheLiveBuildNotTheLiveItem() {
    // An item traversal started while the build runs must not take the head — the head is
    // what the panel follows, and the build is the thread's spine.
    let build = run(10, live: true)
    let item = run(90, live: true, kind: .item)
    #expect(SZAgentGraphRun.ordered([item, build]).map(\.id) == [build.id, item.id])
    // Among ENDED records the kind means nothing — newest still wins.
    let older = run(10), newerItem = run(90, kind: .item)
    #expect(SZAgentGraphRun.ordered([older, newerItem]).map(\.id) == [newerItem.id, older.id])
}

@Test func capEvictsTheOldestEndedFirst() {
    let runs = SZAgentGraphRun.ordered([run(30), run(10), run(20)])
    let capped = SZAgentGraphRun.capped(runs, builds: 2)
    #expect(capped.map(\.startedAt.timeIntervalSinceReferenceDate) == [30, 20])
}

@Test func capPicksItsVictimByClockNotByPosition() {
    // Handed an UNORDERED list, the cap must still drop the oldest record rather than
    // whatever sits last.
    let capped = SZAgentGraphRun.capped([run(10), run(30), run(20)], builds: 2)
    #expect(Set(capped.map(\.startedAt.timeIntervalSinceReferenceDate)) == [30, 20])
}

@Test func capNeverEvictsALiveRecord() {
    // Every slot over the limit is live → nothing may be evicted, even over-cap.
    let lives = SZAgentGraphRun.ordered([run(1, live: true), run(2, live: true), run(3, live: true)])
    #expect(SZAgentGraphRun.capped(lives, builds: 2).count == 3)
    // Mixed: the ended record goes, the lives stay.
    let mixed = SZAgentGraphRun.ordered([run(1, live: true), run(2), run(3, live: true)])
    let capped = SZAgentGraphRun.capped(mixed, builds: 2)
    #expect(capped.count == 2)
    #expect(capped.allSatisfy { $0.isLive })
}

@Test func eachBudgetIsCappedOnItsOwn() {
    // The whole point: item traversals outnumber builds many to one, and a burst of them
    // must not evict a single recorded build.
    let items = (1...40).map { run(Double($0), kind: .item) }
    let builds = (1...3).map { run(Double(100 + $0)) }
    let capped = SZAgentGraphRun.capped(SZAgentGraphRun.ordered(items + builds),
                                        builds: 20, others: 30)
    #expect(capped.filter { $0.kind == .item }.count == 30)
    #expect(capped.filter { $0.kind == .build }.count == 3)
    // And the items that went are the oldest ones.
    #expect(capped.filter { $0.kind == .item }
        .allSatisfy { $0.startedAt.timeIntervalSinceReferenceDate > 10 })
}

// MARK: - note: merge + stamps

@Test func noteStampsStartOnFirstSightAndEndOnSettle() {
    var record = run(0, live: true)
    let t0 = Date(timeIntervalSinceReferenceDate: 100)
    let t1 = Date(timeIntervalSinceReferenceDate: 112)
    record.note(entry(1, phase: .running), at: t0)
    #expect(record.trace[0].startedAt == t0)
    #expect(record.trace[0].endedAt == nil)
    record.note(entry(1, phase: .done, outcome: "yes"), at: t1)
    #expect(record.trace.count == 1)                 // replaced by (ordinal, node), not appended
    #expect(record.trace[0].startedAt == t0)         // first-seen keeps its start
    #expect(record.trace[0].endedAt == t1)
    #expect(record.trace[0].outcome == "yes")
    #expect(record.trace[0].duration == 12)
}

@Test func noteReEmitNeverRestamps() {
    var record = run(0, live: true)
    let t0 = Date(timeIntervalSinceReferenceDate: 100)
    let t1 = Date(timeIntervalSinceReferenceDate: 110)
    record.note(entry(1, phase: .running), at: t0)
    record.note(entry(1, phase: .done), at: t1)
    record.note(entry(1, phase: .done), at: Date(timeIntervalSinceReferenceDate: 200))
    #expect(record.trace[0].startedAt == t0)
    #expect(record.trace[0].endedAt == t1)
}

@Test func noteAlreadySettledFirstReportStampsBothAtOnce() {
    // An entry reported only once, already settled — both stamps land, duration reads zero.
    var record = run(0, live: true)
    let t = Date(timeIntervalSinceReferenceDate: 100)
    record.note(entry(1, phase: .done), at: t)
    #expect(record.trace[0].startedAt == t)
    #expect(record.trace[0].endedAt == t)
}

@Test func aRevisitIsItsOwnEntryNotAReplace() {
    // Same node, later ordinal — the loop's second pass appends; the trace is the unrolled
    // chain, which is the whole reason it exists.
    var record = run(0, live: true)
    record.note(entry(1, node: "check", phase: .done, outcome: "yes"))
    record.note(entry(3, node: "check", phase: .running))
    #expect(record.trace.count == 2)
    #expect(record.visits(of: "check") == 2)
    #expect(record.visitNumber(of: record.trace[1]) == 2)
}

@Test func sealedRecordDropsLateWrites() {
    var record = run(0, live: true)
    record.note(entry(1, phase: .running))
    record.seal(conclusion: .cancelled)
    record.note(entry(2, phase: .running))
    #expect(record.trace.count == 1)
}

// MARK: - seal

@Test func sealFlipsAStillRunningLastEntryToCancelled() {
    var record = run(0, live: true)
    let t = Date(timeIntervalSinceReferenceDate: 130)
    record.note(entry(1, phase: .done), at: Date(timeIntervalSinceReferenceDate: 100))
    record.note(entry(2, node: "turn", phase: .running), at: Date(timeIntervalSinceReferenceDate: 110))
    record.seal(conclusion: .cancelled, at: t)
    #expect(record.trace[1].phase == .cancelled)
    #expect(record.trace[1].endedAt == t)
    #expect(record.conclusion == .cancelled)
    #expect(record.endedAt == t)
}

@Test func sealIsIdempotentAndConclusionGuarded() {
    var record = run(0, live: true)
    record.note(entry(1, phase: .done))
    // The traversal already concluded; a later (eager-cancel) seal keeps the real ending.
    record.conclusion = .ended
    let t = Date(timeIntervalSinceReferenceDate: 100)
    record.seal(conclusion: .cancelled, at: t)
    #expect(record.conclusion == .ended)
    #expect(record.endedAt == t)
    // Sealed → a second seal changes nothing.
    record.seal(conclusion: .failed(reason: "late"), at: Date())
    #expect(record.endedAt == t)
    #expect(record.conclusion == .ended)
}

// MARK: - The tally on the visit

@Test func aDispatchVisitsTallyRidesItsEntryAndSurvivesReEmits() {
    // The dispatch waits inside the traversal now, so the tally lands BEFORE the seal —
    // per visit, through the ordinary note flow. A re-emit without a tally (a phase
    // change racing a progress note) never erases the count a progress note wrote.
    var record = run(0, live: true)
    record.note(entry(1, node: "dispatch", phase: .running,
                      tally: .init(settled: 1, total: 4, failed: 0)))
    record.note(entry(1, node: "dispatch", phase: .running))
    #expect(record.trace[0].tally == SZAgentGraphRun.Tally(settled: 1, total: 4, failed: 0))
    record.note(entry(1, node: "dispatch", phase: .done, outcome: "settled",
                      tally: .init(settled: 4, total: 4, failed: 1)))
    #expect(record.trace[0].tally == SZAgentGraphRun.Tally(settled: 4, total: 4, failed: 1))
    record.seal(conclusion: .ended, at: Date(timeIntervalSinceReferenceDate: 100))
    // Sealed means SEALED — there is no post-seal write left in the model.
    record.note(entry(1, node: "dispatch", phase: .done, outcome: "settled",
                      tally: .init(settled: 4, total: 4, failed: 2)))
    #expect(record.trace[0].tally?.failed == 1)
}

// MARK: - The ending mapping (SZTraversalEnding → the archive's own vocabulary)

@Test func conclusionMapsEveryEndingClassPreserving() {
    #expect(SZAgentGraphRun.Conclusion(.ended) == .ended)
    #expect(SZAgentGraphRun.Conclusion(.failed(reason: "r")) == .failed(reason: "r"))
    #expect(SZAgentGraphRun.Conclusion(.cancelled) == .cancelled)
    #expect(SZAgentGraphRun.Conclusion(.declined(reason: "why")) == .declined(reason: "why"))
    #expect(SZAgentGraphRun.Conclusion(.defect(detail: "d")) == .defect(detail: "d"))
}

// MARK: - Entry wire tolerance for the stamps

@Test func entryWithoutOptionalsEncodesWithoutTheirKeys() throws {
    // An absent value must not be encoded — no key that says nothing.
    let data = try JSONEncoder().encode(entry(1, phase: .done))
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("startedAt"))
    #expect(!text.contains("endedAt"))
    #expect(!text.contains("outcome"))
    #expect(!text.contains("detail"))
}

@Test func entryStampsRoundTrip() throws {
    var stamped = entry(1, phase: .done, outcome: "ok")
    stamped.startedAt = Date(timeIntervalSinceReferenceDate: 100)
    stamped.endedAt = Date(timeIntervalSinceReferenceDate: 112)
    let decoded = try JSONDecoder().decode(SZAgentGraphRun.Entry.self,
                                           from: JSONEncoder().encode(stamped))
    #expect(decoded.startedAt == stamped.startedAt)
    #expect(decoded.endedAt == stamped.endedAt)
    #expect(decoded.duration == 12)
}
