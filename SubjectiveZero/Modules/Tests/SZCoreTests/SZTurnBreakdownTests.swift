// SPDX-License-Identifier: AGPL-3.0-only
// The per-turn debug breakdown: event Codable tolerance, the message field's transcript
// round-trip (old sidecars keep decoding), the store setter, and the run-rollup fold.
import Foundation
import Testing
@testable import SZCore

// MARK: - Codable

@Test func turnEventCodableRoundTrip() throws {
    let event = SZTurnEvent(stage: SZTurnStage.compileCheck, start: Date(timeIntervalSince1970: 100),
                            duration: 7.9, detail: "ok")
    let decoded = try JSONDecoder().decode(SZTurnEvent.self, from: JSONEncoder().encode(event))
    #expect(decoded == event)

    // An instant omits duration/detail on the wire rather than writing nulls.
    let instant = SZTurnEvent(stage: SZTurnStage.toolCall, start: Date(timeIntervalSince1970: 5))
    let json = String(decoding: try JSONEncoder().encode(instant), as: UTF8.self)
    #expect(!json.contains("duration"))
    #expect(!json.contains("detail"))
}

@Test func addedTokensRoundTripsAndRenders() throws {
    let event = SZTurnEvent(stage: SZTurnStage.mcpTool, start: Date(timeIntervalSince1970: 5),
                            duration: 0.4, detail: "agent_library_source", addedTokens: 1_150)
    let decoded = try JSONDecoder().decode(SZTurnEvent.self, from: JSONEncoder().encode(event))
    #expect(decoded.addedTokens == 1_150)
    // The row says what the action ADDED to the context, wherever it renders.
    #expect(SZTurnBreakdown.rowTitle(for: event, in: [event])
            == "→ agent_library_source · +1.1k tok")
    let prompt = SZTurnEvent(stage: SZTurnStage.promptSize, detail: "116 chars", addedTokens: 29)
    #expect(SZTurnBreakdown.rowTitle(for: prompt, in: [prompt]) == "prompt · 116 chars · +29 tok")
    // Absent stays absent — a bare event encodes no addedTokens key.
    let bare = SZTurnEvent(stage: SZTurnStage.toolCall)
    #expect(!String(decoding: try JSONEncoder().encode(bare), as: UTF8.self).contains("addedTokens"))
}

