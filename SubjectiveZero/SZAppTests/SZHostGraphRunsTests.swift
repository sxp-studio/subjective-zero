// SPDX-License-Identifier: AGPL-3.0-only
// The RUNS-record host seam, smoke-tested end to end without a project or an engine: the
// delivery's hooks (begin → note → conclude) land on `SZHost` and must leave the
// observable list the Agent Graph panel draws — ordered, sealed, tallies riding the trace
// notes — with the engine's note vocabulary mapped onto the record's own entry.
import Foundation
import Testing
import SZAI
import SZCore
@testable import SubjectiveZero

@Test @MainActor func graphRunHooksBuildOrderAndSealTheRecords() throws {
    let host = SZHost()
    let build = UUID(), item = UUID()

    // A build traversal begins, works, and dispatches; its thread is its own record id.
    host.beginAgentGraphRun(SZTraversalSighting(id: build, agent: "director"), thread: build)
    host.noteAgentGraphRun(build, SZTraversalNote(ordinal: 1, node: "work-left", phase: .running))
    host.noteAgentGraphRun(build, SZTraversalNote(ordinal: 1, node: "work-left", phase: .done,
                                                  outcome: "yes"))
    // An item traversal starts while the build record is still live — the build must keep
    // the head of the list (it is what the panel follows).
    host.beginAgentGraphRun(SZTraversalSighting(id: item, agent: "coding", work: "node-1"),
                            thread: build)
    #expect(host.agentGraphRuns.map(\.id) == [build, item])

    // The dispatch waits INSIDE the build traversal now, so the tally lands through the
    // ordinary note flow — on the dispatch visit's own entry, before the seal.
    host.noteAgentGraphRun(build, SZTraversalNote(ordinal: 2, node: "implement", phase: .done,
                                                  outcome: "settled",
                                                  tally: .init(settled: 1, total: 1, failed: 1)))
    host.concludeAgentGraphRun(build, .ended)
    host.noteAgentGraphRun(item, SZTraversalNote(ordinal: 1, node: "implement", phase: .failed,
                                                 detail: "the turn threw"))
    host.concludeAgentGraphRun(item, .failed(reason: "the turn threw"))

    let sealed = host.agentGraphRuns
    #expect(sealed.allSatisfy { !$0.isLive })
    let buildRecord = try #require(sealed.first { $0.id == build })
    #expect(buildRecord.conclusion == .ended)
    #expect(buildRecord.trace.last?.tally == SZAgentGraphRun.Tally(settled: 1, total: 1, failed: 1))
    #expect(buildRecord.trace.map(\.outcome) == ["yes", "settled"])   // notes replaced, not appended
    let itemRecord = try #require(sealed.first { $0.id == item })
    #expect(itemRecord.work == "node-1")
    #expect(itemRecord.conclusion == .failed(reason: "the turn threw"))
    #expect(itemRecord.trace.first?.detail == "the turn threw")

    // The drain sweep is a no-op once everything sealed itself (the healthy path).
    host.sealLeakedAgentGraphRuns(thread: nil)
    #expect(host.agentGraphRuns == sealed)
}

