// SPDX-License-Identifier: AGPL-3.0-only
// The supervision machine's gate: every confirmed failure mode of the previous campaign's
// host-level supervision, re-expressed as event lists against THE REAL machine — no replica
// supervisor, no simulated host. Each test is named for the scar it keeps fixed; where the
// original scenario spoke in envelopes and task handles, the doc comment states the
// machine's spelling of the same invariant.
import Testing
import Foundation
@testable import SZCore

private let deadline: Duration = .seconds(900)

private func makeBounds(roundCeiling: Int = 8, defaultRounds: Int = 4) -> SZThreadMachine.Bounds {
    .init(roundCeiling: roundCeiling, dispatchDeadline: deadline, defaultRounds: defaultRounds)
}

private func openedMachine(roundCeiling: Int = 8, defaultRounds: Int = 4,
                           graphRounds: Int? = nil, handlesSettled: Bool = true,
                           kind: SZMessageKind = .build) -> SZThreadMachine {
    var machine = SZThreadMachine(bounds: makeBounds(roundCeiling: roundCeiling,
                                                     defaultRounds: defaultRounds))
    _ = machine.handle(.opened(kind: kind, graphRounds: graphRounds, handlesSettled: handlesSettled))
    return machine
}

/// Conclude the in-flight traversal with a dispatch and return the minted set id.
private func dispatch(_ machine: inout SZThreadMachine, items: [String],
                      notes: [String: String] = [:], target: String = "coding") -> Int {
    let commands = machine.handle(.traversalConcluded(.ended, dispatch:
        .init(target: target, items: items, notes: notes)))
    for case .deliverItems(let setID, _, _) in commands { return setID }
    Issue.record("dispatch minted no set")
    return -1
}

private func settledSummary(in commands: [SZThreadMachine.Command]) -> SZSettledSummary? {
    for case .deliverSettled(let summary) in commands { return summary }
    return nil
}

// MARK: - The reference scenarios, one test each

/// Scenario: a settled reply waits while a director traversal is in flight. The machine
/// makes the gate structural — no event can start a second traversal while one runs: a
/// stray settle, watchdog or steer during `.traversing` emits nothing that traverses, and
/// the settled re-entry starts only from the machine's own set closure.
@Test func aSettledReplyWaitsWhileADirectorTraversalIsInFlight() {
    var machine = openedMachine()
    #expect(machine.state == .traversing(kind: .build))
    for event: SZThreadMachine.Event in [
        .itemSettled(node: "n", setID: 1, outcome: "ok"),
        .watchdogFired(setID: 1),
        .absorbSteer("queued, not traversed"),
    ] {
        #expect(machine.handle(event).isEmpty)
    }
    #expect(machine.state == .traversing(kind: .build))
    let setID = dispatch(&machine, items: ["a"])
    let closure = machine.handle(.itemSettled(node: "a", setID: setID, outcome: "ok"))
    #expect(closure.contains(.startTraversal(kind: .settled, round: 1,
                                             steers: ["queued, not traversed"])))
}

/// Scenario: a late outcome settles only its own set. Settlement is keyed by set id, never
/// node id — a straggler from a timed-out set must not touch the younger set a re-dispatch
/// put the same node into, and a closed set drops every later settle.
@Test func aLateOutcomeSettlesOnlyItsOwnSet() {
    var machine = openedMachine()
    let old = dispatch(&machine, items: ["n"])
    let timedOut = machine.handle(.watchdogFired(setID: old))
    #expect(settledSummary(in: timedOut)?.outcomes["n"]?.hasPrefix("timedOut") == true)
    let young = dispatch(&machine, items: ["n"])
    #expect(young != old)
    // The straggler's late truth arrives against the CLOSED set: dropped entirely.
    #expect(machine.handle(.itemSettled(node: "n", setID: old, outcome: "ok")).isEmpty)
    // The young set settles on its own terms; its summary carries the fresh outcome.
    let closure = machine.handle(.itemSettled(node: "n", setID: young,
                                              outcome: "needsInput: which palette?"))
    #expect(settledSummary(in: closure)?.outcomes["n"] == "needsInput: which palette?")
    // And settling the completed set AGAIN is a no-op — exactly one reply per set.
    #expect(machine.handle(.itemSettled(node: "n", setID: young, outcome: "ok")).isEmpty)
}

