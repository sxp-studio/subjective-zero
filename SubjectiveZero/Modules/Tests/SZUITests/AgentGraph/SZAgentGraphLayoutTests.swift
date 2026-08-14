// SPDX-License-Identifier: AGPL-3.0-only
// The Agent Graph panel's geometry and face derivation, pinned headlessly — the frames the
// canvas renders AND the follow-cam centres on, so a drift here moves both the picture and
// the camera that chases it. The face tests pin this era's one derivation: three node
// forms, no step-type library — icon/title/rows all come from the form + the node's title.
import CoreGraphics
import Foundation
import Testing
import SZCore
@testable import SZUI

private let graph = SZAgentGraph(
    name: "build",
    nodes: [
        SZAgentGraph.Node(id: "message", title: "On message", form: .message(.init())),
        SZAgentGraph.Node(id: "check", title: "Work left?", form: .step(name: "work-left")),
        SZAgentGraph.Node(id: "retry", form: .step(name: "retrying")),
        SZAgentGraph.Node(id: "implement", form: .turn(.init(brief: "prompts/implement.md.mustache"))),
        SZAgentGraph.Node(id: "send", form: .dispatch(.init(to: "coding", items: "workSet"))),
    ],
    edges: [
        SZAgentGraph.Edge(from: "message", outcome: "build", to: "check"),
        SZAgentGraph.Edge(from: "message", outcome: "settled", to: "retry"),
        SZAgentGraph.Edge(from: "check", outcome: "yes", to: "implement"),
        SZAgentGraph.Edge(from: "check", outcome: "no", to: "retry"),
        SZAgentGraph.Edge(from: "implement", outcome: "ok", to: "send"),
        SZAgentGraph.Edge(from: "implement", outcome: "error", to: "check", maxTraversals: 2),
    ])

private let stepFace = SZAgentGraphLayout.face(of: graph.node("check")!, in: graph)
private let turnFace = SZAgentGraphLayout.face(of: graph.node("implement")!, in: graph)
private let dispatchFace = SZAgentGraphLayout.face(of: graph.node("send")!, in: graph)

private func entry(_ ordinal: Int, _ node: String, phase: SZAgentGraphRun.Entry.Phase = .running,
                   outcome: String? = nil, started: TimeInterval? = nil) -> SZAgentGraphRun.Entry {
    SZAgentGraphRun.Entry(ordinal: ordinal, node: node, phase: phase, outcome: outcome,
                          startedAt: started.map(Date.init(timeIntervalSinceReferenceDate:)))
}

private func record(_ entries: [SZAgentGraphRun.Entry]) -> SZAgentGraphRun {
    SZAgentGraphRun(id: UUID(), agent: "director", graphName: "build", kind: .build,
                    startedAt: Date(timeIntervalSinceReferenceDate: 0),
                    trace: entries)
}

// MARK: - Faces (the era's derivation)

@Test func aStepFaceDrawsItsWiredOutcomesUnderItsOwnTitle() {
    #expect(stepFace.form == .step)
    #expect(stepFace.title == "Work left?")            // the node's title wins
    #expect(stepFace.outcomes == ["yes", "no"])        // wire order, deduped
    // Untitled → the step's folder name is the honest default.
    let retry = SZAgentGraphLayout.face(of: graph.node("retry")!, in: graph)
    #expect(retry.title == "retrying")
    // No out-edges wired → one quiet done row rather than zero rows.
    #expect(retry.outcomes == ["done"])
}

@Test func aTurnFaceCarriesTheFixedProcessRowsAndItsBriefName() {
    #expect(turnFace.form == .turn)
    #expect(turnFace.outcomes == ["ok", "error"])      // process truth, fixed order
    #expect(turnFace.title == "implement")             // prompts/implement.md.mustache → implement
}

@Test func aDispatchFaceSendsAndConcludes() {
    #expect(dispatchFace.form == .dispatch)
    #expect(dispatchFace.outcomes == ["sent"])
    #expect(dispatchFace.title == "→ coding")
}

