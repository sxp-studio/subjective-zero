// SPDX-License-Identifier: AGPL-3.0-only
// Which run the Agent Graph panel's canvas draws: the latest by default, an explicit pick
// while it lasts, and an honest fallback when that pick ages out of the capped list.
import Foundation
import Testing
import SZCore
@testable import SZUI

private func run(_ started: TimeInterval, live: Bool = false) -> SZAgentGraphRun {
    SZAgentGraphRun(id: UUID(), agent: "director",
                    startedAt: Date(timeIntervalSinceReferenceDate: started),
                    endedAt: live ? nil : Date(timeIntervalSinceReferenceDate: started + 5))
}

@Test func noPickShowsTheHeadOfTheList() {
    // The host keeps the list live-first, newest-first — so the head IS "the latest run".
    let runs = SZAgentGraphRun.ordered([run(10), run(30), run(20, live: true)])
    #expect(SZAgentGraphRunSelection.select(runs, id: nil)?.id == runs[0].id)
}

@Test func anExplicitPickSticks() {
    let runs = SZAgentGraphRun.ordered([run(10), run(30)])
    #expect(SZAgentGraphRunSelection.select(runs, id: runs[1].id)?.id == runs[1].id)
}

@Test func aVanishedPickFallsBackToTheHead() {
    let runs = SZAgentGraphRun.ordered([run(10), run(30)])
    #expect(SZAgentGraphRunSelection.select(runs, id: UUID())?.id == runs[0].id)
}

@Test func anEmptyListSelectsNothing() {
    #expect(SZAgentGraphRunSelection.select([], id: nil) == nil)
}