/// Scenario: a timeout cancels the straggler's work and synthesizes the settled reply.
/// The machine orders the cancel of exactly what it timed out, marks it timed-out in the
/// summary, and closes the set — the reply is unconditional, not an optimization.
@Test func aTimeoutCancelsTheStragglersAndSynthesizesTheSettledReply() {
    var machine = openedMachine()
    let setID = dispatch(&machine, items: ["a", "b"])
    _ = machine.handle(.itemDelivered(node: "a", setID: setID))
    _ = machine.handle(.itemSettled(node: "a", setID: setID, outcome: "ok"))
    let commands = machine.handle(.watchdogFired(setID: setID))
    #expect(commands.contains(.cancelItems(setID: setID, nodes: ["b"])))
    let summary = settledSummary(in: commands)
    #expect(summary?.outcomes["a"] == "ok")
    #expect(summary?.outcomes["b"]?.hasPrefix("timedOut") == true)
    // The set is closed: the straggler's genuine settle after synthesis is dropped.
    #expect(machine.handle(.itemSettled(node: "b", setID: setID, outcome: "ok")).isEmpty)
}

/// Scenario: an undeliverable item still settles, instantly and with the real diagnosis —
/// the dispatcher never waits out the watchdog to learn what the host knew at delivery
/// time. The machine's spelling: a settle needs no prior delivery, and the outcome string
/// travels verbatim into the summary.
@Test func anUndeliverableItemSettlesInstantlyWithTheRealReason() {
    var machine = openedMachine()
    let setID = dispatch(&machine, items: ["a"])
    let commands = machine.handle(.itemSettled(node: "a", setID: setID,
                                               outcome: "error: no work graph for this dispatch"))
    #expect(settledSummary(in: commands)?.outcomes["a"] == "error: no work graph for this dispatch")
    #expect(machine.state == .traversing(kind: .settled))
}

/// Scenario: notes and blockers are captured into the send itself. The machine's spelling:
/// the sender's note and the per-item attempt are stamped into the order at dispatch — a
/// re-dispatched node carries attempt 2 and never a stale note.
@Test func notesAndAttemptsAreCapturedIntoTheOrderAtSend() {
    var machine = openedMachine()
    var commands = machine.handle(.traversalConcluded(.ended, dispatch:
        .init(target: "coding", items: ["n"], notes: ["n": "Use Rec.709 luma weights."])))
    var firstSet = -1
    for case .deliverItems(let setID, let target, let orders) in commands {
        firstSet = setID
        #expect(target == "coding")
        #expect(orders == [SZDispatchOrder(node: "n", attempt: 1,
                                           senderNote: "Use Rec.709 luma weights.")])
    }
    #expect(machine.attempts["n"] == 1)
    // The watchdog is armed with the send, at the injected deadline.
    #expect(commands.contains(.armWatchdog(setID: firstSet, after: deadline)))

    _ = machine.handle(.watchdogFired(setID: firstSet))
    commands = machine.handle(.traversalConcluded(.ended, dispatch:
        .init(target: "coding", items: ["n"], notes: [:])))
    for case .deliverItems(_, _, let orders) in commands {
        #expect(orders == [SZDispatchOrder(node: "n", attempt: 2, senderNote: nil)])
    }
    #expect(machine.attempts["n"] == 2)
}

/// Scenario: a dead item's detail reaches the record (the reference surfaced it on the
/// node). The machine's spelling: a failed outcome string reaches the settled summary
/// verbatim and counts in the failed tally the dispatch card draws.
@Test func aFailedItemsDetailReachesTheSummaryVerbatimAndTheFailedTally() {
    var machine = openedMachine()
    let setID = dispatch(&machine, items: ["a", "b"])
    _ = machine.handle(.itemSettled(node: "a", setID: setID, outcome: "ok"))
    let commands = machine.handle(.itemSettled(node: "b", setID: setID,
                                               outcome: "error: exited before emitting any event"))
    #expect(commands.contains(.amendTally(setID: setID, settled: 2, total: 2, failed: 1)))
    #expect(settledSummary(in: commands)?.outcomes["b"] == "error: exited before emitting any event")
}

/// Scenario: the retry hint keys on the settled declaration. The machine's spelling: a
/// thread opened over a graph declaring no settled entry concludes at its set's close —
/// keyed on the declaration handed to `opened`, never on a graph's name (the machine
/// cannot even see one).
@Test func aRetrylessGraphConcludesAtFirstSettleInsteadOfReentering() {
    var machine = openedMachine(handlesSettled: false)
    let setID = dispatch(&machine, items: ["a"])
    let commands = machine.handle(.itemSettled(node: "a", setID: setID, outcome: "ok"))
    #expect(commands.contains(.conclude(.ended, unconsumedSteers: [])))
    #expect(!commands.contains { if case .startTraversal = $0 { true } else { false } })
    #expect(machine.state == .concluded(.ended))
}