@Test func aRunFaceGrowsTheOutcomeTheWiringNeverNamed() {
    // A step may END the traversal on an outcome with no edge — the fired port must exist.
    let face = SZAgentGraphLayout.runFace(
        for: entry(1, "check", phase: .done, outcome: "declined"), in: graph)
    #expect(face.outcomes == ["yes", "no", "declined"])
    // And a trace naming a node the graph no longer carries stays drawable.
    let orphan = SZAgentGraphLayout.runFace(for: entry(1, "gone", phase: .done), in: graph)
    #expect(orphan.title == "gone")
    #expect(!orphan.outcomes.isEmpty)
}

// MARK: - The Run view's chain

@Test func chainMarchesLeftToRightOnASharedSpine() {
    let run = record([entry(1, "check"), entry(2, "implement")])
    let frames = SZAgentGraphLayout.runFrames(for: run, graph: graph)
    #expect(frames.count == 2)
    // One column pitch apart, each centred on the y = 0 spine.
    #expect(frames[1].minX == frames[0].maxX + SZAgentGraphLayout.layerGap)
    for frame in frames { #expect(abs(frame.midY) < 1e-9) }
    // Sized by the plan's own sizing — same node, same silhouette in both modes.
    #expect(frames[0].size == SZAgentGraphLayout.size(of: stepFace))
}

@Test func revisitsAndDispatchTalliesGrowTheSubheaderRow() {
    // `check` visited twice → BOTH its entries carry the visit mark; the dispatch entry
    // carries ITS OWN tally (per visit, since a retry loop's second set is its own). The
    // frame must grow with the row or sockets land a line above it.
    var dispatchVisit = entry(2, "send")
    dispatchVisit.tally = .init(settled: 2, total: 4, failed: 0)
    let run = record([entry(1, "check"), dispatchVisit, entry(3, "check")])
    for e in run.trace {
        let face = SZAgentGraphLayout.runFace(for: e, in: graph)
        #expect(SZAgentGraphLayout.hasSubheader(e, in: run, face: face))
    }
    let frames = SZAgentGraphLayout.runFrames(for: run, graph: graph)
    #expect(frames[0].height == SZAgentGraphLayout.size(of: stepFace, subheader: true).height)
    #expect(frames[1].height
        == SZAgentGraphLayout.size(of: dispatchFace, subheader: true, stats: false).height)
}

@Test func aSingleVisitWithoutATallyKeepsThePlainHeader() {
    let run = record([entry(1, "implement")])
    let face = SZAgentGraphLayout.runFace(for: run.trace[0], in: graph)
    #expect(!SZAgentGraphLayout.hasSubheader(run.trace[0], in: run, face: face))
    let frames = SZAgentGraphLayout.runFrames(for: run, graph: graph)
    #expect(frames[0].size == SZAgentGraphLayout.size(of: turnFace))
}

@Test func aDispatchWithoutATallyYetKeepsThePlainHeader() {
    // The tally arrives with the set's first settle — until then the card has nothing to
    // say on the subheader line, and its frame must agree.
    let run = record([entry(1, "send")])
    let face = SZAgentGraphLayout.runFace(for: run.trace[0], in: graph)
    #expect(!SZAgentGraphLayout.hasSubheader(run.trace[0], in: run, face: face))
}

// MARK: - The stats footer

@Test func onlySpendingFormsCarryStats() {
    #expect(SZAgentGraphLayout.spends(.turn))
    #expect(SZAgentGraphLayout.spends(.dispatch))
    #expect(!SZAgentGraphLayout.spends(.step))
}

@Test func aStampedSpendingEntryGrowsTheFooterFromItsFirstFrame() {
    // Stamped the moment it is first reported — so the strip is there before the clock
    // ticks, and the card never grows under the pointer a second later.
    let run = record([entry(1, "implement", started: 100)])
    #expect(SZAgentGraphLayout.hasStats(run.trace[0], spends: true))
    let frames = SZAgentGraphLayout.runFrames(for: run, graph: graph)
    #expect(frames[0].height == SZAgentGraphLayout.size(of: turnFace, stats: true).height)
    #expect(frames[0].height
        == SZAgentGraphLayout.size(of: turnFace).height + SZAgentGraphLayout.statsFooterHeight)
}