@Test func turnEventDecodeToleratesMissingFields() throws {
    // Only `stage` is required — a future build's slimmer event still decodes.
    let decoded = try JSONDecoder().decode(SZTurnEvent.self, from: Data(#"{"stage":"queue.wait"}"#.utf8))
    #expect(decoded.stage == SZTurnStage.queueWait)
    #expect(decoded.duration == nil)
    #expect(decoded.detail == nil)
    #expect(decoded.calls == nil)
}

@Test func callsRoundTripsAndStaysAbsent() throws {
    let report = SZTurnEvent(stage: SZTurnStage.providerReport, start: Date(timeIntervalSince1970: 9),
                             duration: 42, detail: "3 turns · api 8.2s", calls: 3)
    let decoded = try JSONDecoder().decode(SZTurnEvent.self, from: JSONEncoder().encode(report))
    #expect(decoded == report && decoded.calls == 3)
    // Absent stays absent — a call-less event encodes no calls key (old builds' transcripts too).
    let bare = SZTurnEvent(stage: SZTurnStage.providerReport, detail: "api 8.2s")
    #expect(!String(decoding: try JSONEncoder().encode(bare), as: UTF8.self).contains("calls"))
}

@Test func reportedCallsSumsProviderReportRowsOnly() {
    let events = [
        SZTurnEvent(stage: SZTurnStage.providerReport, calls: 3),
        SZTurnEvent(stage: SZTurnStage.providerReport, calls: 2),
        SZTurnEvent(stage: SZTurnStage.mcpTool, calls: 9),          // wrong stage — ignored
        SZTurnEvent(stage: SZTurnStage.providerReport),             // count-less report — absence
    ]
    #expect(SZTurnBreakdown.reportedCalls(in: events) == 5)
    // No report carries a count → nil, not zero (a CLI that doesn't count isn't "0 calls").
    #expect(SZTurnBreakdown.reportedCalls(in: [SZTurnEvent(stage: SZTurnStage.providerReport)]) == nil)
    #expect(SZTurnBreakdown.reportedCalls(in: []) == nil)
}

@Test func callsDetailDividesUsageAcrossCalls() {
    let turn = makeTurn(scope: "n", label: "N", startOffset: 0, duration: 30,
                        usage: SZTokenUsage(inputTokens: 604_400, outputTokens: 1_000),
                        events: [SZTurnEvent(stage: SZTurnStage.providerReport, calls: 3)])
    #expect(SZTurnBreakdown.callsDetail(of: [turn]) == "3 calls · ~201.5k ctx/call")
    // A single call reads singular; no usage → no ctx clause, the count still tells.
    let single = makeTurn(scope: "n", label: "N", startOffset: 0, duration: 5,
                          events: [SZTurnEvent(stage: SZTurnStage.providerReport, calls: 1)])
    #expect(SZTurnBreakdown.callsDetail(of: [single]) == "1 call")
    // No reported count anywhere → nil (nothing rendered, nothing invented).
    let uncounted = makeTurn(scope: "n", label: "N", startOffset: 0, duration: 5,
                             usage: SZTokenUsage(inputTokens: 100, outputTokens: 1))
    #expect(SZTurnBreakdown.callsDetail(of: [uncounted]) == nil)
}

@Test func chatMessageBreakdownRoundTripsAndOldTranscriptsDecode() throws {
    let message = SZChatMessage(role: .assistant, text: "done", duration: 12.5,
                                breakdown: [SZTurnEvent(stage: SZTurnStage.firstOutput, duration: 3.8)])
    let data = try JSONEncoder().encode(message)
    let decoded = try JSONDecoder().decode(SZChatMessage.self, from: data)
    #expect(decoded.breakdown?.count == 1)
    #expect(decoded.breakdown?.first?.stage == SZTurnStage.firstOutput)

    // A breakdown-less message (every pre-existing transcript) omits the key and decodes as nil.
    let bare = SZChatMessage(role: .assistant, text: "old")
    let bareJSON = String(decoding: try JSONEncoder().encode(bare), as: UTF8.self)
    #expect(!bareJSON.contains("breakdown"))
    let bareDecoded = try JSONDecoder().decode(SZChatMessage.self, from: Data(bareJSON.utf8))
    #expect(bareDecoded.breakdown == nil)
}

// MARK: - Finalize (turn-end post-processing, pure)

@Test func finalizeDedupesSortsDerivesAndPins() {
    let t0 = Date(timeIntervalSince1970: 0)
    let events = [
        // provider.report arrives first in raw order — must be pinned last.
        SZTurnEvent(stage: SZTurnStage.providerReport, start: t0, duration: 9.0, detail: "1 turn"),
        SZTurnEvent(stage: SZTurnStage.firstOutput, start: t0, duration: 0.5),
        // Streamed sighting superseded by the measured span of the same tool…
        SZTurnEvent(stage: SZTurnStage.toolCall, start: t0.addingTimeInterval(2), detail: "agent_compile_node"),
        SZTurnEvent(stage: SZTurnStage.mcpTool, start: t0.addingTimeInterval(2.1), duration: 3.0,
                    detail: "agent_compile_node"),
        // …while a CLI-local tool (no span) keeps its sighting.
        SZTurnEvent(stage: SZTurnStage.toolCall, start: t0.addingTimeInterval(1), detail: "Bash"),
        // Nested inside the mcp.tool span — must NOT be subtracted from the model residual again.
        SZTurnEvent(stage: SZTurnStage.compileCheck, start: t0.addingTimeInterval(2.2), duration: 2.0,
                    detail: "ok"),
    ]
    let rows = SZTurnBreakdown.finalize(events: events, started: t0, ended: t0.addingTimeInterval(10))

    #expect(rows.filter { $0.detail == "agent_compile_node" }.count == 1)          // dedupe kept the span
    #expect(rows.first { $0.detail == "agent_compile_node" }?.stage == SZTurnStage.mcpTool)
    #expect(rows.contains { $0.stage == SZTurnStage.toolCall && $0.detail == "Bash" })
    let model = rows.first { $0.stage == SZTurnStage.modelTime }
    #expect(model?.duration == 10 - 0.5 - 3.0)             // firstOutput + mcp.tool only, compile NOT double-counted
    #expect(rows.last?.stage == SZTurnStage.providerReport) // pinned last
    // Everything before the derived+pinned tail is chronological.
    let measured = rows.prefix(rows.count - 2).map(\.start)
    #expect(measured == measured.sorted())
}

@Test func finalizeEmptyAndResidualSuppression() {
    #expect(SZTurnBreakdown.finalize(events: [], started: Date(), ended: Date()).isEmpty)
    // A fully-measured turn (residual ≤ 0.05s) gets no model row.
    let t0 = Date(timeIntervalSince1970: 0)
    let rows = SZTurnBreakdown.finalize(
        events: [SZTurnEvent(stage: SZTurnStage.firstOutput, start: t0, duration: 1.0)],
        started: t0, ended: t0.addingTimeInterval(1.02))
    #expect(!rows.contains { $0.stage == SZTurnStage.modelTime })
}

// MARK: - Store setter

@MainActor
@Test func setChatBreakdownAttachesToTheTurnAndIgnoresEmpty() {
    let store = SZStore()
    let scope = SZChatScope.node(SZNodeID())
    let id = store.appendChatMessage(SZChatMessage(role: .assistant, text: "done"), to: scope)

    store.setChatBreakdown([], id, in: scope)   // absence stays absence
    #expect(store.messages(for: scope).first?.breakdown == nil)

    store.setChatBreakdown([SZTurnEvent(stage: SZTurnStage.queueWait, duration: 1.2)], id, in: scope)
    #expect(store.messages(for: scope).first?.breakdown?.first?.stage == SZTurnStage.queueWait)
}

// MARK: - Run rollup

private func makeTurn(scope: String, label: String, isDirector: Bool = false, startOffset: TimeInterval,
                      duration: TimeInterval, usage: SZTokenUsage? = nil,
                      events: [SZTurnEvent] = []) -> SZTurnBreakdown.RunTurn {
    SZTurnBreakdown.RunTurn(scopeKey: scope, label: label, isDirector: isDirector,
                            start: Date(timeIntervalSince1970: startOffset), duration: duration,
                            usage: usage, events: events)
}

@Test func aggregateFoldsASyntheticRun() {
    let base = Date(timeIntervalSince1970: 0)
    let turns = [
        makeTurn(scope: "director", label: "Director", isDirector: true, startOffset: 0, duration: 48.2,
                 usage: SZTokenUsage(inputTokens: 40_000, outputTokens: 2_000, costUSD: 0.30)),
        makeTurn(scope: "node-a", label: "Grayscale", startOffset: 50, duration: 118,
                 usage: SZTokenUsage(inputTokens: 48_000, outputTokens: 2_300,
                                     cachedInputTokens: 40_000, costUSD: 0.31),
                 events: [SZTurnEvent(stage: SZTurnStage.queueWait, duration: 1.2),
                          SZTurnEvent(stage: SZTurnStage.compileCheck, duration: 7.9),
                          SZTurnEvent(stage: SZTurnStage.promote, duration: 6.2)]),
        // Second turn on the same node (a reconcile re-dispatch) folds into one row.
        makeTurn(scope: "node-a", label: "Grayscale", startOffset: 200, duration: 30,
                 events: [SZTurnEvent(stage: SZTurnStage.compileCheck, duration: 3.1)]),
        makeTurn(scope: "director", label: "Director", isDirector: true, startOffset: 240, duration: 31.5),
    ]
    let rows = SZTurnBreakdown.aggregate(turns: turns, runStart: base, runEnd: base.addingTimeInterval(280))

    let node = rows.first { $0.stage == SZTurnStage.runNode }
    #expect(node?.duration == 148)                          // summed agent time, nested spans NOT added
    #expect(node?.detail?.contains("Grayscale") == true)
    #expect(node?.detail?.contains("2 turns") == true)
    #expect(node?.detail?.contains("compile 11s") == true)  // 7.9 + 3.1 across both turns
    #expect(node?.detail?.contains("promote 6.2s") == true)

    let director = rows.filter { $0.stage == SZTurnStage.runDirector }
    #expect(director.count == 2)                            // one row per director turn
    #expect(director[0].detail == "decompose")              // transcript order = round order
    #expect(director[0].duration == 48.2)
    #expect(director[1].detail == "reconcile 1")
    #expect(director[1].duration == 31.5)

    let queue = rows.first { $0.stage == SZTurnStage.queueWait }
    #expect(queue?.duration == 1.2)

    let total = rows.first { $0.stage == SZTurnStage.runTotal }
    #expect(total?.duration == 280)                         // wall clock, not sum of turns
    #expect(total?.detail?.contains("88.0k in") == true)
    #expect(total?.detail?.contains("$0.61") == true)
    #expect(total?.detail?.contains("45% cached") == true)  // 40k of 88k input
    // Rows follow the run's timeline: the director's decompose (t=0) leads, total is pinned last.
    #expect(rows.first?.stage == SZTurnStage.runDirector)
    #expect(rows.last?.stage == SZTurnStage.runTotal)
}

@Test func aggregateAppendsTheCallsBitWhenCLIsReportCounts() {
    let base = Date(timeIntervalSince1970: 0)
    let turns = [
        makeTurn(scope: "node-a", label: "Grayscale", startOffset: 10, duration: 60,
                 usage: SZTokenUsage(inputTokens: 400_000, outputTokens: 3_000),
                 events: [SZTurnEvent(stage: SZTurnStage.providerReport, calls: 3)]),
        makeTurn(scope: "node-a", label: "Grayscale", startOffset: 80, duration: 20,
                 usage: SZTokenUsage(inputTokens: 200_000, outputTokens: 1_000),
                 events: [SZTurnEvent(stage: SZTurnStage.providerReport, calls: 2)]),
        // A node whose CLI reports no count gets no calls bit — nothing invented.
        makeTurn(scope: "node-b", label: "Camera", startOffset: 10, duration: 30,
                 usage: SZTokenUsage(inputTokens: 100_000, outputTokens: 500)),
    ]
    let rows = SZTurnBreakdown.aggregate(turns: turns, runStart: base, runEnd: base.addingTimeInterval(120))
    let grayscale = rows.first { $0.stage == SZTurnStage.runNode && $0.detail?.hasPrefix("Grayscale") == true }
    #expect(grayscale?.detail?.contains("5 calls · ~120.0k ctx/call") == true)   // 600k over 5 calls
    let camera = rows.first { $0.stage == SZTurnStage.runNode && $0.detail?.hasPrefix("Camera") == true }
    #expect(camera?.detail?.contains("call") == false)
}

@Test func aggregateOfNothingIsEmpty() {
    #expect(SZTurnBreakdown.aggregate(turns: [], runStart: Date(), runEnd: Date()).isEmpty)
}

@Test func totalUsageAbsenceStaysAbsence() {
    let turns = [makeTurn(scope: "a", label: "A", startOffset: 0, duration: 5)]
    #expect(SZTurnBreakdown.totalUsage(of: turns) == nil)   // no turn reported → nil, not zeros
}

// MARK: - Run records + summary

private func runFixture() -> (chat: [String: [SZChatMessage]], runID: UUID) {
    let runID = UUID()
    let t0 = Date(timeIntervalSince1970: 1_000)
    let nodeKey = SZNodeID().uuidString
    let turnEvents = [
        SZTurnEvent(stage: SZTurnStage.firstOutput, start: t0.addingTimeInterval(18), duration: 0.2, runID: runID),
        SZTurnEvent(stage: SZTurnStage.mcpTool, start: t0.addingTimeInterval(40), duration: 2.5,
                    detail: "agent_compile_node", runID: runID),
        SZTurnEvent(stage: SZTurnStage.modelTime, start: t0.addingTimeInterval(18), duration: 30,
                    detail: "reasoning + streaming between tools", runID: runID),
    ]
    let rollup = [
        SZTurnEvent(stage: SZTurnStage.runDirector, start: t0, duration: 17, detail: "decompose", runID: runID),
        SZTurnEvent(stage: SZTurnStage.runNode, start: t0.addingTimeInterval(18), duration: 33,
                    detail: "Grayscale · 1 turn · compile 2.5s", runID: runID),
        SZTurnEvent(stage: SZTurnStage.runTotal, start: t0, duration: 51,
                    detail: "100.0k in / 2.0k out (90% cached)", runID: runID),
    ]
    let chat: [String: [SZChatMessage]] = [
        SZChatScope.directorKey: [
            SZChatMessage(role: .assistant, text: "decomposing", timestamp: t0, duration: 17,
                          breakdown: [SZTurnEvent(stage: SZTurnStage.firstOutput, start: t0,
                                                  duration: 0.3, runID: runID)]),
            SZChatMessage(role: .assistant, text: "Run complete — 1 node implemented.",
                          timestamp: t0.addingTimeInterval(51), breakdown: rollup),
        ],
        nodeKey: [SZChatMessage(role: .assistant, text: "done", timestamp: t0.addingTimeInterval(18),
                                duration: 33,
                                usage: SZTokenUsage(inputTokens: 100_000, outputTokens: 2_000),
                                breakdown: turnEvents)],
        // Noise that must not become a run: a chat turn with no run stamp.
        "debug": [SZChatMessage(role: .assistant, text: "hi", duration: 5,
                                breakdown: [SZTurnEvent(stage: SZTurnStage.firstOutput, duration: 0.7)])],
    ]
    return (chat, runID)
}

@Test func runRecordsReassembleARunFromTranscripts() {
    let (chat, runID) = runFixture()
    let records = SZTurnBreakdown.runRecords(chat: chat, titles: [:])
    #expect(records.count == 1)
    let record = records[0]
    #expect(record.id == runID)
    #expect(record.wallDuration == 51)
    #expect(record.turns.count == 2)                       // director turn + node turn, NOT the rollup
    #expect(record.turns[0].isDirector)                    // chronological
    #expect(record.turns[1].label.count == 8)              // no title map → uuid prefix label
    #expect(!record.turns.contains { $0.events.contains { $0.stage == SZTurnStage.runTotal } })
}

@Test func modelSegmentsAreTheComplementOfMeasuredSpans() {
    let t0 = Date(timeIntervalSince1970: 0)
    let turn = SZTurnBreakdown.RunTurn(
        scopeKey: "n", label: "N", isDirector: false, start: t0, duration: 30, usage: nil,
        events: [
            SZTurnEvent(stage: SZTurnStage.firstOutput, start: t0, duration: 1),
            SZTurnEvent(stage: SZTurnStage.mcpTool, start: t0.addingTimeInterval(10), duration: 2,
                        detail: "agent_compile_node"),
            // Nested inside the tool span — must not punch an extra hole.
            SZTurnEvent(stage: SZTurnStage.compileCheck, start: t0.addingTimeInterval(10.2), duration: 1),
        ])
    let segments = SZTurnBreakdown.modelSegments(of: turn)
    #expect(segments.count == 2)                                   // 1→10 and 12→30
    #expect(segments[0].start == t0.addingTimeInterval(1) && segments[0].duration == 9)
    #expect(segments[1].start == t0.addingTimeInterval(12) && segments[1].duration == 18)
    #expect(segments.allSatisfy { $0.stage == SZTurnStage.modelTime })
    // Sub-threshold gaps don't become noise rows.
    #expect(SZTurnBreakdown.modelSegments(of: turn, minimum: 20).count == 0)
}

@Test func chatTurnRecordsListRunlessTurnsOnly() {
    let (chat, _) = runFixture()
    let records = SZTurnBreakdown.chatTurnRecords(chat: chat, titles: [:])
    // Only the debug chat turn qualifies: run-stamped turns and the rollup narration are runs'.
    #expect(records.count == 1)
    #expect(records[0].rollup.isEmpty)
    #expect(records[0].turns.count == 1)
    #expect(records[0].turns[0].scopeKey == "debug")
    #expect(records[0].wallDuration == 5)
}

@Test func renderTokenReportListsPerTurnUsage() {
    let (chat, _) = runFixture()
    let record = SZTurnBreakdown.runRecords(chat: chat, titles: [:])[0]
    let report = SZTurnBreakdown.renderTokenReport(record)
    #expect(report.contains("100.0k in / 2.0k out (90% cached)"))       // header totals
    #expect(report.contains("100.0k in / 2.0k out"))                    // the node turn's line
    #expect(report.contains("(no usage reported)"))                     // the usage-less director turn
    #expect(report.contains("per-turn totals"))                         // the honesty note
}

@Test func tokenLineSpellsOutEveryReportedField() {
    let full = SZTokenUsage(inputTokens: 166_600, outputTokens: 1_200,
                            cachedInputTokens: 148_274, reasoningOutputTokens: 321, costUSD: 0.31)
    #expect(SZTurnBreakdown.tokenLine(full)
            == "166.6k in (89% cached) / 1.2k out (321 reasoning) · $0.31")
    // Absent fields stay absent — no zeros invented.
    let bare = SZTokenUsage(inputTokens: 500, outputTokens: 20)
    #expect(SZTurnBreakdown.tokenLine(bare) == "500 in / 20 out")
}

@Test func renderSummaryReadsAsTheRunReport() {
    let (chat, _) = runFixture()
    let record = SZTurnBreakdown.runRecords(chat: chat, titles: [:])[0]
    let summary = SZTurnBreakdown.renderSummary(record)
    #expect(summary.contains("wall 51s"))
    #expect(summary.contains("100.0k in / 2.0k out (90% cached)"))
    #expect(summary.contains("director  17s — decompose"))
    #expect(!summary.contains("director  17s — decompose  (starts"))   // run-opening row: no offset noise
    #expect(summary.contains("Grayscale  33s — 1 turn · compile 2.5s  (starts +18s)"))
    #expect(summary.contains("→ agent_compile_node  2.5s"))
    // The legacy explanatory detail is filtered — the row renders as the generic thinking label.
    #expect(summary.contains("(model thinking)  30s"))
}

// MARK: - Shared row titles + formatting

@Test func rowTitleComposesEverySurfaceShape() {
    let t0 = Date(timeIntervalSince1970: 0)
    let toolID = UUID(), promoteID = UUID(), reloadID = UUID()
    let events = [
        SZTurnEvent(stage: SZTurnStage.mcpTool, start: t0, duration: 2.8,
                    detail: "agent_compile_node", id: toolID),
        SZTurnEvent(stage: SZTurnStage.promote, start: t0.addingTimeInterval(1), duration: 1.1,
                    id: promoteID, parentID: toolID),
        SZTurnEvent(stage: SZTurnStage.promoteReload, start: t0.addingTimeInterval(1.2),
                    duration: 0.4, id: reloadID, parentID: promoteID),
        SZTurnEvent(stage: SZTurnStage.modelTime, start: t0, duration: 20, detail: "codex · high"),
        SZTurnEvent(stage: SZTurnStage.compileCheck, start: t0.addingTimeInterval(0.5),
                    duration: 1.7, detail: "ok", parentID: toolID),
    ]
    #expect(SZTurnBreakdown.rowTitle(for: events[0], in: events) == "→ agent_compile_node")
    // Depth derives from the parent chain when not passed…
    #expect(SZTurnBreakdown.rowTitle(for: events[1], in: events) == "└ promote")
    #expect(SZTurnBreakdown.rowTitle(for: events[2], in: events) == "  └ reload")
    // …and an explicit depth overrides it (chat's flat list).
    #expect(SZTurnBreakdown.rowTitle(for: events[2], in: events, depth: 0) == "reload")
    #expect(SZTurnBreakdown.rowTitle(for: events[4], in: events) == "└ compile · ok")
    // A named model with no local tool sightings reads as pure thinking…
    #expect(SZTurnBreakdown.rowTitle(for: events[3], in: events) == "(codex · high thinking)")
    // …while local sightings widen the residual's honesty label.
    let withLocal = events + [SZTurnEvent(stage: SZTurnStage.toolCall, start: t0, detail: "Bash")]
    #expect(SZTurnBreakdown.rowTitle(for: events[3], in: withLocal)
            == "(codex · high thinking + local tools)")

    // Run rollup shapes: run unindented, its children two-space indented.
    let rollup = [
        SZTurnEvent(stage: SZTurnStage.runTotal, start: t0, duration: 51),
        SZTurnEvent(stage: SZTurnStage.runDirector, start: t0, duration: 17, detail: "decompose"),
        SZTurnEvent(stage: SZTurnStage.runNode, start: t0, duration: 33,
                    detail: "Grayscale · 1 turn · compile 2.5s"),
    ]
    #expect(SZTurnBreakdown.rowTitle(for: rollup[0], in: rollup) == "run")
    #expect(SZTurnBreakdown.rowTitle(for: rollup[1], in: rollup) == "  director")
    #expect(SZTurnBreakdown.rowTitle(for: rollup[2], in: rollup) == "  Grayscale")
}

