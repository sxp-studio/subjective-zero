// SPDX-License-Identifier: AGPL-3.0-only
// SZStripPlan — what the run strip shows once the caps bite, and what opening a fold adds. The
// rules that matter here are the ones a screenshot cannot check: live agents are never the ones
// hidden, an open group stops reordering itself, every group ends on exactly one elbow, and no
// expansion can grow the band past the budget the panel gave it.
import Foundation
import Testing
import SZCore
@testable import SZUI

private let base = Date(timeIntervalSinceReferenceDate: 0)

private func director(_ thread: UUID) -> SZAgentGraphRun {
    SZAgentGraphRun(id: thread, agent: "director", thread: thread, startedAt: base)
}

private func agent(_ thread: UUID, _ n: Int, live: Bool = true) -> SZAgentGraphRun {
    SZAgentGraphRun(id: UUID(), agent: "coding", thread: thread, work: "node-\(n)",
                    startedAt: base.addingTimeInterval(Double(n)),
                    endedAt: live ? nil : base.addingTimeInterval(Double(n) + 0.5))
}

private func fleet(_ thread: UUID, _ count: Int) -> [SZAgentGraphRun] {
    [director(thread)] + (1...count).map { agent(thread, $0) }
}

private func lanes(_ rows: [SZStripPlan.Row]) -> [SZAgentGraphRun] {
    rows.compactMap { if case .lane(let run, _) = $0 { run } else { nil } }
}

private func toggles(_ rows: [SZStripPlan.Row]) -> [SZStripPlan.Toggle] {
    rows.compactMap { if case .toggle(let toggle) = $0 { toggle } else { nil } }
}

private func elbows(_ rows: [SZStripPlan.Row]) -> [SZLaneConnector.Kind] {
    rows.compactMap {
        switch $0 {
        case .lane(_, let kind): kind
        case .toggle(let toggle): toggle.connector
        default: nil
        }
    }
}

@Test func closedGroupCapsTheFleetAndCountsTheRest() {
    let thread = UUID()
    let rows = SZStripPlan.rows(threads: [thread], runs: fleet(thread, 7), scheduled: [],
                                expanded: [], extraBudget: 10)
    #expect(lanes(rows).count == 3)
    #expect(toggles(rows).map(\.label) == ["+4 more"])
    #expect(toggles(rows).first?.help == "Show every agent on this build")
}

@Test func openGroupShowsEveryAgentInDispatchOrder() {
    let thread = UUID()
    let runs = fleet(thread, 7)
    let rows = SZStripPlan.rows(threads: [thread], runs: runs, scheduled: [],
                                expanded: [.thread(thread)], extraBudget: 10)
    #expect(lanes(rows).map(\.work) == runs.dropFirst().map(\.work))
    #expect(toggles(rows).map(\.label) == ["show less"])
}

@Test func closedFleetHidesSealedAgentsBeforeWorkingOnes() {
    let thread = UUID()
    // Four finished, dispatched first, then two still working: a plain prefix would show the
    // finished ones and fold away the agents actually building.
    let sealed = (1...4).map { agent(thread, $0, live: false) }
    let live = (5...6).map { agent(thread, $0) }
    let runs = [director(thread)] + sealed + live

    let closed = SZStripPlan.rows(threads: [thread], runs: runs, scheduled: [],
                                  expanded: [], extraBudget: 10)
    let workingFirst = lanes(closed).prefix(2).allSatisfy(\.isLive)
    #expect(workingFirst)

    // Open, nothing is hidden, so the live-first shuffle stops: pills must not move under the
    // cursor as agents settle.
    let open = SZStripPlan.rows(threads: [thread], runs: runs, scheduled: [],
                                expanded: [.thread(thread)], extraBudget: 10)
    #expect(lanes(open).map(\.work) == (sealed + live).map(\.work))
}

@Test func everyGroupWithAFleetEndsOnExactlyOneElbow() {
    let thread = UUID()
    for (fleetSize, expanded) in [(7, Set<SZStripPlan.Group>()), (7, [.thread(thread)]),
                                  (2, []), (3, [.thread(thread)]), (12, [.thread(thread)])] {
        let rows = SZStripPlan.rows(threads: [thread], runs: fleet(thread, fleetSize), scheduled: [],
                                    expanded: expanded, extraBudget: 4)
        #expect(elbows(rows).filter { $0 == .last }.count == 1)
        #expect(elbows(rows).last == .last)
    }
    // Two builds, one open: one elbow each, never a second inside a group.
    let other = UUID()
    let two = SZStripPlan.rows(threads: [thread, other], runs: fleet(thread, 7) + fleet(other, 5),
                               scheduled: [], expanded: [.thread(other)], extraBudget: 6)
    #expect(elbows(two).filter { $0 == .last }.count == 2)
    // A Director whose fleet has not gone out yet hangs nothing, so it draws no elbow.
    let bare = SZStripPlan.rows(threads: [thread], runs: [director(thread)], scheduled: [],
                                expanded: [], extraBudget: 6)
    #expect(elbows(bare).isEmpty)
}

