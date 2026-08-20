// SPDX-License-Identifier: AGPL-3.0-only
// The Agent Graph panel: the orchestration, drawn. Read-only — pan and zoom, no editing.
//
// Two views of one vocabulary. PLAN is the authored graph as a static document. RUN is an
// accumulating list applied to executions: every recorded RUN down the left, the selected
// one's canvas beside it — and each run draws ITS OWN graph, so an item traversal renders
// its agent's item graph rather than whatever the Director happens to have selected.
//
// SZUI may not import SZAI, which is exactly why `SZAgentGraph` and `SZAgentGraphRun` live
// in SZCore: the host hands this view values, not an engine. The graph a record resolves to
// arrives through a closure for the same reason — the pack library sits on the other side
// of that line, and a record it no longer carries degrades to an honest empty canvas.
//
// Composed from the canvas pieces that are already model-free rather than reaching for
// `SZNodeEditorPanel` — that view owns marquee, wire-drag, docking and hit-testing this
// panel has no use for. What it borrows: `SZCanvasCamera` (the same zoom range and pivot
// maths), `SZDotGridView` (the same ground), `monitorCanvasScrollWheel` (the same pan/zoom
// feel), and `SZCubic` for wire geometry — so the two canvases read as one app.
//
// THIS file keeps the panel itself: what is shown, the sidebar tree, and the camera
// (framing and follow-cam). Its two halves live beside it — `SZAgentGraphRunList` (the RUNS
// column and the selection rule) and `SZAgentGraphCanvasContent` (world space) — and the
// geometry both read is `SZAgentGraphLayout`.
import SwiftUI
import SZCore

/// One agent in the Plan view's tree: who it is and THE graph it carries. Built by the
/// host — the agent-pack library lives in SZAI, which this module may not import — and
/// drawn here, the pattern every prop on this panel follows.
public struct SZAgentGraphPlanAgent: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var symbol: String
    public var graph: SZAgentGraph
    /// Declared outcomes per STEP node id, from the compiled steps' own exports —
    /// resolved host-side (SZUI may not reach the compiler) and filled in asynchronously
    /// as declarations warm. Empty until then: a card falls back to its wired ports.
    public var stepOutcomes: [String: [String]]
    /// The seat this agent holds — what a dispatch's `to` resolves against. nil = seatless.
    public var seat: String?

    public init(id: String, title: String, symbol: String, graph: SZAgentGraph,
                stepOutcomes: [String: [String]] = [:], seat: String? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.graph = graph
        self.stepOutcomes = stepOutcomes
        self.seat = seat
    }
}

public struct SZAgentGraphPanel: View {
    /// Every agent and its graphs — the Plan view browses all of them, director first.
    private let planAgents: [SZAgentGraphPlanAgent]
    /// The recorded runs, live first then newest — the host keeps the order, this draws it.
    private let runs: [SZAgentGraphRun]
    /// Open a card's authored source in the user's editor, agent-qualified — the host
    /// resolves the materialized file. nil = the affordance is absent (tests, previews).
    private let openStepSource: ((String, SZAgentGraphFace.Source) -> Void)?
    /// A record's OWN graph. nil = the pack library no longer carries it (an archive from a
    /// build whose agents have since changed) — the canvas says so and stops.
    private let resolveGraph: (SZAgentGraphRun) -> SZAgentGraph?
    /// A work node's display title, resolved against the live project — the sub-agent
    /// lanes name the node, not its id. nil = the node is gone; the lane falls back.
    private let nodeTitle: (String) -> String?
    /// A run the transcript asked to reveal (host-owned, consumed once shown).
    private let focusRequest: UUID?
    private let onConsumeFocus: () -> Void
    /// An agent whose PLAN the settings sheet asked to reveal (the Routing pane's View
    /// Graph) — same consume handshake as the run focus above, but by agent id.
    private let planFocusRequest: String?
    private let onConsumePlanFocus: () -> Void

    @State private var mode: SZAgentGraphPanelMode = .plan
    /// The run the user PICKED, if any. nil = follow the head of the list, which is how the
    /// panel tracks the latest run without fighting an explicit choice.
    @State private var selectedRunID: UUID?
    /// The Plan view's browse position. nil = the first agent; an id the library dropped
    /// falls back the same way.
    @State private var selectedAgentID: String?