@Test func aStampedStepStaysStatFree() {
    // Sub-millisecond noise on a card with nothing to report — no strip, no extra height.
    let run = record([entry(1, "check", phase: .done, outcome: "yes", started: 100)])
    #expect(!SZAgentGraphLayout.hasStats(run.trace[0], spends: false))
    let frames = SZAgentGraphLayout.runFrames(for: run, graph: graph)
    #expect(frames[0].size == SZAgentGraphLayout.size(of: stepFace))
}

@Test func subheaderAndFooterStackIndependently() {
    // A revisited turn that spends earns BOTH — and the ports must keep their rows, so the
    // footer's height lands under them rather than displacing them.
    let run = record([entry(1, "implement", started: 100), entry(3, "implement")])
    let face = SZAgentGraphLayout.runFace(for: run.trace[0], in: graph)
    #expect(SZAgentGraphLayout.hasSubheader(run.trace[0], in: run, face: face))
    #expect(SZAgentGraphLayout.hasStats(run.trace[0], spends: true))
    let frames = SZAgentGraphLayout.runFrames(for: run, graph: graph)
    #expect(frames[0].height
        == SZAgentGraphLayout.size(of: turnFace, subheader: true, stats: true).height)
    // The outcome rows sit where they always did: the footer is additive at the BOTTOM.
    #expect(SZAgentGraphLayout.outcomePoint(frames[0], outcome: "ok", in: turnFace, subheader: true)
        == SZAgentGraphLayout.outcomePoint(
            CGRect(origin: frames[0].origin,
                   size: SZAgentGraphLayout.size(of: turnFace, subheader: true)),
            outcome: "ok", in: turnFace, subheader: true))
}

// MARK: - Ports and the terminal stub

@Test func theTerminalLeavesByTheProducedPortOffTheSizedFrame() {
    #expect(SZAgentGraphLayout.terminalPort("error", in: turnFace) == "error")
    #expect(SZAgentGraphLayout.terminalPort(nil, in: turnFace) == "ok")
    #expect(SZAgentGraphLayout.terminalPort(nil, in: stepFace) == "yes")

    // The same `subheader` hazard the chain wires have: the stub must leave off the frame
    // the card was SIZED with.
    let run = record([entry(1, "implement", started: 100), entry(3, "implement")])
    let frame = SZAgentGraphLayout.runFrames(for: run, graph: graph)[0]
    let start = SZAgentGraphLayout.outcomePoint(
        frame, outcome: SZAgentGraphLayout.terminalPort("error", in: turnFace), in: turnFace,
        subheader: true)
    #expect(start.x == frame.maxX)
    #expect(start.y == SZAgentGraphLayout.rowCenterY(frame, row: 1, subheader: true))
    // Sized WITHOUT the subheader it actually has, the stub would leave a line too high.
    #expect(start.y != SZAgentGraphLayout.rowCenterY(frame, row: 1))
}

@Test func theInputPointIgnoresTheSubheader() {
    // The control-flow input rides the header's left edge BY DESIGN — the subheader sits
    // under the header, and the input is not one of the rows it pushes down.
    let plain = CGRect(origin: .zero, size: SZAgentGraphLayout.size(of: turnFace))
    let grown = CGRect(origin: .zero, size: SZAgentGraphLayout.size(of: turnFace, subheader: true,
                                                                    stats: true))
    #expect(SZAgentGraphLayout.inputPoint(plain) == SZAgentGraphLayout.inputPoint(grown))
    #expect(SZAgentGraphLayout.inputPoint(plain) == CGPoint(x: 0, y: SZNodeLayout.headerHeight / 2))
}

// MARK: - The plan's placement