@Test func openingCannotGrowTheBandPastTheBudget() {
    let thread = UUID()
    let closed = SZStripPlan.rows(threads: [thread], runs: fleet(thread, 12), scheduled: [],
                                  expanded: [], extraBudget: 4)
    let open = SZStripPlan.rows(threads: [thread], runs: fleet(thread, 12), scheduled: [],
                                expanded: [.thread(thread)], extraBudget: 4)
    #expect(lanes(open).count == 7)
    #expect(open.count - closed.count == 4)
    #expect(toggles(open).map(\.label) == ["show less · 5 not shown"])
}

@Test func openGroupsShareOneBudgetRatherThanRaceForIt() {
    let first = UUID(), second = UUID()
    let runs = fleet(first, 10) + fleet(second, 10)
    let closed = SZStripPlan.rows(threads: [first, second], runs: runs, scheduled: [],
                                  expanded: [], extraBudget: 5)
    let rows = SZStripPlan.rows(threads: [first, second], runs: runs, scheduled: [],
                                expanded: [.thread(first), .thread(second)], extraBudget: 5)
    // Neither build takes the whole budget and starves the other, and the two together stay inside it.
    #expect(lanes(rows).filter { $0.thread == first }.count > 3)
    #expect(lanes(rows).filter { $0.thread == second }.count > 3)
    #expect(rows.count - closed.count == 5)
}

@Test func aFoldOpensOntoSomethingWhileAnyRoomIsLeft() {
    // Three folds and three rows to give: one row each. A share rounded down to zero would relabel
    // the line and reveal nothing, which is the dead end the toggle exists to remove.
    let threads = (0..<3).map { _ in UUID() }
    let runs = threads.flatMap { fleet($0, 6) }
    let tasks = (1...6).map { SZScheduledRow(id: UUID(), title: "task \($0)") }
    let open: Set<SZStripPlan.Group> = [.thread(threads[0]), .thread(threads[1]),
                                        .thread(threads[2])]
    let closed = SZStripPlan.rows(threads: threads, runs: runs, scheduled: tasks,
                                  expanded: [], extraBudget: 3)
    let rows = SZStripPlan.rows(threads: threads, runs: runs, scheduled: tasks,
                                expanded: open, extraBudget: 3)
    #expect(rows.count > closed.count)
    for toggle in toggles(rows) where toggle.open {
        let closedHidden = SZStripPlan.hidden(in: toggle.group, threads: threads, runs: runs,
                                              scheduled: tasks)
        #expect(toggle.hidden < closedHidden)
    }
}

@Test func openGroupShortOfRoomStillShowsTheWorkingAgentsFirst() {
    // Nine finished, then three still building, and only room for six more rows. Opening must not
    // hand back a plain dispatch-order prefix: that buries every agent actually working.
    let thread = UUID()
    let sealedRuns = (1...9).map { agent(thread, $0, live: false) }
    let liveRuns = (10...12).map { agent(thread, $0) }
    let runs = [director(thread)] + sealedRuns + liveRuns
    let rows = SZStripPlan.rows(threads: [thread], runs: runs, scheduled: [],
                                expanded: [.thread(thread)], extraBudget: 6)
    let shown = lanes(rows)
    #expect(shown.count == 9)
    let workingFirst = shown.prefix(3).allSatisfy(\.isLive)
    #expect(workingFirst)
    #expect(toggles(rows).map(\.label) == ["show less · 3 not shown"])
}