/// Scenario: settling an item amends the dispatch card. The machine's spelling: every
/// settle and every timeout emits a live tally so the card counts up while items land —
/// and the synthesized stragglers amend too, so the card and the Director always agree.
@Test func everyItemSettleAmendsTheDispatchTallyLive() {
    var machine = openedMachine()
    let setID = dispatch(&machine, items: ["a", "b", "c"])
    #expect(machine.handle(.itemSettled(node: "a", setID: setID, outcome: "ok"))
        .contains(.amendTally(setID: setID, settled: 1, total: 3, failed: 0)))
    #expect(machine.handle(.itemSettled(node: "b", setID: setID, outcome: "error: died"))
        .contains(.amendTally(setID: setID, settled: 2, total: 3, failed: 1)))
    #expect(machine.handle(.watchdogFired(setID: setID))
        .contains(.amendTally(setID: setID, settled: 3, total: 3, failed: 2)))
}

/// Scenario: concluding a thread drains what it staged. The machine's spelling: the
/// conclude command is the single ending — emitted exactly once, carrying the unconsumed
/// steers so the host's ceremony can sweep them; no later event mints a second ending.
@Test func concludingReportsUnconsumedSteersExactlyOnce() {
    var machine = openedMachine(handlesSettled: false)
    let setID = dispatch(&machine, items: ["a"])
    _ = machine.handle(.absorbSteer("prefer the darker palette"))
    let commands = machine.handle(.itemSettled(node: "a", setID: setID, outcome: "ok"))
    #expect(commands.contains(.conclude(.ended, unconsumedSteers: ["prefer the darker palette"])))
    // No second ending, whatever arrives afterwards.
    #expect(machine.handle(.stopRequested).isEmpty)
    #expect(machine.handle(.traversalConcluded(.ended, dispatch: nil)).isEmpty)
}

/// Scenario: a stopped thread leaves nothing delivering. Stop closes the open set (its
/// outstanding items get the cancel order) and concludes cancelled — no settled summary
/// is synthesized, because a stopped conversation just ends.
@Test func aStopClosesTheOpenSetAndConcludesCancelled() {
    var machine = openedMachine()
    let setID = dispatch(&machine, items: ["a", "b"])
    let commands = machine.handle(.stopRequested)
    #expect(commands.contains(.cancelItems(setID: setID, nodes: ["a", "b"])))
    #expect(commands.contains(.conclude(.cancelled, unconsumedSteers: [])))
    #expect(settledSummary(in: commands) == nil)
    #expect(!commands.contains(.cancelTraversal))   // no traversal was in flight
    #expect(machine.state == .concluded(.cancelled))
}

/// Scenario: a thread never drains another thread's staged op. The machine's spelling:
/// events keyed to a set this machine never minted are refused without effect — the open
/// set stays intact and still settles normally afterwards.
@Test func eventsKeyedToAForeignSetNeverTouchTheOpenSet() {
    var machine = openedMachine()
    let setID = dispatch(&machine, items: ["a"])
    #expect(machine.handle(.itemSettled(node: "a", setID: setID + 99, outcome: "ok")).isEmpty)
    #expect(machine.handle(.watchdogFired(setID: setID + 99)).isEmpty)
    #expect(machine.handle(.itemDelivered(node: "a", setID: setID + 99)).isEmpty)
    let closure = machine.handle(.itemSettled(node: "a", setID: setID, outcome: "ok"))
    #expect(settledSummary(in: closure)?.outcomes["a"] == "ok")
}

/// Scenario: an unspeakable operation is refused at the boundary. The machine's spelling:
/// an event its state declares no entry for is refused without effect — opening twice, a
/// zombie traversal conclusion while the fleet is out, a settle before anything opened.
@Test func anEventTheStateHasNoEntryForIsRefusedWithoutEffect() {
    var fresh = SZThreadMachine(bounds: makeBounds())
    #expect(fresh.handle(.itemSettled(node: "a", setID: 1, outcome: "ok")).isEmpty)
    #expect(fresh.state == .opening)

    var machine = openedMachine()
    #expect(machine.handle(.opened(kind: .build, graphRounds: nil, handlesSettled: true)).isEmpty)
    _ = dispatch(&machine, items: ["a"])
    // A zombie conclusion while awaiting the fleet must not resurrect a traversal.
    #expect(machine.handle(.traversalConcluded(.ended, dispatch: nil)).isEmpty)
    #expect(machine.state == .awaitingFleet)
}

// MARK: - Machine semantics beyond the ported catalog