    /// The Run view's follow-cam: while armed, the camera re-centres on the newest entry —
    /// the traversing head — each time the chain grows. A manual pan disengages it (the
    /// user took the camera; don't fight them); a new traversal starting re-arms it, the
    /// same moment the panel switches itself back to Run. Zoom deliberately does NOT
    /// disengage: the follow re-centres the head on the next growth either way, so a zoom
    /// (pinch about the view centre, ⌘-scroll about the pointer) just picks the scale the
    /// follow then honours.
    @State private var following = true

    @State private var camera = SZCanvasCamera(zoom: 1, offset: CGSize(width: 60, height: 0))
    @State private var pinchAnchor: SZCanvasCamera?
    @State private var viewSize: CGSize = .zero
    @State private var centred = false
    /// Per-node nudges, in world points. Session-only and deliberately NOT persisted: the
    /// layout is computed, and these exist so a graph can be pulled apart to read it, not
    /// to author a picture. Reset by switching graph.
    @State private var nudges: [String: CGSize] = [:]
    /// The two SECTIONS collapse too: AGENTS starts folded (the plans are reference
    /// material), RUNS starts open (the live surface).
    @State private var agentsSectionOpen = false
    @State private var runsSectionOpen = true

    private static let space = "szagentgraph"

    public init(planAgents: [SZAgentGraphPlanAgent],
                runs: [SZAgentGraphRun] = [],
                resolveGraph: @escaping (SZAgentGraphRun) -> SZAgentGraph? = { _ in nil },
                nodeTitle: @escaping (String) -> String? = { _ in nil },
                openStepSource: ((String, SZAgentGraphFace.Source) -> Void)? = nil,
                focusRequest: UUID? = nil, onConsumeFocus: @escaping () -> Void = {},
                planFocusRequest: String? = nil,
                onConsumePlanFocus: @escaping () -> Void = {}) {
        self.planAgents = planAgents
        self.runs = runs
        self.resolveGraph = resolveGraph
        self.nodeTitle = nodeTitle
        self.openStepSource = openStepSource
        self.focusRequest = focusRequest
        self.onConsumeFocus = onConsumeFocus
        self.planFocusRequest = planFocusRequest
        self.onConsumePlanFocus = onConsumePlanFocus
    }

    /// No runs, nothing to list — force Plan rather than a Run view with no canvas.
    private var effectiveMode: SZAgentGraphPanelMode { runs.isEmpty ? .plan : mode }

    /// The run the canvas is drawing: the explicit pick while it still exists, else the
    /// head of the list (the live run, else the newest).
    private var shown: SZAgentGraphRun? { SZAgentGraphRunSelection.select(runs, id: selectedRunID) }

    /// The agent the Plan view is browsing, and which of its graphs — an unrecognised
    /// selection (a library that changed under a stale pick) falls back rather than
    /// emptying the canvas.
    private var planAgent: SZAgentGraphPlanAgent? {
        planAgents.first { $0.id == selectedAgentID } ?? planAgents.first
    }

    /// What the canvas draws right now — the run's own graph and record, or the browsed
    /// plan graph with no record at all. nil = nothing resolvable, and `empty` says which
    /// kind of nothing.
    private var displayed: Displayed? {
        if effectiveMode == .run {
            guard let shown, let graph = resolveGraph(shown) else { return nil }
            // The record's agent joins back to the plan entry for the declared outcomes
            // the record itself never carries.
            let outcomes = planAgents.first { $0.id == shown.agent }?.stepOutcomes ?? [:]
            return Displayed(key: shown.id.uuidString, graph: graph, record: shown,
                             agent: shown.agent, stepOutcomes: outcomes)
        }
        guard let planAgent else { return nil }
        return Displayed(key: planAgent.id, graph: planAgent.graph,
                         record: nil, agent: planAgent.id,
                         stepOutcomes: planAgent.stepOutcomes)
    }

    /// The work children a shown record dispatched: the records sharing its thread. They
    /// are already in `runs`, so showing the fleet on the canvas is a filter — the same one
    /// the transcript's run strip applies.
    private func subagents(of record: SZAgentGraphRun?) -> [SZAgentGraphRun] {
        guard let record, record.work == nil else { return [] }
        return SZAgentGraphRun.workChildren(thread: record.thread, in: runs)
    }