@Test func modelLabelFiltersTheLegacyPhrase() {
    let named = SZTurnEvent(stage: SZTurnStage.modelTime, detail: "gpt-5.6-terra · fast")
    #expect(SZTurnBreakdown.modelLabel(of: named) == "gpt-5.6-terra · fast")
    let legacy = SZTurnEvent(stage: SZTurnStage.modelTime,
                             detail: "reasoning + streaming between tools")
    #expect(SZTurnBreakdown.modelLabel(of: legacy) == nil)
    #expect(SZTurnBreakdown.modelLabel(of: SZTurnEvent(stage: SZTurnStage.modelTime)) == nil)
    // Only thinking rows have a model identity.
    #expect(SZTurnBreakdown.modelLabel(of: SZTurnEvent(stage: SZTurnStage.compileCheck,
                                                       detail: "ok")) == nil)
}

@Test func depthFollowsParentChainsAndSurvivesCyclesAndOrphans() {
    let a = UUID(), b = UUID(), c = UUID()
    let chain = [
        SZTurnEvent(stage: "a", id: a),
        SZTurnEvent(stage: "b", id: b, parentID: a),
        SZTurnEvent(stage: "c", id: c, parentID: b),
    ]
    #expect(SZTurnBreakdown.depth(of: chain[0], in: chain) == 0)
    #expect(SZTurnBreakdown.depth(of: chain[2], in: chain) == 2)
    // An orphan parent (its span was attribution-dropped) is top-level, not an error.
    let orphan = SZTurnEvent(stage: "x", parentID: UUID())
    #expect(SZTurnBreakdown.depth(of: orphan, in: chain) == 0)
    // A corrupt cycle terminates at the bound instead of hanging the render.
    let cycle = [SZTurnEvent(stage: "p", id: a, parentID: b),
                 SZTurnEvent(stage: "q", id: b, parentID: a)]
    #expect(SZTurnBreakdown.depth(of: cycle[0], in: cycle) == 8)
}

