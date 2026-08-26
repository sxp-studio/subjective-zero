// SPDX-License-Identifier: AGPL-3.0-only
// The run record's rules, host-free: list ordering (live first, the thread's leader
// leads), the caps that never evict a live record, the sealed-record guard, the
// stamp-preserving merge, and the idempotent seal. The record carries no kind: a leader
// is the record whose own id is its thread.
import Foundation
import Testing
@testable import SZCore

/// A record; `leads` makes it a thread leader (thread == its own id), `work` a child.
private func run(_ started: TimeInterval, live: Bool = false,
                 leads: Bool = false, work: String? = nil,
                 thread: UUID? = nil) -> SZAgentGraphRun {
    let id = UUID()
    return SZAgentGraphRun(id: id, agent: "director",
                           thread: leads ? id : thread, work: work,
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

@Test func orderedLeadsWithTheLiveThreadLeaderNotItsChild() {
    // A work child started while the build runs must not take the head — the head is what
    // the panel follows, and the leader is the thread's spine.
    let leader = run(10, live: true, leads: true)
    let child = run(90, live: true, work: "n", thread: leader.id)
    #expect(SZAgentGraphRun.ordered([child, leader]).map(\.id) == [leader.id, child.id])
    // Among ENDED records structure means nothing — newest still wins.
    let older = run(10, leads: true), newerChild = run(90, work: "n")
    #expect(SZAgentGraphRun.ordered([older, newerChild]).map(\.id) == [newerChild.id, older.id])
}

@Test func capEvictsTheOldestEndedFirst() {
    let runs = SZAgentGraphRun.ordered([run(30, leads: true), run(10, leads: true), run(20, leads: true)])
    let capped = SZAgentGraphRun.capped(runs, leaders: 2)
    #expect(capped.map(\.startedAt.timeIntervalSinceReferenceDate) == [30, 20])
}

@Test func capPicksItsVictimByClockNotByPosition() {
    // Handed an UNORDERED list, the cap must still drop the oldest record rather than
    // whatever sits last.
    let capped = SZAgentGraphRun.capped([run(10, leads: true), run(30, leads: true), run(20, leads: true)],
                                        leaders: 2)
    #expect(Set(capped.map(\.startedAt.timeIntervalSinceReferenceDate)) == [30, 20])
}

@Test func capNeverEvictsALiveRecord() {
    // Every slot over the limit is live → nothing may be evicted, even over-cap.
    let lives = SZAgentGraphRun.ordered([run(1, live: true, leads: true),
                                         run(2, live: true, leads: true),
                                         run(3, live: true, leads: true)])
    #expect(SZAgentGraphRun.capped(lives, leaders: 2).count == 3)
    // Mixed: the ended record goes, the lives stay.
    let mixed = SZAgentGraphRun.ordered([run(1, live: true, leads: true),
                                         run(2, leads: true),
                                         run(3, live: true, leads: true)])
    let capped = SZAgentGraphRun.capped(mixed, leaders: 2)
    #expect(capped.count == 2)
    #expect(capped.allSatisfy { $0.isLive })
}

@Test func eachBudgetIsCappedOnItsOwn() {
    // The whole point: thread children outnumber their leaders many to one, and a burst
    // of them must not evict a single recorded thread.
    let children = (1...40).map { run(Double($0), work: "n") }
    let leaders = (1...3).map { run(Double(100 + $0), leads: true) }
    let capped = SZAgentGraphRun.capped(SZAgentGraphRun.ordered(children + leaders),
                                        leaders: 20, others: 30)
    #expect(capped.filter { !$0.leadsThread }.count == 30)
    #expect(capped.filter(\.leadsThread).count == 3)
    // And the children that went are the oldest ones.
    #expect(capped.filter { !$0.leadsThread }
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

@Test func sealFlipsEveryStillRunningEntryToCancelled() {
    // A fan-out leaves SEVERAL visits open at once; a sealed record that kept any of them
    // running would pulse forever in the panel.
    var record = run(0, live: true)
    let t = Date(timeIntervalSinceReferenceDate: 200)
    record.note(entry(1, node: "door", phase: .done), at: Date(timeIntervalSinceReferenceDate: 100))
    record.note(entry(2, node: "send-a", phase: .running), at: Date(timeIntervalSinceReferenceDate: 110))
    record.note(entry(3, node: "send-b", phase: .running), at: Date(timeIntervalSinceReferenceDate: 120))
    record.note(entry(4, node: "send-c", phase: .running), at: Date(timeIntervalSinceReferenceDate: 130))
    record.seal(conclusion: .cancelled, at: t)
    #expect(record.trace.allSatisfy { $0.phase != .running })
    #expect(record.trace.dropFirst().allSatisfy { $0.phase == .cancelled && $0.endedAt == t })
    // The one that had already settled keeps its own stamp.
    #expect(record.trace[0].phase == .done)
    #expect(record.trace[0].endedAt == Date(timeIntervalSinceReferenceDate: 100))
}

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

// MARK: - The restore policy for a record found live on disk

@Test func sealInterruptedStopsAtTheLatestTraceStampWithTheDetailOnTheFlippedEntry() {
    var record = run(0, live: true)
    record.note(entry(1, phase: .done), at: Date(timeIntervalSinceReferenceDate: 100))
    record.note(entry(2, node: "turn", phase: .running), at: Date(timeIntervalSinceReferenceDate: 110))
    record.sealInterrupted()
    // Its OWN conclusion — a truncated run is not the user's Stop.
    #expect(record.conclusion == .interrupted)
    #expect(record.conclusion != .cancelled)
    #expect(record.endedAt == Date(timeIntervalSinceReferenceDate: 110))
    #expect(record.trace[1].phase == .cancelled)
    #expect(record.trace[1].endedAt == Date(timeIntervalSinceReferenceDate: 110))
    #expect(record.trace[1].detail == SZAgentGraphRun.interruptedDetail)
    #expect(record.trace[0].detail == nil)
}

@Test func sealInterruptedMarksEveryEntryThatWasStillRunning() {
    // The Director's fan-out: three concurrent visits, all truncated by the same close.
    var record = run(0, live: true)
    record.note(entry(1, node: "door", phase: .done), at: Date(timeIntervalSinceReferenceDate: 100))
    record.note(entry(2, node: "send-a", phase: .running), at: Date(timeIntervalSinceReferenceDate: 110))
    record.note(entry(3, node: "send-b", phase: .running), at: Date(timeIntervalSinceReferenceDate: 120))
    record.sealInterrupted()
    #expect(record.conclusion == .interrupted)
    #expect(record.endedAt == Date(timeIntervalSinceReferenceDate: 120))
    #expect(record.trace.dropFirst().allSatisfy {
        $0.phase == .cancelled && $0.detail == SZAgentGraphRun.interruptedDetail
    })
    // The settled entry keeps its own (absent) detail — only the truncated ones are marked.
    #expect(record.trace[0].detail == nil)
}

@Test func sealInterruptedWithoutATraceStopsAtTheStartAndLeavesEndedRecordsAlone() {
    var bare = run(50, live: true)
    bare.sealInterrupted()
    #expect(bare.conclusion == .interrupted)
    #expect(bare.endedAt == bare.startedAt)

    var ended = run(0)
    ended.seal(conclusion: .ended)
    let before = ended
    ended.sealInterrupted()
    #expect(ended == before)
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

// MARK: - The turn a visit ran

@Test func aTurnVisitsIdRidesItsEntryAndSurvivesReEmits() {
    // `turnID` is what a card's activity band hangs off, so it must outlive the phase
    // change that settles the visit — a re-emit without one never erases it, exactly as
    // the tally and the receipt behave.
    let id = UUID()
    var record = run(0, live: true)
    var running = entry(1, node: "implement", phase: .running)
    running.turnID = id
    record.note(running)
    record.note(entry(1, node: "implement", phase: .running))
    #expect(record.trace[0].turnID == id)
    record.note(entry(1, node: "implement", phase: .done, outcome: "ok"))
    #expect(record.trace[0].turnID == id)
}

@Test func aRevisitCarriesItsOwnTurnNotTheFirstVisits() {
    // Two visits of one turn node are two turns, and a card reads the words of the visit
    // it draws — keying by ordinal is what keeps a loop's second pass off the first card.
    let first = UUID(), second = UUID()
    var record = run(0, live: true)
    var a = entry(1, node: "implement", phase: .done, outcome: "ok"); a.turnID = first
    var b = entry(2, node: "implement", phase: .done, outcome: "ok"); b.turnID = second
    record.note(a); record.note(b)
    #expect(record.trace.map(\.turnID) == [first, second])
}

@Test func entryTurnIDRoundTrips() throws {
    var stamped = entry(1, phase: .done, outcome: "ok")
    stamped.turnID = UUID()
    let decoded = try JSONDecoder().decode(SZAgentGraphRun.Entry.self,
                                           from: JSONEncoder().encode(stamped))
    #expect(decoded.turnID == stamped.turnID)
}

@Test func entryWithoutOptionalsEncodesWithoutTheirKeys() throws {
    // An absent value must not be encoded — no key that says nothing.
    let data = try JSONEncoder().encode(entry(1, phase: .done))
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("startedAt"))
    #expect(!text.contains("endedAt"))
    #expect(!text.contains("outcome"))
    #expect(!text.contains("detail"))
    #expect(!text.contains("turnID"))
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
