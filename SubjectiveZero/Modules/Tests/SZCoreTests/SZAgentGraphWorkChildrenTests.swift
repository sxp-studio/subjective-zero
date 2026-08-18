// SPDX-License-Identifier: AGPL-3.0-only
// `workChildren` — the one rule for "the fleet a build sent out", shared by the run canvas's
// sub-agent band and the transcript's run strip so the two can never disagree about who is working.
import Foundation
import Testing
@testable import SZCore

private func child(thread: UUID, work: String, at offset: TimeInterval,
                   ended: Bool = false) -> SZAgentGraphRun {
    let start = Date(timeIntervalSince1970: 1_000 + offset)
    return SZAgentGraphRun(id: UUID(), agent: "coding", thread: thread, work: work,
                           startedAt: start, endedAt: ended ? start.addingTimeInterval(5) : nil)
}

/// Oldest first, never the ordering `ordered` imposes: a band of lanes must not reshuffle under the
/// reader as items settle.
@Test func workChildrenAreOldestFirstRegardlessOfListOrder() {
    let thread = UUID()
    let leader = SZAgentGraphRun(id: thread, agent: "director", thread: thread)
    let new = child(thread: thread, work: "b", at: 20)
    let old = child(thread: thread, work: "a", at: 10, ended: true)

    let children = SZAgentGraphRun.workChildren(thread: thread, in: SZAgentGraphRun.ordered([leader, new, old]))
    #expect(children.map(\.work) == ["a", "b"])   // settled first, because it started first
}

/// The leader is the dispatch, not one of its lanes.
@Test func workChildrenExcludeTheThreadLeader() {
    let thread = UUID()
    let leader = SZAgentGraphRun(id: thread, agent: "director", thread: thread)
    let children = SZAgentGraphRun.workChildren(thread: thread, in: [leader, child(thread: thread, work: "a", at: 1)])
    #expect(children.map(\.work) == ["a"])
}

/// Another build's fleet is not this one's, and off a run there is no fleet at all.
@Test func workChildrenIgnoreOtherThreadsAndNoThread() {
    let mine = UUID(), theirs = UUID()
    let runs = [child(thread: mine, work: "a", at: 1), child(thread: theirs, work: "b", at: 2)]
    #expect(SZAgentGraphRun.workChildren(thread: mine, in: runs).map(\.work) == ["a"])
    #expect(SZAgentGraphRun.workChildren(thread: nil, in: runs).isEmpty)
}