/// The opening traversal carries round 0, the thread's kind, and every steer absorbed
/// before the open — drained, so the next traversal never repeats them.
@Test func theOpeningTraversalCarriesRoundZeroAndDrainedSteers() {
    var machine = SZThreadMachine(bounds: makeBounds())
    _ = machine.handle(.absorbSteer("start with the blur node"))
    let commands = machine.handle(.opened(kind: .request, graphRounds: nil, handlesSettled: true))
    #expect(commands == [.startTraversal(kind: .request, round: 0,
                                         steers: ["start with the blur node"])])
    #expect(machine.state == .traversing(kind: .request))
    #expect(machine.round == 0)
    let setID = dispatch(&machine, items: ["a"])
    let closure = machine.handle(.itemSettled(node: "a", setID: setID, outcome: "ok"))
    #expect(closure.contains(.startTraversal(kind: .settled, round: 1, steers: [])))
}

/// A steer absorbed while the fleet is out rides the NEXT traversal — the settled
/// re-entry — and is drained by it.
@Test func aSteerAbsorbedMidFlightRidesTheSettledReentry() {
    var machine = openedMachine()
    let setID = dispatch(&machine, items: ["a"])
    _ = machine.handle(.absorbSteer("use the darker palette"))
    let closure = machine.handle(.itemSettled(node: "a", setID: setID, outcome: "ok"))
    #expect(closure.contains(.startTraversal(kind: .settled, round: 1,
                                             steers: ["use the darker palette"])))
}

/// The leash a graph cannot remove: a settled re-entry past the host ceiling concludes
/// `.roundCeiling` LOUDLY instead of traversing, whatever the graph declared.
@Test func aSettledReentryPastTheHostCeilingConcludesLoudly() {
    var machine = openedMachine(roundCeiling: 1, graphRounds: 99)
    var setID = dispatch(&machine, items: ["a"])
    _ = machine.handle(.itemSettled(node: "a", setID: setID, outcome: "error: retry me"))
    #expect(machine.state == .traversing(kind: .settled))   // round 1 — still allowed
    setID = dispatch(&machine, items: ["a"])
    let commands = machine.handle(.itemSettled(node: "a", setID: setID, outcome: "error: again"))
    #expect(commands.contains(.conclude(.roundCeiling(round: 2), unconsumedSteers: [])))
    #expect(machine.state == .concluded(.roundCeiling(round: 2)))
}

/// The graph's own rounds cap binds when it is the smaller bound — and an absent cap
/// falls back to the injected default, never to an environment read.
@Test func theGraphsOwnRoundsCapBindsBeforeTheHostCeiling() {
    var machine = openedMachine(roundCeiling: 8, graphRounds: 1)
    var setID = dispatch(&machine, items: ["a"])
    _ = machine.handle(.itemSettled(node: "a", setID: setID, outcome: "error: retry me"))
    #expect(machine.state == .traversing(kind: .settled))
    setID = dispatch(&machine, items: ["a"])
    #expect(machine.handle(.itemSettled(node: "a", setID: setID, outcome: "error: again"))
        .contains(.conclude(.roundCeiling(round: 2), unconsumedSteers: [])))

    var defaulted = openedMachine(roundCeiling: 8, defaultRounds: 1, graphRounds: nil)
    setID = dispatch(&defaulted, items: ["a"])
    _ = defaulted.handle(.itemSettled(node: "a", setID: setID, outcome: "ok"))
    #expect(defaulted.state == .traversing(kind: .settled))
    setID = dispatch(&defaulted, items: ["a"])
    #expect(defaulted.handle(.itemSettled(node: "a", setID: setID, outcome: "ok"))
        .contains(.conclude(.roundCeiling(round: 2), unconsumedSteers: [])))
}

/// A stop mid-traversal cancels the traversal and concludes immediately; the cancelled
/// traversal's eventual conclusion is absorbed as the `.concluding` → `.concluded`
/// graduation — no commands, nothing resurrected, even when the zombie claims a dispatch.
@Test func aLateTraversalConclusionAfterStopResurrectsNothing() {
    var machine = openedMachine()
    let commands = machine.handle(.stopRequested)
    #expect(commands == [.cancelTraversal, .conclude(.cancelled, unconsumedSteers: [])])
    #expect(machine.state == .concluding)
    #expect(machine.handle(.traversalConcluded(.ended, dispatch:
        .init(target: "coding", items: ["a"], notes: [:]))).isEmpty)
    #expect(machine.state == .concluded(.cancelled))
    #expect(machine.handle(.traversalConcluded(.cancelled, dispatch: nil)).isEmpty)
    #expect(machine.state == .concluded(.cancelled))
}

