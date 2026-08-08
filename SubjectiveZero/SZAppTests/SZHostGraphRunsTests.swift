// SPDX-License-Identifier: AGPL-3.0-only
// The RUNS-record host seam, smoke-tested end to end without a project or an engine: the
// strategy's hooks (begin → note → conclude → tally) land on `SZHost` and must leave the
// observable list the Agent Graph panel draws — ordered, sealed, tally-amended — with the
// engine's note vocabulary mapped onto the record's own trace entry.
import Foundation
import Testing
import SZAI
import SZCore
@testable import SubjectiveZero

@Test @MainActor func graphRunHooksBuildOrderAndSealTheRecords() throws {
    let host = SZHost()
    let build = UUID(), item = UUID()

    // A director traversal begins, works, and concludes by dispatching.
    host.beginAgentGraphRun(SZTraversalSighting(id: build, agent: "director",
                                                graphName: "build", kind: .build))
    host.noteAgentGraphRun(build, SZTraversalNote(ordinal: 1, node: "work-left", phase: .running))
    host.noteAgentGraphRun(build, SZTraversalNote(ordinal: 1, node: "work-left", phase: .done,
                                                  outcome: "yes"))
    // An item traversal starts while the build record is still live — the build must keep
    // the head of the list (it is what the panel follows).
    host.beginAgentGraphRun(SZTraversalSighting(id: item, agent: "coding", graphName: "item",
                                                kind: .item, item: "node-1"))
    #expect(host.agentGraphRuns.map(\.id) == [build, item])

    host.concludeAgentGraphRun(build, .ended)
    host.noteAgentGraphRun(item, SZTraversalNote(ordinal: 1, node: "implement", phase: .failed,
                                                 detail: "the turn threw"))
    host.concludeAgentGraphRun(item, .failed(reason: "the turn threw"))
    // The set settles after the sender sealed — the sanctioned post-seal amend.
    host.amendAgentGraphRunTally(build, settled: 1, total: 1, failed: 1)

    let sealed = host.agentGraphRuns
    #expect(sealed.allSatisfy { !$0.isLive })
    let buildRecord = try #require(sealed.first { $0.id == build })
    #expect(buildRecord.conclusion == .ended)
    #expect(buildRecord.tally == SZAgentGraphRun.Tally(settled: 1, total: 1, failed: 1))
    #expect(buildRecord.trace.map(\.outcome) == ["yes"])       // note replaced, not appended
    let itemRecord = try #require(sealed.first { $0.id == item })
    #expect(itemRecord.item == "node-1")
    #expect(itemRecord.conclusion == .failed(reason: "the turn threw"))
    #expect(itemRecord.trace.first?.detail == "the turn threw")

    // The drain sweep is a no-op once everything sealed itself (the healthy path).
    host.sealLeakedAgentGraphRuns(thread: nil)
    #expect(host.agentGraphRuns == sealed)
}

/// The wedged-fleet story at the host tier: one dispatched item never reports, the
/// watchdog fires, and the RECORDS must stay honest. The decisions come from the REAL
/// SZThreadMachine (its command semantics are pinned in SZThreadMachineTests); this test
/// is the machine's motor over a bare SZHost, mapping each command onto the same hooks
/// the run wires (`makeGraphOrchestrator`): amendTally → the sender's tally amend, and a
/// cancelItems order landing as the item traversal's cooperative-cancel conclusion. What
/// it pins: the straggler's record seals `cancelled` — never "done" — the sealed sender
/// record takes the timeout-counting tally through the one sanctioned post-seal write,
/// and the synthesized reply says how long the straggler was given.
@Test @MainActor func aWatchdogTimeoutSealsTheRecordsHonestly() throws {
    let host = SZHost()
    var machine = SZThreadMachine(bounds: .init(roundCeiling: 8,
                                                dispatchDeadline: .seconds(900),
                                                defaultRounds: 1))
    _ = machine.handle(.opened(kind: .build, graphRounds: 1, handlesSettled: true))

    // The director traversal concludes by dispatching two items; its record seals .ended.
    let build = UUID()
    host.beginAgentGraphRun(SZTraversalSighting(id: build, agent: "director",
                                                graphName: "recovery", kind: .build))
    let sent = machine.handle(.traversalConcluded(
        .ended, dispatch: .init(target: "coding", items: ["node-a", "node-b"], notes: [:])))
    host.concludeAgentGraphRun(build, .ended)
    var setID = -1
    for case .deliverItems(let id, _, _) in sent { setID = id }
    #expect(setID != -1)

    // Both items open records; "node-a" settles clean, "node-b" wedges silently.
    let itemA = UUID(), itemB = UUID()
    var records: [String: UUID] = ["node-a": itemA, "node-b": itemB]
    host.beginAgentGraphRun(SZTraversalSighting(id: itemA, agent: "coding", graphName: "item",
                                                kind: .item, item: "node-a"))
    host.beginAgentGraphRun(SZTraversalSighting(id: itemB, agent: "coding", graphName: "item",
                                                kind: .item, item: "node-b"))
    _ = machine.handle(.itemDelivered(node: "node-a", setID: setID))
    _ = machine.handle(.itemDelivered(node: "node-b", setID: setID))

    // The machine's motor, host-side: tallies amend the SENDER's record; a cancel order
    // lands as the cancelled item traversal's own conclusion (cancellation is cooperative —
    // the run's task unwinds and concludes .cancelled, the same hook every ending uses).
    var synthesized: SZSettledSummary?
    func execute(_ commands: [SZThreadMachine.Command]) {
        for command in commands {
            switch command {
            case .amendTally(_, let settled, let total, let failed):
                host.amendAgentGraphRunTally(build, settled: settled, total: total, failed: failed)
            case .cancelItems(_, let nodes):
                for node in nodes {
                    if let id = records.removeValue(forKey: node) {
                        host.concludeAgentGraphRun(id, .cancelled)
                    }
                }
            case .deliverSettled(let summary):
                synthesized = summary
            default:
                break
            }
        }
    }
    execute(machine.handle(.itemSettled(node: "node-a", setID: setID, outcome: "ok")))
    host.concludeAgentGraphRun(itemA, .ended)
    execute(machine.handle(.watchdogFired(setID: setID)))

    // Every record is sealed — nothing pulses "live" after the timeout.
    #expect(host.agentGraphRuns.allSatisfy { !$0.isLive })
    // The straggler's record is honest: cancelled, never a quiet "ended".
    let wedged = try #require(host.agentGraphRuns.first { $0.id == itemB })
    #expect(wedged.conclusion == .cancelled)
    let healthy = try #require(host.agentGraphRuns.first { $0.id == itemA })
    #expect(healthy.conclusion == .ended)
    // The sender's sealed record took the amended tally — the timed-out item counts FAILED.
    let sender = try #require(host.agentGraphRuns.first { $0.id == build })
    #expect(sender.conclusion == .ended)
    #expect(sender.tally == SZAgentGraphRun.Tally(settled: 2, total: 2, failed: 1))
    // And the synthesized reply says how long the straggler was given.
    #expect(synthesized?.outcomes["node-b"] == "timedOut: no terminal report within 900s")
    #expect(synthesized?.outcomes["node-a"] == "ok")

    // The drain sweep after the run task unwinds has nothing left to seal.
    host.sealLeakedAgentGraphRuns(thread: nil)
    #expect(host.agentGraphRuns.allSatisfy { !$0.isLive })
}