/// The wedged-fleet story at the host tier: one dispatched item never reports, the
/// watchdog fires, and the RECORDS must stay honest. The decisions come from the REAL
/// SZDispatchSupervisor (its command semantics are pinned in SZDispatchSupervisorTests);
/// this test is its motor over a bare SZHost, mapping each command onto the same hooks
/// the run wires: amendTally → the sender's tally note, and a cancelItems order landing
/// as the child's cooperative-cancel conclusion. What it pins: the straggler's record
/// seals `cancelled` — never "done" — the sender's entry takes the timeout-counting
/// tally before its seal, and the synthesized reply says how long the straggler was
/// given.
@Test @MainActor func aWatchdogTimeoutSealsTheRecordsHonestly() throws {
    let host = SZHost()
    var supervisor = SZDispatchSupervisor(bounds: .init(dispatchDeadline: .seconds(900)))

    // The build traversal reaches its dispatch, which mints the set and WAITS — its
    // record stays live for the whole fleet phase.
    let build = UUID()
    host.beginAgentGraphRun(SZTraversalSighting(id: build, agent: "director"), thread: build)
    host.noteAgentGraphRun(build, SZTraversalNote(ordinal: 1, node: "implement", phase: .running))
    let sent = supervisor.handle(.dispatched(
        .init(target: "coding", items: ["node-a", "node-b"], notes: [:])))
    var setID = -1
    for case .deliverItems(let id, _, _) in sent { setID = id }
    #expect(setID != -1)

    // Both items open records; "node-a" settles clean, "node-b" wedges silently.
    let itemA = UUID(), itemB = UUID()
    var records: [String: UUID] = ["node-a": itemA, "node-b": itemB]
    host.beginAgentGraphRun(SZTraversalSighting(id: itemA, agent: "coding", work: "node-a"),
                            thread: build)
    host.beginAgentGraphRun(SZTraversalSighting(id: itemB, agent: "coding", work: "node-b"),
                            thread: build)
    _ = supervisor.handle(.workDelivered(node: "node-a", setID: setID))
    _ = supervisor.handle(.workDelivered(node: "node-b", setID: setID))

    // The machine's motor, host-side: tallies amend the SENDER's record; a cancel order
    // lands as the cancelled item traversal's own conclusion (cancellation is cooperative —
    // the run's task unwinds and concludes .cancelled, the same hook every ending uses).
    var synthesized: SZSettledSummary?
    func execute(_ commands: [SZDispatchSupervisor.Command]) {
        for command in commands {
            switch command {
            case .amendTally(_, let settled, let total, let failed):
                // The progress lane: the tally rides a running-note on the LIVE dispatch
                // visit — the same flow the engine's deliver progress uses.
                host.noteAgentGraphRun(build, SZTraversalNote(
                    ordinal: 1, node: "implement", phase: .running,
                    tally: .init(settled: settled, total: total, failed: failed)))
            case .cancelItems(_, let nodes):
                for node in nodes {
                    if let id = records.removeValue(forKey: node) {
                        host.concludeAgentGraphRun(id, .cancelled)
                    }
                }
            case .settled(let summary):
                synthesized = summary
            default:
                break
            }
        }
    }
    execute(supervisor.handle(.workSettled(node: "node-a", setID: setID, outcome: "ok")))
    host.concludeAgentGraphRun(itemA, .ended)
    execute(supervisor.handle(.watchdogFired(setID: setID)))
    // The set closed: the waiting traversal walks on and seals — after its fleet, never
    // before it.
    host.noteAgentGraphRun(build, SZTraversalNote(ordinal: 1, node: "implement", phase: .done,
                                                  outcome: "settled"))
    host.concludeAgentGraphRun(build, .ended)

    // Every record is sealed — nothing pulses "live" after the timeout.
    #expect(host.agentGraphRuns.allSatisfy { !$0.isLive })
    // The straggler's record is honest: cancelled, never a quiet "ended".
    let wedged = try #require(host.agentGraphRuns.first { $0.id == itemB })
    #expect(wedged.conclusion == .cancelled)
    let healthy = try #require(host.agentGraphRuns.first { $0.id == itemA })
    #expect(healthy.conclusion == .ended)
    // The dispatch visit's entry took the live tally — the timed-out item counts FAILED —
    // and the done re-emit never erased it.
    let sender = try #require(host.agentGraphRuns.first { $0.id == build })
    #expect(sender.conclusion == .ended)
    #expect(sender.trace.first?.tally == SZAgentGraphRun.Tally(settled: 2, total: 2, failed: 1))
    // And the synthesized reply says how long the straggler was given.
    #expect(synthesized?.outcomes["node-b"] == "timedOut: no terminal report within 900s")
    #expect(synthesized?.outcomes["node-a"] == "ok")

    // The drain sweep after the run task unwinds has nothing left to seal.
    host.sealLeakedAgentGraphRuns(thread: nil)
    #expect(host.agentGraphRuns.allSatisfy { !$0.isLive })
}

/// A conversation never joins a build's thread, even when delivered while one runs — the
/// thread groups the build with its work children, and a chat that joined would paint its
/// own ending as the build's.
@Test @MainActor func aChatRecordStaysStandaloneEvenDuringARun() throws {
    let host = SZHost()
    let build = UUID(), chat = UUID(), item = UUID()

    host.beginAgentGraphRun(SZTraversalSighting(id: build, agent: "director"), thread: build)
    host.beginAgentGraphRun(SZTraversalSighting(id: item, agent: "coding", work: "n1"),
                            thread: build)
    host.beginAgentGraphRun(SZTraversalSighting(id: chat, agent: "coding"), thread: nil)

    func record(_ id: UUID) throws -> SZAgentGraphRun {
        try #require(host.agentGraphRuns.first { $0.id == id })
    }
    // The build LEADS its thread and its fleet shares it; the conversation stands alone.
    #expect(try record(build).leadsThread)
    #expect(try record(item).thread == build)
    #expect(!(try record(item).leadsThread))
    #expect(try record(chat).thread == nil)
}

