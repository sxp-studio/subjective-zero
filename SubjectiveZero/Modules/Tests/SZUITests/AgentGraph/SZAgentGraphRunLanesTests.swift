// SPDX-License-Identifier: AGPL-3.0-only
// What the Agent Graph panel's history lists: the door-only routing pass is folded away, and
// everything that actually traversed — an ask-less conversation included — keeps its lane.
import Foundation
import Testing
import SZCore
@testable import SZUI

private func entry(_ ordinal: Int, _ node: String, _ outcome: String,
                   phase: SZAgentGraphRun.Entry.Phase = .done) -> SZAgentGraphRun.Entry {
    SZAgentGraphRun.Entry(ordinal: ordinal, node: node, phase: phase, outcome: outcome)
}

private func record(trace: [SZAgentGraphRun.Entry],
                    conclusion: SZAgentGraphRun.Conclusion? = .ended,
                    thread: UUID? = nil, work: String? = nil) -> SZAgentGraphRun {
    SZAgentGraphRun(id: UUID(), agent: "director", thread: thread, work: work,
                    endedAt: conclusion == nil ? nil : Date(), trace: trace, conclusion: conclusion)
}

@Test func aDoorOnlyRoutingPassGetsNoLane() {
    // The door ruled "build" and stopped: the build it minted is the run.
    let routing = record(trace: [entry(1, "door", "implement")])
    #expect(SZAgentGraphRunList.lanes([routing]).isEmpty)
}

@Test func anAskLessConversationKeepsItsLane() {
    // No title either, but it traversed — a conversation is a real run.
    let chat = record(trace: [entry(1, "door", "answer"), entry(2, "chat", "ok")])
    #expect(SZAgentGraphRunList.lanes([chat]).count == 1)
}

@Test func aBuildAndItsRoutingPassLeaveOneLane() {
    // The pair a single user message writes.
    let thread = UUID()
    var build = record(trace: [entry(1, "door", "build"), entry(2, "decompose", "ok")], thread: thread)
    build.id = thread
    build.title = "make the cube spin"
    let lanes = SZAgentGraphRunList.lanes([record(trace: [entry(1, "door", "implement")]), build])
    #expect(lanes.map(\.id) == [thread])
}

@Test func aDoorThatDidNotFinishCleanlyKeepsItsLane() {
    // The only record of a message that got nothing, so it stays visible.
    let failed = record(trace: [entry(1, "door", "error", phase: .failed)],
                        conclusion: .failed(reason: "the triage ask threw"))
    let stopped = record(trace: [entry(1, "door", "implement", phase: .cancelled)], conclusion: .cancelled)
    let live = record(trace: [entry(1, "door", "implement", phase: .running)], conclusion: nil)
    #expect(SZAgentGraphRunList.lanes([failed, stopped, live]).count == 3)
}

@Test func aWorkChildThatEndedAtItsDoorKeepsItsLane() {
    // A dispatched lane is the fleet's own row: it is never a routing pass, however short.
    let child = record(trace: [entry(1, "door", "ok")], thread: UUID(), work: "node-1")
    #expect(SZAgentGraphRunList.lanes([child]).count == 1)
}