@Test func theFoldLineStaysUnderTheCursorThatOpensIt() {
    // The band is pinned to the composer and grows upward, so a row's place on screen is set by how
    // many rows sit BELOW it. Every fold line must therefore keep its count of rows below when it
    // opens, or the control jumps away from the pointer that just clicked it.
    let threads = (0..<5).map { _ in UUID() }
    let runs = threads.flatMap { fleet($0, 7) }
    let tasks = (1...6).map { SZScheduledRow(id: UUID(), title: "task \($0)") }
    func rowsBelowEachFold(_ expanded: Set<SZStripPlan.Group>) -> [String: Int] {
        let rows = SZStripPlan.rows(threads: threads, runs: runs, scheduled: tasks,
                                    expanded: expanded, extraBudget: 12)
        var below: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            if case .toggle(let toggle) = row { below[toggle.group.key] = rows.count - 1 - index }
        }
        return below
    }
    let closed = rowsBelowEachFold([])
    for group in [SZStripPlan.Group.thread(threads[0]), .running, .queued] {
        let opened = rowsBelowEachFold([group])
        #expect(opened[group.key] == closed[group.key])
    }
}

@Test func topLevelFoldsCarryNoElbowAndSayWhatTheyHold() {
    let threads = (0..<5).map { _ in UUID() }
    let runs = threads.flatMap { fleet($0, 1) }
    let tasks = (1...5).map { SZScheduledRow(id: UUID(), title: "task \($0)") }
    let rows = SZStripPlan.rows(threads: threads, runs: runs, scheduled: tasks,
                                expanded: [], extraBudget: 6)
    let top = toggles(rows)
    #expect(top.map(\.label) == ["+2 more running", "+2 more queued"])
    let noElbows = top.allSatisfy { $0.connector == nil }
    #expect(noElbows)
    #expect(top.map(\.help) == ["Show every build running", "Show everything queued"])
}

@Test func theBudgetIsReadOffThePanelAndNeverGoesBelowThreeRows() {
    #expect(SZStripPlan.budget(panelHeight: 900) == Int(900 * 0.4 / SZLaneMetrics.rowHeight))
    #expect(SZStripPlan.budget(panelHeight: 160) == 3)
    #expect(SZStripPlan.budget(panelHeight: 0) == 3)
    #expect(SZStripPlan.budget(panelHeight: .nan) == 3)
    #expect(SZStripPlan.budget(panelHeight: .infinity) == 3)
}

@Test func withNoRoomToGiveTheBandIsExactlyTheClosedOne() {
    let thread = UUID()
    let closed = SZStripPlan.rows(threads: [thread], runs: fleet(thread, 9), scheduled: [],
                                  expanded: [], extraBudget: 0)
    let open = SZStripPlan.rows(threads: [thread], runs: fleet(thread, 9), scheduled: [],
                                expanded: [.thread(thread)], extraBudget: 0)
    #expect(closed.count == open.count)
    #expect(lanes(open).count == 3)
}

@Test func openingTheBuildsListAdmitsWholeGroupsOnly() {
    let threads = (0..<5).map { _ in UUID() }
    let runs = threads.flatMap { fleet($0, 2) }   // three rows each: a Director and two agents

    let closed = SZStripPlan.rows(threads: threads, runs: runs, scheduled: [],
                                  expanded: [], extraBudget: 5)
    #expect(toggles(closed).map(\.label) == ["+2 more running"])

    // Five spare rows admit ONE more build (three rows). Half of the next would read as a defect.
    let open = SZStripPlan.rows(threads: threads, runs: runs, scheduled: [],
                                expanded: [.running], extraBudget: 5)
    #expect(open.count - closed.count == 3)
    #expect(toggles(open).map(\.label) == ["show less · 1 not shown"])
}

@Test func openingTheQueueLeavesTheBuildFolded() {
    let thread = UUID()
    let tasks = (1...6).map { SZScheduledRow(id: UUID(), title: "task \($0)") }
    let closed = SZStripPlan.rows(threads: [thread], runs: fleet(thread, 7), scheduled: tasks,
                                  expanded: [], extraBudget: 10)
    #expect(toggles(closed).map(\.label) == ["+4 more", "+3 more queued"])

    // Opening the queue leaves the build folded, and vice versa.
    let open = SZStripPlan.rows(threads: [thread], runs: fleet(thread, 7), scheduled: tasks,
                                expanded: [.queued], extraBudget: 10)
    #expect(toggles(open).map(\.label) == ["+4 more", "show less"])
    #expect(open.filter { if case .scheduled = $0 { true } else { false } }.count == 6)
}

@Test func aBuildWithNoFleetYetStillReadsAsRunning() {
    let thread = UUID()
    let rows = SZStripPlan.rows(threads: [thread], runs: [], scheduled: [],
                                expanded: [], extraBudget: 10)
    #expect(rows.count == 1)
    let isWaiting = if case .waiting(let t) = rows.first { t == thread } else { false }
    #expect(isWaiting)
}