/// Termination is absorbing by construction: after a thread concludes, every event is a
/// no-op command-wise and the state never leaves `.concluded`.
@Test func aConcludedThreadAbsorbsEveryLaterEvent() {
    var machine = openedMachine()
    _ = machine.handle(.traversalConcluded(.ended, dispatch: nil))
    #expect(machine.state == .concluded(.ended))
    for event: SZThreadMachine.Event in [
        .opened(kind: .build, graphRounds: nil, handlesSettled: true),
        .traversalConcluded(.failed(reason: "late"), dispatch: nil),
        .itemDelivered(node: "a", setID: 1),
        .itemSettled(node: "a", setID: 1, outcome: "ok"),
        .watchdogFired(setID: 1),
        .absorbSteer("too late"),
        .stopRequested,
    ] {
        #expect(machine.handle(event).isEmpty)
        #expect(machine.state == .concluded(.ended))
    }
}

/// Termination is structural: a traversal concluding with no orders while nothing is
/// outstanding IS the ending — mapped from the traversal's own conclusion, with a refusal
/// kept as its own class (never a failure, never "complete").
@Test func aTraversalConcludingWithNoOrdersEndsTheThreadStructurally() {
    let mappings: [(SZTraversalEnding, SZThreadConclusion)] = [
        (.ended, .ended),
        (.declined(reason: "nothing to build"), .declined(reason: "nothing to build")),
        (.failed(reason: "step threw"), .failed(reason: "step threw")),
        (.cancelled, .cancelled),
        (.defect(detail: "unknown step"), .defect(detail: "unknown step")),
    ]
    for (traversal, thread) in mappings {
        var machine = openedMachine()
        let commands = machine.handle(.traversalConcluded(traversal, dispatch: nil))
        #expect(commands == [.conclude(thread, unconsumedSteers: [])])
        #expect(machine.state == .concluded(thread))
    }
}

/// An empty dispatch is no dispatch: a traversal that "sent" zero items concludes the
/// thread instead of parking it awaiting a fleet that will never report.
@Test func anEmptyDispatchIsNoDispatch() {
    var machine = openedMachine()
    let commands = machine.handle(.traversalConcluded(.ended, dispatch:
        .init(target: "coding", items: [], notes: [:])))
    #expect(commands == [.conclude(.ended, unconsumedSteers: [])])
    #expect(machine.state == .concluded(.ended))
}

/// The watchdog for a set that already closed is absorbed — the host may cancel its timer
/// on closure as an optimization, but correctness never depends on the cancel landing.
@Test func aWatchdogForAClosedSetIsAbsorbed() {
    var machine = openedMachine()
    let setID = dispatch(&machine, items: ["a"])
    _ = machine.handle(.itemSettled(node: "a", setID: setID, outcome: "ok"))
    #expect(machine.handle(.watchdogFired(setID: setID)).isEmpty)
}

/// A stop before the thread ever traversed still concludes cleanly — no cancel orders
/// for work that never existed.
@Test func aStopBeforeOpeningConcludesCancelled() {
    var machine = SZThreadMachine(bounds: makeBounds())
    #expect(machine.handle(.stopRequested) == [.conclude(.cancelled, unconsumedSteers: [])])
    #expect(machine.state == .concluded(.cancelled))
}

/// Exactly one outcome per item within an open set: a duplicate settle of an already
/// settled member is refused — it neither bumps the tally nor overwrites the outcome.
@Test func aDuplicateSettleOfASettledItemIsRefused() {
    var machine = openedMachine()
    let setID = dispatch(&machine, items: ["a", "b"])
    _ = machine.handle(.itemSettled(node: "a", setID: setID, outcome: "ok"))
    #expect(machine.handle(.itemSettled(node: "a", setID: setID, outcome: "error: flip")).isEmpty)
    let closure = machine.handle(.itemSettled(node: "b", setID: setID, outcome: "ok"))
    #expect(settledSummary(in: closure)?.outcomes["a"] == "ok")
}

/// The settled summary names its sender and its re-entry round — what the re-entry's
/// delivery binding is built from.
@Test func theSettledSummaryCarriesSenderAndRound() {
    var machine = openedMachine()
    let setID = dispatch(&machine, items: ["a"], target: "coding")
    let closure = machine.handle(.itemSettled(node: "a", setID: setID, outcome: "ok"))
    #expect(settledSummary(in: closure)
        == SZSettledSummary(setID: setID, from: "coding", outcomes: ["a": "ok"], round: 1))
}