    /// A dispatch card's link: jump the Plan view to the target seat's graph — the one the
    /// dispatched work traverses. Unknown seat = no-op.
    private func navigate(toSeat seat: String) {
        guard let target = planAgents.first(where: { $0.seat == seat }) else { return }
        mode = .plan
        selectedRunID = nil
        selectedAgentID = target.id
        // Show the destination in the outline too: a canvas that swaps under a collapsed
        // AGENTS section leaves the user somewhere with no visible "here".
        agentsSectionOpen = true
    }

    /// One canvas's worth of values. The Plan view carries no record — its cards are the
    /// authored document, deliberately state-free.
    private struct Displayed {
        /// What "a different canvas" means for the per-canvas state (nudges, framing): a
        /// different RUN, or a different agent's graph — graph NAMES repeat across agents,
        /// so the agent belongs in the key.
        var key: String
        var graph: SZAgentGraph
        var record: SZAgentGraphRun?
        /// Whose pack the drawn graph belongs to — what the source affordance opens under.
        var agent: String
        /// The compiled steps' declared outcomes, for the cards' unwired ports.
        var stepOutcomes: [String: [String]] = [:]
    }

    public var body: some View {
        // ONE permanent sidebar, one outline — and the outline IS the mode: picking a graph
        // shows its plan, picking a traversal shows that run. No Plan/Run toggle to place,
        // no chips floating over the canvas — the tree carries the whole selection surface.
        // The sidebar's permanence is also structural: one stable canvas identity means the
        // `.onAppear` land-on-runs default runs once, when the panel appears.
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader("AGENTS", open: $agentsSectionOpen)
                    if agentsSectionOpen { agentTree }
                    if !runs.isEmpty {
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                            .padding(.horizontal, 8).padding(.top, 8)
                        sectionHeader("RUNS", open: $runsSectionOpen)
                        if runsSectionOpen {
                            SZAgentGraphRunList(runs: runs,
                                                names: SZAgentGraphNaming(agents: planAgents),
                                                shownID: effectiveMode == .run ? shown?.id : nil) { run in
                                selectedRunID = run.id
                                mode = .run           // picking a traversal shows it
                                // An archived run is a still picture — only a live one is
                                // worth chasing.
                                following = run.isLive
                            }
                        }
                    }
                }
                // The chrome's header floats OVER the tile; the sidebar starts below it
                // so the AGENTS section is never hidden underneath.
                .padding(.top, SZPanelChromeView<EmptyView>.headerHeight + 4)
                .padding(.bottom, 8)
            }
            .frame(width: 200)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            canvas
        }
        // A NEW live run is the moment the Run view becomes the interesting one: switch to
        // it and re-arm the follow. TWO things it deliberately does not do: it never
        // interrupts a record that is itself LIVE (an item starting mid-build must not yank
        // the canvas), and it never clears an explicit pick — a picked run is released only
        // by ageing out of the list, which the selection rule already falls back from.
        .onChange(of: runs.first?.id) { old, _ in
            guard runs.first?.isLive == true else { return }
            let showing = selectedRunID.flatMap { id in runs.first { $0.id == id } }
                ?? runs.first { $0.id == old }
            guard showing?.isLive != true else { return }
            mode = .run
            following = true
        }
        // On the common container, so a request landing before any record exists is still
        // consumed (and honored the moment the run is recorded) instead of going stale.
        .onAppear { consumeFocusRequest(); consumePlanFocusRequest() }
        .onChange(of: focusRequest) { consumeFocusRequest() }
        .onChange(of: planFocusRequest) { consumePlanFocusRequest() }
    }

    /// The transcript's "open in the Agent Graph" landing — the sidebar's own pick, asked for
    /// from outside: show the run, and chase it only while it is still live.
    private func consumeFocusRequest() {
        guard let focusRequest else { return }
        selectedRunID = focusRequest
        mode = .run
        following = runs.first { $0.id == focusRequest }?.isLive ?? false
        onConsumeFocus()
    }

    /// The Routing pane's "View Graph" landing — `navigate(toSeat:)`'s move, asked for from
    /// outside and addressed by agent id.
    private func consumePlanFocusRequest() {
        guard let planFocusRequest else { return }
        mode = .plan
        selectedRunID = nil
        selectedAgentID = planFocusRequest
        agentsSectionOpen = true
        onConsumePlanFocus()
    }

    private var canvas: some View {
        GeometryReader { proxy in
            ZStack {
                SZDotGridView.canvasBackground
                SZDotGridView(zoom: camera.zoom, offset: camera.offset).allowsHitTesting(false)

                if let displayed {
                    content(displayed)
                        .scaleEffect(camera.zoom, anchor: .topLeading)
                        .offset(camera.offset)
                } else {
                    empty
                }

                // (The "this graph only runs when dispatched to" note lived here while a
                // graph handled exactly one kind. A document now routes several, so the
                // statement belongs to a PORT, not a canvas — the message card's ports say
                // which kinds arrive, and the RUNS list shows where each one's traces land.)
            }
            // The world is unbounded and the camera pans it anywhere: without this the
            // chain draws straight over the sidebar sitting beside it (the canvas is the
            // HStack's later sibling, so it paints on top).
            .clipped()
            .coordinateSpace(name: Self.space)
            .contentShape(Rectangle())
            // Only scrolls that land ON this canvas arrive here — the catcher's frame is this
            // space, so the ones panning the node editor next door never reach it.
            .monitorCanvasScrollWheel { scroll in
                if scroll.commandHeld {
                    let target = camera.zoom * (1 + scroll.deltaY * 0.01)
                    camera.applyZoom(target, pivot: scroll.location, from: camera)
                } else {
                    following = false
                    camera.pan(by: CGSize(width: scroll.deltaX, height: scroll.deltaY))
                }
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let anchor = pinchAnchor ?? camera
                        if pinchAnchor == nil { pinchAnchor = camera }
                        camera.applyZoom(anchor.zoom * value.magnification,
                                         pivot: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2),
                                         from: anchor)
                    }
                    .onEnded { _ in pinchAnchor = nil })
            .onAppear {
                viewSize = proxy.size; centreIfNeeded()
                // A panel recreated mid-traversal (the user visited another leaf and came
                // back) must land on the runs, not the default Plan — on the live head.
                // Unless a plan focus is pending: View Graph may have just SHOWN the panel,
                // and this onAppear must not race the consume back into Run.
                if planFocusRequest == nil, !runs.isEmpty { mode = .run; followActiveEntry() }
            }
            .onChange(of: proxy.size) { _, new in viewSize = new; centreIfNeeded() }
            // A different run, or a different plan graph, is a different canvas: drop the
            // nudges with it, and re-frame rather than leaving the camera parked over where
            // the old one happened to be.
            .onChange(of: displayed?.key) { _, _ in
                nudges = [:]
                centred = false; centreIfNeeded()
                followActiveEntry()
            }
            // The shown record GROWING is the traversal moving — chase its head. Keyed on
            // COUNT rather than a flag: a record swapped under the selection can land at
            // the same count, and shrinkage means a different chain entirely.
            .onChange(of: displayed?.record?.trace.count) { old, new in
                if let new, new > 0, old == 0 || new < (old ?? 0) { following = true }
                followActiveEntry()
            }
            // A chain that regrows to the SAME count in one observation slips past the
            // count check above — the head entry is the tiebreaker.
            .onChange(of: displayed?.record?.trace.first) { old, new in
                if let new, new.phase == .running, old != new {
                    following = true
                    followActiveEntry()
                }
            }
            // Flipping back to Run rejoins the traversal at its head — IF the follow is
            // still armed; a pan-disengaged camera stays wherever the user parked it.
            .onChange(of: mode) { _, _ in followActiveEntry() }
        }
    }

    /// World space — the mode split and both renderers live in the content view.
    private func content(_ displayed: Displayed) -> some View {
        SZAgentGraphCanvasContent(graph: displayed.graph,
                                  stepOutcomes: displayed.stepOutcomes,
                                  // A file pill is drawn only when a host can actually open
                                  // it; dispatch LINKS are the panel's own business, so they
                                  // stand whether or not one is wired.
                                  openSource: { [self] source in
                                      if case .dispatch(let target) = source {
                                          navigate(toSeat: target)
                                      } else {
                                          openStepSource?(displayed.agent, source)
                                      }
                                  },
                                  drawsFileSources: openStepSource != nil,
                                  record: displayed.record,
                                  items: subagents(of: displayed.record),
                                  nodeTitle: nodeTitle,
                                  // A lane is a door into its own record — the same pick
                                  // rule the RUNS rows use.
                                  onPickItem: { run in
                                      selectedRunID = run.id
                                      mode = .run
                                      following = run.isLive
                                  },
                                  mode: effectiveMode,
                                  zoom: camera.zoom, nudges: nudges,
                                  onNudge: { id, delta in nudges[id, default: .zero] = delta })
    }

    /// Two honest nothings: a plan selection that resolves to no library, and an archived
    /// run whose graph the library has since dropped. Neither is an error — the row still
    /// says which agent traversed what, it just can't be drawn.
    private var empty: some View {
        VStack(spacing: 6) {
            if effectiveMode == .run, let shown {
                Text("Graph unavailable").font(.system(size: 13, weight: .semibold))
                Text("\(shown.agent)'s graph isn't in the agent-pack library any more.")
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
            } else {
                Text("No agent graph").font(.system(size: 13, weight: .semibold))
                Text("No agent-pack library is loaded to browse.")
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: 320)
    }

    /// A collapsible section label — the sidebar's top tier of the one folding gesture.
    private func sectionHeader(_ title: String, open: Binding<Bool>) -> some View {
        Button { open.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The AGENTS outline: one row per agent — each IS its graph, so the row selects the
    /// plan directly.
    private var agentTree: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(planAgents) { agent in
                let selected = effectiveMode == .plan && agent.id == planAgent?.id
                Button {
                    selectedAgentID = agent.id
                    mode = .plan
                } label: {
                    HStack(spacing: 5) {
                        Capsule()
                            .fill(selected ? SZChatPanel.directorColor.opacity(0.8) : .clear)
                            .frame(width: 2)
                        Image(systemName: agent.symbol)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(agent.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 18).padding(.trailing, 10).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(selected ? 0.06 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(agent.graph.label.map { "\(agent.title) · \($0)" } ?? agent.title)
            }
        }
    }

    private func centreIfNeeded() {
        guard !centred, viewSize.height > 0, let displayed else { return }
        let bounds = SZAgentGraphLayout.lay(out: displayed.graph,
                                            stepOutcomes: displayed.stepOutcomes).bounds
        guard !bounds.isNull else { return }
        // 130, not a slimmer margin: the Run view hangs its `start` capsule ~90pt LEFT of
        // the entry card, and the initial framing must include it rather than clip it.
        camera = SZCanvasCamera(zoom: 1,
                                offset: CGSize(width: 130 - bounds.minX,
                                               height: viewSize.height / 2 - bounds.midY))
        centred = true
    }

    /// Centre the camera on the chain's newest entry at the current zoom — the follow-cam's
    /// one move. Reads the SAME `runFrames` the canvas renders from, so "centred" means the
    /// card, not an estimate of it. No-ops unless the follow is armed, the Run view is what
    /// is actually showing (a user reading the Plan mid-traversal must not have the camera
    /// yanked), and the shown run is LIVE — an archive has no head to chase.
    private func followActiveEntry() {
        guard following, effectiveMode == .run, shown?.isLive == true, viewSize.height > 0,
              let displayed, let record = displayed.record,
              let frame = SZAgentGraphLayout.runFrames(for: record, graph: displayed.graph,
                                                       stepOutcomes: displayed.stepOutcomes).last
        else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            camera.offset = CGSize(width: viewSize.width / 2 - camera.zoom * frame.midX,
                                   height: viewSize.height / 2 - camera.zoom * frame.midY)
        }
    }
}

/// PLAN is the authored graph as a static document — loops as back edges, each node once,
/// no live state, so it can be read the way its file is read. RUN is the executed trace —
/// the same traversal UNROLLED, one card per entry, so a node visited twice is two cards
/// with two outcomes instead of the second overwriting the first.
enum SZAgentGraphPanelMode: String, CaseIterable { case plan = "Plan", run = "Run" }


/// The transcript's jump into the Agent Graph panel, set by the app layer. An Environment value
/// on purpose, matching `\.szRevealInProfiler`: chat rows are VALUE-ONLY for their Equatable
/// render skip, and environment reads don't participate in `==`. Unlike the Profiler's, this one
/// is never nil in the app — the Agent Graph panel ships everywhere the packs do.
public struct SZRevealInAgentGraphKey: EnvironmentKey {
    public static let defaultValue: (@Sendable @MainActor (UUID) -> Void)? = nil
}

extension EnvironmentValues {
    public var szRevealInAgentGraph: (@Sendable @MainActor (UUID) -> Void)? {
        get { self[SZRevealInAgentGraphKey.self] }
        set { self[SZRevealInAgentGraphKey.self] = newValue }
    }
}