@Test func eventKeyPrefersFenceIDAndIsContentStableWithoutOne() {
    let id = UUID()
    let fenced = SZTurnEvent(stage: SZTurnStage.mcpTool, start: Date(timeIntervalSince1970: 5),
                             duration: 2, id: id)
    #expect(SZTurnBreakdown.eventKey(fenced) == id.uuidString)
    // Derived rows (model segments) have no id — same content, same key, every render.
    let derived = SZTurnEvent(stage: SZTurnStage.modelTime,
                              start: Date(timeIntervalSince1970: 5), duration: 2)
    #expect(SZTurnBreakdown.eventKey(derived)
            == SZTurnBreakdown.eventKey(SZTurnEvent(stage: SZTurnStage.modelTime,
                                                    start: Date(timeIntervalSince1970: 5),
                                                    duration: 2)))
    #expect(SZTurnBreakdown.eventKey(derived) != SZTurnBreakdown.eventKey(fenced))
}

@Test func formatTiersFollowMagnitude() {
    #expect(SZTurnBreakdown.format(0) == "0µs")
    #expect(SZTurnBreakdown.format(0.000218) == "218µs")
    #expect(SZTurnBreakdown.format(0.0021) == "2.1ms")
    #expect(SZTurnBreakdown.format(0.047) == "47ms")
    #expect(SZTurnBreakdown.format(7.9) == "7.9s")
    #expect(SZTurnBreakdown.format(31.4) == "31s")
    #expect(SZTurnBreakdown.format(132) == "2m 12s")
    // Tier boundaries round INTO the next unit, never printing "1000µs" or "60s".
    #expect(SZTurnBreakdown.format(0.0009996) == "1.0ms")
    #expect(SZTurnBreakdown.format(0.9996) == "1.0s")
    #expect(SZTurnBreakdown.format(59.6) == "1m 0s")
    // A negative duration is a measurement bug — rendered loud, not masked as zero.
    #expect(SZTurnBreakdown.format(-1.5) == "−1.5s")
}