/// Which agent answers which chat scope — a map over the SEAT vocabulary, so replacing the
/// folder that holds `coding` moves node chats with it. The one place that map can rot.
@Test func everyChatScopeResolvesToAnAgent() {
    let seats = SZSeatAssignment(director: "director", coding: "coding")
    #expect(SZHost.chatAgentID(for: .director, seats: seats) == "director")
    #expect(SZHost.chatAgentID(for: .node(SZNodeID()), seats: seats) == "coding")
    // Seatless: a scope's key IS its agent id.
    #expect(SZHost.chatAgentID(for: .debug, seats: seats) == "debug")
    // An unfilled seat resolves to nothing rather than guessing — the delivery then fails
    // with an honest line instead of opening some other agent's graph.
    #expect(SZHost.chatAgentID(for: .node(SZNodeID()),
                               seats: SZSeatAssignment(director: "director", coding: nil)) == nil)
}


/// The transcript's way into a run: the host stamps the live run's record id onto its own
/// narrations, so a build stays reachable from the conversation long after it scrolled away.
/// Exercised through the helper the run path calls rather than a whole run, which needs an engine.
@Test @MainActor func runNarrationsCarryTheRunsRecord() throws {
    let host = SZHost()
    let thread = UUID()

    // A line no run speaks for is never linked, so it stays a plain narration.
    let orphan = host.narrateDirector("Run not started — no agent packs.")
    #expect(host.store.messages(for: .director).first { $0.id == orphan }?.graphRunID == nil)

    // A run's own narration carries the record the Agent Graph panel draws. The thread is passed,
    // never looked up: with several runs live there is no "the" run to ask for.
    host.beginAgentGraphRun(SZTraversalSighting(id: thread, agent: "director"), thread: thread)
    let started = host.narrateDirector("Run started (claude) — implementing 2 nodes…")
    host.linkNarrationToRun(started, thread: thread)

    let stamped = try #require(host.store.messages(for: .director).first { $0.id == started })
    #expect(stamped.graphRunID == thread)
    // And it RESOLVES — a link to a record that was never opened would be a dead end.
    #expect(host.agentGraphRuns.contains { $0.id == stamped.graphRunID })
}

@Test @MainActor func aRunsLinesWearTheBuildsNameAndStep() throws {
    // The name and step are written onto the message, so a header still reads after the run
    // record has been capped away.
    let host = SZHost()
    let thread = UUID()
    host.beginAgentGraphRun(SZTraversalSighting(id: thread, agent: "director"), thread: thread,
                            title: "Make a slowly rotating grayscale checkerboard")
    host.noteAgentGraphRun(thread, SZTraversalNote(ordinal: 1, node: "door", phase: .done, outcome: "build"))
    host.noteAgentGraphRun(thread, SZTraversalNote(ordinal: 2, node: "decompose", phase: .running))
    #expect(host.buildName(thread: thread) == "Slowly rotating grayscale checkerboard")
    #expect(host.buildStep(thread: thread) == "Decompose")
    #expect(host.buildStep(thread: UUID()) == nil)

    let line = host.narrateDirector("⚠️ a note")
    host.linkNarrationToRun(line, thread: thread)
    let stamped = try #require(host.store.messages(for: .director).first { $0.id == line })
    #expect(stamped.buildName == "Slowly rotating grayscale checkerboard")
    #expect(stamped.buildStep == nil)
}

/// The panel's landing ask is host-owned and consumed once, exactly like the Profiler's.
@Test @MainActor func revealInAgentGraphRecordsTheAsk() {
    let host = SZHost()
    let target = UUID()
    #expect(host.agentGraphFocusRequest == nil)
    host.revealInAgentGraph(target)
    #expect(host.agentGraphFocusRequest == target)
}

@Test @MainActor func theLeaderRecordCarriesTheAskAndItsChildrenDoNot() throws {
    // The chat names a build by what was asked: the title rides the thread's leader record
    // (persisted with it), never a dispatched child's, which is named by its node.
    let host = SZHost()
    let build = UUID(), item = UUID()
    host.beginAgentGraphRun(SZTraversalSighting(id: build, agent: "director"), thread: build,
                            title: "Make a grayscale version of my camera")
    host.beginAgentGraphRun(SZTraversalSighting(id: item, agent: "coding", work: "node-1"),
                            thread: build)
    let leader = try #require(host.agentGraphRuns.first { $0.id == build })
    #expect(leader.title == "Make a grayscale version of my camera")
    let child = try #require(host.agentGraphRuns.first { $0.id == item })
    #expect(child.title == nil)
}

@Test @MainActor func aStepTitleResolvesThroughTheAgentLibrary() {
    // The strip's muted word and the transcript header read the step's declared title, not the
    // trace's node id; an id the library does not carry resolves to nothing, so callers fall
    // back to the id.
    let host = SZHost()
    #expect(host.agentGraphStepTitle(agent: "director", node: "decompose") == "Decompose")
    #expect(host.agentGraphStepTitle(agent: "director", node: "no-such-step") == nil)
    #expect(host.agentGraphStepTitle(agent: "no-such-agent", node: "decompose") == nil)
}
