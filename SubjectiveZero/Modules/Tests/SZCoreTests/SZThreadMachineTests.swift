// SPDX-License-Identifier: AGPL-3.0-only
// The dispatch-set supervisor, driven as THE REAL THING with event lists — never a replica.
// The invariants under test: one open set at a time, exactly one summary per set (collected
// or synthesized), attempts accumulate per item across sets, closed sets absorb every late
// event, and a stop sweeps without synthesizing.
import Foundation
import Testing
@testable import SZCore

private let bounds = SZThreadMachine.Bounds(dispatchDeadline: .seconds(300))

private func machineWithOpenSet(
    _ items: [String] = ["a", "b"]) -> (machine: SZThreadMachine, setID: Int) {
    var machine = SZThreadMachine(bounds: bounds)
    let commands = machine.handle(.dispatched(SZDispatchIntent(target: "coding", items: items)))
    guard case .deliverItems(let setID, _, _) = commands.first else {
        Issue.record("expected deliverItems, got \(commands)")
        return (machine, 0)
    }
    return (machine, setID)
}

struct SZThreadMachineTests {

    // MARK: - Minting

    @Test func aDispatchMintsOneSetWithStampedAttemptsAndAWatchdog() {
        var machine = SZThreadMachine(bounds: bounds)
        let commands = machine.handle(.dispatched(SZDispatchIntent(
            target: "coding", items: ["a", "b", "a"], notes: ["b": "careful"])))
        // Duplicates dedupe; each order carries its per-item attempt and the sender's note.
        #expect(commands == [
            .deliverItems(setID: 1, target: "coding", orders: [
                SZDispatchOrder(node: "a", attempt: 1),
                SZDispatchOrder(node: "b", attempt: 1, senderNote: "careful"),
            ]),
            .armWatchdog(setID: 1, after: .seconds(300)),
        ])
        #expect(machine.state == .awaitingFleet)
    }

    @Test func attemptsAccumulateAcrossSets() {
        var (machine, set1) = machineWithOpenSet(["a"])
        _ = machine.handle(.workSettled(node: "a", setID: set1, outcome: "error: no"))
        let second = machine.handle(.dispatched(SZDispatchIntent(target: "coding", items: ["a"])))
        guard case .deliverItems(_, _, let orders) = second.first else {
            Issue.record("expected deliverItems"); return
        }
        // The retry loop re-dispatches the same node: its briefing must say attempt 2.
        #expect(orders == [SZDispatchOrder(node: "a", attempt: 2)])
    }

    @Test func aSecondDispatchWhileOneIsOpenIsRefused() {
        var (machine, _) = machineWithOpenSet()
        #expect(machine.handle(.dispatched(SZDispatchIntent(target: "coding", items: ["c"]))) == [])
    }

    @Test func anEmptyDispatchMintsNothing() {
        var machine = SZThreadMachine(bounds: bounds)
        #expect(machine.handle(.dispatched(SZDispatchIntent(target: "coding", items: []))) == [])
        #expect(machine.state == .idle)
    }

    // MARK: - Settling

    @Test func theLastItemLandingClosesTheSetWithOneSummary() {
        var (machine, setID) = machineWithOpenSet()
        let first = machine.handle(.workSettled(node: "a", setID: setID, outcome: "ok"))
        #expect(first == [.amendTally(setID: setID, settled: 1, total: 2, failed: 0)])

        let second = machine.handle(.workSettled(node: "b", setID: setID, outcome: "error: boom"))
        #expect(second == [
            .amendTally(setID: setID, settled: 2, total: 2, failed: 1),
            .settled(SZSettledSummary(setID: setID, from: "coding",
                                      outcomes: ["a": "ok", "b": "error: boom"], round: 1)),
        ])
        // Closed and ready for the next set — the retry loop's re-dispatch.
        #expect(machine.state == .idle)
        #expect(machine.round == 1)
    }

    @Test func roundCountsClosedSets() {
        var (machine, set1) = machineWithOpenSet(["a"])
        _ = machine.handle(.workSettled(node: "a", setID: set1, outcome: "ok"))
        var (m2, set2) = (machine, 0)
        let commands = m2.handle(.dispatched(SZDispatchIntent(target: "coding", items: ["a"])))
        if case .deliverItems(let id, _, _) = commands.first { set2 = id }
        let closing = m2.handle(.workSettled(node: "a", setID: set2, outcome: "ok"))
        guard case .settled(let summary) = closing.last else {
            Issue.record("expected a summary"); return
        }
        #expect(summary.round == 2)
    }

    @Test func aLateSettleAgainstAClosedSetIsAbsorbed() {
        var (machine, setID) = machineWithOpenSet(["a"])
        _ = machine.handle(.workSettled(node: "a", setID: setID, outcome: "ok"))
        #expect(machine.handle(.workSettled(node: "a", setID: setID, outcome: "ok")) == [])
        #expect(machine.handle(.workSettled(node: "a", setID: 99, outcome: "ok")) == [])
    }

    @Test func aSecondOutcomeForTheSameItemIsDropped() {
        var (machine, setID) = machineWithOpenSet()
        _ = machine.handle(.workSettled(node: "a", setID: setID, outcome: "ok"))
        // The duplicate must not close the set nor overwrite the first outcome.
        #expect(machine.handle(.workSettled(node: "a", setID: setID, outcome: "error: x")) == [])
        let closing = machine.handle(.workSettled(node: "b", setID: setID, outcome: "ok"))
        guard case .settled(let summary) = closing.last else {
            Issue.record("expected a summary"); return
        }
        #expect(summary.outcomes["a"] == "ok")
    }

    // MARK: - The watchdog

    @Test func theWatchdogSynthesizesStragglersAndCancelsThemFirst() {
        var (machine, setID) = machineWithOpenSet()
        _ = machine.handle(.workSettled(node: "a", setID: setID, outcome: "ok"))
        let fired = machine.handle(.watchdogFired(setID: setID))
        // Cancel BEFORE the summary ships — the machine's stated order.
        guard case .cancelItems(let cancelledSet, let nodes) = fired.first else {
            Issue.record("expected cancelItems first, got \(fired)"); return
        }
        #expect(cancelledSet == setID)
        #expect(nodes == ["b"])
        guard case .settled(let summary) = fired.last else {
            Issue.record("expected a summary last"); return
        }
        #expect(summary.outcomes["a"] == "ok")
        #expect(summary.outcomes["b"]?.hasPrefix("timedOut") == true)
        // The synthesized straggler counts as failed — the deadline is stated in the text.
        #expect(summary.failedCount == 1)
        #expect(summary.outcomes["b"]?.contains("300s") == true)
    }

    @Test func aWatchdogAgainstAClosedSetIsAbsorbed() {
        var (machine, setID) = machineWithOpenSet(["a"])
        _ = machine.handle(.workSettled(node: "a", setID: setID, outcome: "ok"))
        #expect(machine.handle(.watchdogFired(setID: setID)) == [])
    }

    // MARK: - Stop

    @Test func stopSweepsTheOpenSetAndSynthesizesNothing() {
        var (machine, setID) = machineWithOpenSet()
        _ = machine.handle(.workSettled(node: "a", setID: setID, outcome: "ok"))
        let stopped = machine.handle(.stopRequested)
        // The outstanding item is cancelled; no summary ships — the waiting traversal is
        // being cancelled, and a stopped conversation just ends.
        #expect(stopped == [.cancelItems(setID: setID, nodes: ["b"])])
        #expect(machine.state == .stopped)
        // Absorbing: everything after the stop is a no-op.
        #expect(machine.handle(.workSettled(node: "b", setID: setID, outcome: "ok")) == [])
        #expect(machine.handle(.dispatched(SZDispatchIntent(target: "coding", items: ["c"]))) == [])
    }

    @Test func stopWhileIdleJustStops() {
        var machine = SZThreadMachine(bounds: bounds)
        #expect(machine.handle(.stopRequested) == [])
        #expect(machine.state == .stopped)
    }

    // MARK: - The summary's own rules

    @Test func theSummaryCountsFailuresByThePrefixRule() {
        let summary = SZSettledSummary(setID: 1, from: "coding", outcomes: [
            "a": "ok", "b": "ok: with detail", "c": "error: boom",
            "d": "declined: nope", "e": "timedOut: too slow",
        ], round: 1)
        #expect(summary.failedCount == 3)
    }

    @Test func theDeadlineTextSpeaksMillisecondsHonestly() {
        var machine = SZThreadMachine(bounds: .init(dispatchDeadline: .milliseconds(250)))
        _ = machine.handle(.dispatched(SZDispatchIntent(target: "coding", items: ["a"])))
        let fired = machine.handle(.watchdogFired(setID: 1))
        guard case .settled(let summary) = fired.last else {
            Issue.record("expected a summary"); return
        }
        #expect(summary.outcomes["a"]?.contains("250ms") == true)
    }
}