@Test func formatTokensTiersIntoThousandsAndMillions() {
    #expect(SZTurnBreakdown.formatTokens(999) == "999")
    #expect(SZTurnBreakdown.formatTokens(48_000) == "48.0k")
    #expect(SZTurnBreakdown.formatTokens(999_949) == "999.9k")
    // The 999_950 boundary keeps "1000.0k" from ever rendering.
    #expect(SZTurnBreakdown.formatTokens(999_950) == "1.0M")
    #expect(SZTurnBreakdown.formatTokens(2_450_000) == "2.5M")
}

@Test func finalizeUnionResidualSurvivesOverlappingSpans() {
    // firstOutput [0,4] overlaps mcp.tool [2,5] — a sum would subtract 7 from a 6s turn and
    // silently drop the model row; the union subtracts 5 and keeps the honest 1s residual.
    let t0 = Date(timeIntervalSince1970: 0)
    let rows = SZTurnBreakdown.finalize(
        events: [
            SZTurnEvent(stage: SZTurnStage.firstOutput, start: t0, duration: 4),
            SZTurnEvent(stage: SZTurnStage.mcpTool, start: t0.addingTimeInterval(2), duration: 3,
                        detail: "ui_edit_ports"),
        ],
        started: t0, ended: t0.addingTimeInterval(6))
    let model = rows.first { $0.stage == SZTurnStage.modelTime }
    #expect(model != nil)
    if let duration = model?.duration {
        #expect(abs(duration - 1.0) < 0.0001)
    }
}