@Test func thePlanRanksFromTheMessageNodeOverForwardEdgesOnly() {
    let placement = SZAgentGraphLayout.lay(out: graph)
    let x = { (id: String) in placement.frames[id]!.minX }
    // The door leads: every lane hangs off it, so nothing may sit left of the message node
    // — that is the whole reason the entry map became a card.
    #expect(x("message") < x("check"))
    #expect(x("message") < x("retry"))
    // check → implement → send march right; the bounded back edge never drags `check`
    // rightward, and the settled lane (`retry`) keeps its own honest rank.
    #expect(x("check") < x("implement"))
    #expect(x("implement") < x("send"))
    #expect(!placement.bounds.isNull)
}

@Test func theDoorDrawsOnePortPerRoutedKindInCauseOrder() {
    let face = SZAgentGraphLayout.face(of: graph.node("message")!, in: graph)
    #expect(face.form == .message)
    #expect(face.outcomes == ["build"])
    // Cause order across the deliverable kinds, not alphabet: work opens threads before
    // conversation, and the fleet's items follow the request lane they serve.
    let door = SZAgentGraph.Node(id: "m", form: .message(.init()))
    let wide = SZAgentGraph(name: "wide", nodes: [
        door,
        .init(id: "a", form: .turn(.init(brief: "prompts/a.md.mustache"))),
        .init(id: "b", form: .turn(.init(brief: "prompts/b.md.mustache"))),
        .init(id: "c", form: .turn(.init(brief: "prompts/c.md.mustache"))),
    ], edges: [
        .init(from: "m", outcome: "message", to: "a"),
        .init(from: "m", outcome: "work", to: "b"),
        .init(from: "m", outcome: "request", to: "c"),
    ])
    let wideFace = SZAgentGraphLayout.face(of: door, in: wide)
    #expect(wideFace.outcomes == ["message", "request", "work"])
    // The door costs nothing, so it never carries a wall-time strip.
    #expect(!SZAgentGraphLayout.spends(.message))
}

// MARK: - The projected future (the ghost wires)

@Test func anEdgeLeavingTheLiveNodeStartsAtItsRealPort() {
    let liveFrame = CGRect(x: 400, y: -60, width: SZAgentGraphLayout.cardWidth, height: 120)
    let edge = SZAgentGraph.Edge(from: "implement", outcome: "error", to: "check")
    let start = SZAgentGraphLayout.futureWireOrigin(
        edge: edge, liveNode: "implement", liveFrame: liveFrame, liveFace: turnFace,
        liveSubheader: true, projected: CGPoint(x: 0, y: 0),
        offset: CGSize(width: 400, height: 30))
    #expect(start == SZAgentGraphLayout.outcomePoint(liveFrame, outcome: "error", in: turnFace,
                                                     subheader: true))
}

@Test func aStatsCarryingLiveCardIsNotTheTranslatedPlanPoint() {
    // The regression this exists for: the footer grows the card by `statsFooterHeight`
    // around a spine at y = 0, so its top edge — which every row is measured from — sits
    // half a footer HIGHER than the translated plan frame's.
    let plan = CGRect(origin: .zero, size: SZAgentGraphLayout.size(of: turnFace))
    let live = CGRect(origin: CGPoint(x: 0, y: -SZAgentGraphLayout.size(of: turnFace, stats: true).height / 2),
                      size: SZAgentGraphLayout.size(of: turnFace, stats: true))
    let planPoint = SZAgentGraphLayout.outcomePoint(plan, outcome: "ok", in: turnFace)
    let offset = CGSize(width: live.midX - plan.midX, height: live.midY - plan.midY)
    let edge = SZAgentGraph.Edge(from: "implement", outcome: "ok", to: "check")
    let start = SZAgentGraphLayout.futureWireOrigin(
        edge: edge, liveNode: "implement", liveFrame: live, liveFace: turnFace,
        liveSubheader: false, projected: planPoint, offset: offset)
    let translated = CGPoint(x: planPoint.x + offset.width, y: planPoint.y + offset.height)
    #expect(start != translated)
    #expect(start.y == translated.y - SZAgentGraphLayout.statsFooterHeight / 2)
    #expect(SZAgentGraphLayout.statsFooterHeight / 2 == 8)
}