@Test func finalizePairsSightingsPerCallNotPerName() {
    // Two calls to the same tool, only ONE measured span (the other's attribution was dropped):
    // the paired sighting dies, the unpaired one survives as evidence of the second call.
    let t0 = Date(timeIntervalSince1970: 0)
    let rows = SZTurnBreakdown.finalize(
        events: [
            SZTurnEvent(stage: SZTurnStage.toolCall, start: t0.addingTimeInterval(1), detail: "agent_compile_node"),
            SZTurnEvent(stage: SZTurnStage.mcpTool, start: t0.addingTimeInterval(1.1), duration: 2,
                        detail: "agent_compile_node"),
            SZTurnEvent(stage: SZTurnStage.toolCall, start: t0.addingTimeInterval(30), detail: "agent_compile_node"),
        ],
        started: t0, ended: t0.addingTimeInterval(40))
    let compiles = rows.filter { $0.detail == "agent_compile_node" }
    #expect(compiles.count == 2)
    #expect(compiles.filter { $0.stage == SZTurnStage.toolCall }.count == 1)
    #expect(compiles.filter { $0.stage == SZTurnStage.mcpTool }.count == 1)
}

@Test func modelSegmentsSumMatchesTheStoredResidual() {
    // The derived segments and the finalize residual are two views of one quantity — they must
    // agree, or the timeline and the detail rows tell different stories.
    let t0 = Date(timeIntervalSince1970: 0)
    let events = [
        SZTurnEvent(stage: SZTurnStage.firstOutput, start: t0, duration: 1),
        SZTurnEvent(stage: SZTurnStage.mcpTool, start: t0.addingTimeInterval(10), duration: 2,
                    detail: "agent_compile_node"),
    ]
    let finalized = SZTurnBreakdown.finalize(events: events, started: t0,
                                             ended: t0.addingTimeInterval(30))
    let residual = finalized.first { $0.stage == SZTurnStage.modelTime }?.duration
    let turn = SZTurnBreakdown.RunTurn(scopeKey: "n", label: "N", isDirector: false,
                                       start: t0, duration: 30, usage: nil, events: events)
    let segmentSum = SZTurnBreakdown.modelSegments(of: turn).compactMap(\.duration).reduce(0, +)
    #expect(residual != nil)
    if let residual {
        #expect(abs(residual - segmentSum) < 0.0001)
    }
}