@Test func anEdgeBetweenTwoFutureNodesIsThePlanPointPlusTheOffset() {
    let edge = SZAgentGraph.Edge(from: "check", outcome: "yes", to: "implement")
    let start = SZAgentGraphLayout.futureWireOrigin(
        edge: edge, liveNode: "implement",
        liveFrame: CGRect(x: 0, y: -60, width: SZAgentGraphLayout.cardWidth, height: 120),
        liveFace: turnFace, liveSubheader: true,
        projected: CGPoint(x: 10, y: 20), offset: CGSize(width: 400, height: -5))
    #expect(start == CGPoint(x: 410, y: 15))
}

@Test func theProjectionFollowsForwardEdgesAndDropsTheLoop() {
    // Re-rooted over FORWARD edges only: the loop back is a possibility the bounded edge
    // already states, so it is dropped from the reachable set AND from the projection's
    // own edges.
    let future = SZAgentGraphLayout.projectedPlan(of: graph, from: "implement")
    // A forecast is a fragment PAST the door, so it carries no message node at all — it is
    // laid out from an explicit seed instead.
    #expect(future?.messageNode == nil)
    // `check` is only reachable back through the bounded edge — so neither it nor `retry`
    // behind it is drawn, and the forecast is the one stage that genuinely follows.
    #expect(future?.nodes.map(\.id) == ["implement", "send"])
    #expect(future?.edges.count == 1)
    #expect(future?.edges.first?.to == "send")
    // Nothing follows the last stage — no ghost at all; the terminal speaks instead.
    #expect(SZAgentGraphLayout.projectedPlan(of: graph, from: "send") == nil)
}

@Test func aDeclaredButUnwiredOutcomeDrawsAsADimmedPort() {
    // `check` declares yes/no; the fixture wires both — so first prove the fallback…
    let bare = SZAgentGraphLayout.face(of: graph.node("check")!, in: graph)
    #expect(bare.unwired.isEmpty)
    // …then the declaration path: a gate whose `no` ends the run must SHOW the no,
    // dimmed, instead of the port vanishing with its meaning.
    let gate = SZAgentGraph.Node(id: "gate", title: "Still unresolved?", form: .step(name: "work-left"))
    let lean = SZAgentGraph(name: "lean", nodes: [
        .init(id: "message", form: .message(.init())),
        gate,
        .init(id: "fix", form: .turn(.init(brief: "prompts/fix.md.mustache"))),
    ], edges: [
        .init(from: "message", outcome: "build", to: "gate"),
        .init(from: "gate", outcome: "yes", to: "fix"),
    ])
    let face = SZAgentGraphLayout.face(of: gate, in: lean,
                                       stepOutcomes: ["gate": ["yes", "no"]])
    #expect(face.outcomes == ["yes", "no"])   // wired first, then the edge-less answers
    #expect(face.unwired == ["no"])
    // The ask form dims the same way, from its own config — one rule, two forms.
    let ask = SZAgentGraph.Node(id: "rule", form: .ask(.init(
        prompt: "prompts/rule.md.mustache", outcomes: ["go", "hold"])))
    var wired = lean
    wired.nodes.append(ask)
    wired.edges.append(.init(from: "fix", outcome: "ok", to: "rule"))
    wired.edges.append(.init(from: "rule", outcome: "go", to: "gate"))
    let askFace = SZAgentGraphLayout.face(of: ask, in: wired)
    #expect(askFace.unwired == ["hold"])
    // And the PLACEMENT sizes with the same enriched face — a card that gained a dimmed
    // row must gain the row's height, or its sockets slide off the labels.
    let oneRow = SZAgentGraphLayout.lay(out: lean).frames["gate"]!
    let grown = SZAgentGraphLayout.lay(out: lean,
                                       stepOutcomes: ["gate": ["yes", "no"]]).frames["gate"]!
    #expect(grown.height == oneRow.height + SZNodeLayout.rowHeight)
    #expect(grown.height == SZAgentGraphLayout.size(of: face).height)
}
