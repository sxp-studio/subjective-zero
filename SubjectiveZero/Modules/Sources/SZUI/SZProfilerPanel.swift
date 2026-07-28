// SPDX-License-Identifier: AGPL-3.0-only
// The Profiler panel (DEBUG builds; SZPanelKind.profiler): browse the project's recorded runs,
// select one for its breakdown — stat strip, a block timeline (one lane per agent, blocks
// positioned on the run's shared axis; a lane expands into its turn's phase blocks), and per-turn
// detail rows — plus Copy Summary, the same plain text `debug_run_summary` serves (one renderer,
// SZCore's SZTurnBreakdown). Data is reassembled from transcripts (`runRecords`), so it survives
// relaunches and needs no live wiring beyond the store. Styling follows the app's language:
// monospaced small-caps section labels, hairline separators, the semantic accent palette
// (Director violet / coding agents orange) — no system chrome.
import AppKit
import SwiftUI
import SZCore

/// The chat transcript's jump-to-Profiler action: set by the app when the Profiler surface
/// exists (DEBUG builds), nil otherwise — the transcript's link renders only when set. An
/// Environment value on purpose: chat rows are VALUE-ONLY for their Equatable render skip, and
/// environment reads don't participate in `==`.
public struct SZRevealInProfilerKey: EnvironmentKey {
    public static let defaultValue: (@Sendable @MainActor (UUID) -> Void)? = nil
}

extension EnvironmentValues {
    public var szRevealInProfiler: (@Sendable @MainActor (UUID) -> Void)? {
        get { self[SZRevealInProfilerKey.self] }
        set { self[SZRevealInProfilerKey.self] = newValue }
    }
}

/// Prompt inspection from the debug UI: opens the turn's rendered prompt (what the CLI was
/// ACTUALLY sent) in the default text editor via a temp file. Set only while tracing holds
/// prompts; same environment-value rationale as above.
public struct SZViewTurnPromptKey: EnvironmentKey {
    public static let defaultValue: (@Sendable @MainActor (UUID) -> Void)? = nil
}

/// Which turn ids the host currently HOLDS a prompt for (the in-memory ring is session-scoped) —
/// the view-prompt button renders only for these, so it can never click into nothing.
public struct SZHeldPromptTurnIDsKey: EnvironmentKey {
    public static let defaultValue: Set<UUID> = []
}

/// Token inspection: opens the turn's ACTUAL in/out text (the rendered prompt + the streamed
/// output) in the app's "Tokens" window. Same environment-value rationale as above.
public struct SZViewTurnTokensKey: EnvironmentKey {
    public static let defaultValue: (@Sendable @MainActor (UUID) -> Void)? = nil
}

extension EnvironmentValues {
    public var szViewTurnPrompt: (@Sendable @MainActor (UUID) -> Void)? {
        get { self[SZViewTurnPromptKey.self] }
        set { self[SZViewTurnPromptKey.self] = newValue }
    }
    public var szHeldPromptTurnIDs: Set<UUID> {
        get { self[SZHeldPromptTurnIDsKey.self] }
        set { self[SZHeldPromptTurnIDsKey.self] = newValue }
    }
    public var szViewTurnTokens: (@Sendable @MainActor (UUID) -> Void)? {
        get { self[SZViewTurnTokensKey.self] }
        set { self[SZViewTurnTokensKey.self] = newValue }
    }
}

/// The Profiler's color system: one MAJOR color per agent type (Director violet, coding agents
/// orange — the app's semantic palette), and two task-type TINTS of it — `local` for harness
/// work the app itself performs (tool handling, compile, promote), `server` for the model
/// working (reasoning/streaming — the dim sibling, same hue). One place, so the timeline lanes
/// and the detail-row bars can never drift apart.
enum SZProfilerTint {
    static func major(isDirector: Bool) -> Color {
        isDirector ? SZChatPanel.directorColor : SZChatPanel.agentColor
    }
    static func local(isDirector: Bool) -> Color {
        major(isDirector: isDirector).opacity(0.62)
    }
    static func server(isDirector: Bool) -> Color {
        major(isDirector: isDirector).opacity(0.28)
    }
}

public struct SZProfilerPanel: View {
    private let store: SZStore
    private let titles: [String: String]   // scope key → node title, for lane names
    private let tracingEnabled: Bool
    private let unreadRunIDs: Set<UUID>    // host-owned: runs recorded since the user last looked
    private let onSelectRun: (UUID) -> Void
    /// A record the transcript asked to reveal (host-owned, consumed once shown).
    private let focusRequest: UUID?
    private let onConsumeFocus: () -> Void
    @State private var selectedRunID: UUID?

    public init(store: SZStore, titles: [String: String], tracingEnabled: Bool,
                unreadRunIDs: Set<UUID> = [], onSelectRun: @escaping (UUID) -> Void = { _ in },
                focusRequest: UUID? = nil, onConsumeFocus: @escaping () -> Void = {}) {
        self.store = store
        self.titles = titles
        self.tracingEnabled = tracingEnabled
        self.unreadRunIDs = unreadRunIDs
        self.onSelectRun = onSelectRun
        self.focusRequest = focusRequest
        self.onConsumeFocus = onConsumeFocus
    }

    private var records: [SZTurnBreakdown.RunRecord] {
        SZTurnBreakdown.runRecords(chat: store.chat, titles: titles)
    }
    /// Turns driven outside a run (a chat straight to a Coding Agent / the Director) — same
    /// detail view, single lane.
    private var chatTurns: [SZTurnBreakdown.RunRecord] {
        SZTurnBreakdown.chatTurnRecords(chat: store.chat, titles: titles)
    }

    public var body: some View {
        let records = records
        let chatTurns = chatTurns
        Group {
            if records.isEmpty, chatTurns.isEmpty {
                emptyState
            } else {
                // ONE chronological list — a run and a direct chat turn are both just sessions;
                // the subtitle (Director + N nodes vs. the agent's name) tells them apart.
                let all = (records + chatTurns).sorted { $0.startedAt > $1.startedAt }
                let selected = all.first { $0.id == selectedRunID } ?? all[0]
                HStack(spacing: 0) {
                    sessionList(all, selectedID: selected.id)
                        .frame(width: 190)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                    SZRunDetailView(record: selected)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // On the common container, so a focus request landing while the panel shows its empty
        // state is still consumed (and honored the moment records exist) instead of going stale.
        .onAppear { consumeFocusRequest() }
        .onChange(of: focusRequest) { consumeFocusRequest() }
    }

    /// The transcript's "open in Profiler" landing: select the requested record and clear the ask.
    private func consumeFocusRequest() {
        guard let focusRequest else { return }
        selectedRunID = focusRequest
        onSelectRun(focusRequest)   // also clears the unread dot
        onConsumeFocus()
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(tracingEnabled
                 ? "No recorded runs yet — build the graph and the run's breakdown lands here."
                 : "Tracing is off (SZ_TRACE) — runs aren't being recorded.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sessionList(_ all: [SZTurnBreakdown.RunRecord], selectedID: UUID) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("SESSIONS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                ForEach(all) { record in
                    SZSessionRow(record: record, selected: record.id == selectedID,
                                 unread: unreadRunIDs.contains(record.id)) {
                        selectedRunID = record.id
                        onSelectRun(record.id)
                    }
                }
            }
        }
    }
}

/// A run row in the app's idiom — accent rail + subtle fill for the selection (never the
/// system highlight), an unread dot in the user's action blue for a run recorded since the
/// user last looked, and a live relative age so "which one is latest" answers itself.
/// Its own view so hover state stays LOCAL — a panel-level hover id re-folds every session's
/// records on each row crossing.
private struct SZSessionRow: View {
    let record: SZTurnBreakdown.RunRecord
    let selected: Bool
    let unread: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 7) {
                Capsule()
                    .fill(selected ? SZChatPanel.directorColor.opacity(0.8) : .clear)
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 2) {
                    // WHEN (relative, ticking) and how long — the two facts that pick a row.
                    TimelineView(.periodic(from: .now, by: 10)) { context in
                        Text("\(relativeAge(now: context.date))  ·  "
                             + SZTurnBreakdown.format(record.wallDuration))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    // WHO/WHAT and cost: agents touched + total tokens, nothing else.
                    Text(subtitle)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if unread {
                    Capsule().fill(SZChatPanel.userColor)
                        .frame(width: 14, height: 5)
                        .padding(.top, 5)
                        .help("Recorded since you last looked")
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(selected ? 0.06 : (hovered ? 0.035 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .padding(.horizontal, 4)
        // The absolute clock lives in the hover tooltip — the row itself stays relative.
        .help(record.startedAt.formatted(date: .abbreviated, time: .standard))
    }

    /// Age of the run's COMPLETION (when the record was generated) — seconds first, coarser as
    /// it ages.
    private func relativeAge(now: Date) -> String {
        let age = max(0, now.timeIntervalSince(record.startedAt.addingTimeInterval(record.wallDuration)))
        if age < 60 { return "\(Int(age))s ago" }
        if age < 3600 { return "\(Int(age / 60))m ago" }
        if age < 86_400 { return "\(Int(age / 3600))h ago" }
        return "\(Int(age / 86_400))d ago"
    }

    /// Agents + nodes touched + total tokens — the compact identity line.
    private var subtitle: String {
        let tokens = SZTurnBreakdown.totalUsage(of: record.turns).map {
            " · \(SZTurnBreakdown.formatTokens($0.inputTokens + $0.outputTokens)) tok"
        } ?? ""
        guard !record.rollup.isEmpty else {   // a chat turn is its agent
            return (record.turns.first?.label ?? "turn") + tokens
        }
        let nodes = record.rollup.filter { $0.stage == SZTurnStage.runNode }.count
        return "Director + \(nodes) node\(nodes == 1 ? "" : "s")" + tokens
    }
}

// MARK: - Run detail

/// One run's detail: header + stat strip, the block timeline, then per-turn phase rows.
struct SZRunDetailView: View {
    let record: SZTurnBreakdown.RunRecord
    /// The event under the cursor, ANYWHERE (a timeline block or a detail row) — both surfaces
    /// highlight it, so the block↔row correspondence is unmistakable.
    @State private var hoveredEventKey: String?
    /// The clicked row's key — STICKY, unlike hover: expanding a lane grows the pinned timeline
    /// and shifts the sections under a stationary cursor, so hover alone would jump to whatever
    /// row slid underneath. Cleared by clicking the same row again or switching records.
    @State private var selectedEventKey: String?
    /// Which turns' phase sub-lanes are open — lifted here so clicking a detail ROW can expand
    /// its turn's lane (the row's block must be visible to be highlighted).
    @State private var expandedTurns: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statStrip
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            // The timeline stays PINNED (own bounded scroll if many lanes) while the turn
            // sections scroll independently below — hovering a deep row must light a block you
            // can actually see, not one scrolled off the top.
            ScrollView(.vertical, showsIndicators: false) {
                SZRunTimelineView(record: record, hoveredEventKey: $hoveredEventKey,
                                  selectedEventKey: selectedEventKey,
                                  expandedTurns: $expandedTurns)   // pins labels, scrolls its own tracks
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            // The turn sections: NESTED single-axis scrolls, not one two-axis ScrollView — a
            // two-axis ScrollView misregisters macOS hover tracking areas (rows highlighted ~3
            // rows off the cursor). Single-line rows, fixed column widths, overflow rides the
            // inner horizontal scroll.
            ScrollView(.vertical, showsIndicators: true) {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(Array(record.turns.enumerated()), id: \.offset) { index, turn in
                            SZTurnDetailSection(turn: turn, record: record,
                                                hoveredEventKey: $hoveredEventKey,
                                                selectedEventKey: $selectedEventKey,
                                                turnIndex: index,
                                                expandedTurns: $expandedTurns)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(12)
        // A different record is a different world — no highlight (or stale frame) may carry over.
        .onChange(of: record.id) {
            hoveredEventKey = nil
            selectedEventKey = nil
            expandedTurns = []
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            // A chat-driven single turn (empty rollup) is titled by its agent, not a run id.
            Text(record.rollup.isEmpty
                 ? "TURN · \(record.turns.first?.label.uppercased() ?? "AGENT")"
                 : "RUN \(record.id.uuidString.prefix(8))")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Text(record.startedAt.formatted(date: .abbreviated, time: .standard))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private var statStrip: some View {
        let total = record.rollup.last { $0.stage == SZTurnStage.runTotal }
        let nodes = record.rollup.filter { $0.stage == SZTurnStage.runNode }
        return HStack(spacing: 14) {
            stat("wall", SZTurnBreakdown.format(record.wallDuration))
            if !record.rollup.isEmpty {   // run-shaped stats are noise on a single chat turn
                stat("nodes", "\(nodes.count)")
                stat("turns", "\(record.turns.count)")
            }
            if let detail = total?.detail {
                stat("tokens", detail)
            } else if let usage = record.turns.first?.usage {
                stat("tokens", "\(SZTurnBreakdown.formatTokens(usage.inputTokens)) in / "
                     + "\(SZTurnBreakdown.formatTokens(usage.outputTokens)) out")
            }
            if let calls = SZTurnBreakdown.callsDetail(of: record.turns) {
                stat("calls", calls)
            }
            Spacer()
            // Lives HERE, not in the title row: the auto-hide panel header floats over the top
            // ~26pt on hover and would swallow the click.
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(SZTurnBreakdown.renderSummary(record), forType: .string)
            } label: {
                Label("Copy Summary", systemImage: "doc.on.doc")
                    .font(.system(size: 10))
            }
            .buttonStyle(SZIconHoverStyle())
            .help("Copy the report as text (same output as debug_run_summary)")
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label.uppercased()).font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(value).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Block timeline

/// The run as lanes of blocks on one shared axis (the Safari-timelines idea, much simplified):
/// the run's full span on top, then one lane per agent turn — Director violet, coding agents
/// orange. Clicking a lane's LABEL (whole row, not a 6pt chevron) expands it into the turn's
/// phase blocks over a dim extent underlay. Hovering any block writes its numbers into the
/// readout line below the lanes (instant — no tooltip delay), and a trackpad pinch zooms the
/// time axis (labels stay pinned; the track area scrolls horizontally).
private struct SZRunTimelineView: View {
    let record: SZTurnBreakdown.RunRecord
    @Binding var hoveredEventKey: String?
    let selectedEventKey: String?          // sticky row selection — blocks stay lit through layout shifts
    @Binding var expandedTurns: Set<Int>   // indices into record.turns (lifted — rows expand lanes)
    @State private var zoom: CGFloat = 1
    @State private var zoomAnchor: CGFloat = 1        // pinch-start value
    @State private var hoverText = ""
    @State private var hoveredBlockID: String?

    private static let laneHeight: CGFloat = 14
    private static let labelWidth: CGFloat = 92
    private static let axisHeight: CGFloat = 13
    private static let zoomRange: ClosedRange<CGFloat> = 1...60

    /// One rendered lane: its pinned label cell and its blocks. Built as data so the label
    /// column and the (zoomable, scrollable) track column stay row-aligned.
    private struct Lane {
        var label: String
        var color: Color
        var blocks: [Block]
        var underlay: Block?
        var expandIndex: Int?   // toggles record.turns[i]'s phase sub-lane
    }

    private struct Block: Identifiable {
        var offset: Double     // 0…1 on the run axis
        var fraction: Double
        var readout: String
        var tint: Color?       // nil → the lane's color (model segments dim themselves)
        /// The underlying event's cross-view key (nil for whole-turn/run lanes) — hovering the
        /// matching detail row highlights this block and vice versa.
        var eventKey: String?
        /// Vertical shrink per nesting level, so a child block (reload) sits visibly INSIDE its
        /// parent (promote) instead of covering it edge-to-edge.
        var inset: CGFloat = 0
        /// STABLE, content-derived identity. A per-build `UUID()` here caused a hover loop:
        /// hover mutates state → body recomputes → every block gets a fresh id → the "old"
        /// block's hover-exit fires → state mutates → … (the beachball).
        var id: String { "\(offset)|\(fraction)|\(readout)" }
    }

    private var lanes: [Lane] {
        // The top lane wears the user's action blue — a run is the user's Build (a chat turn,
        // their message); the lanes below are the agents doing it.
        let topLabel = record.rollup.isEmpty ? "turn" : "run"
        var lanes = [Lane(label: topLabel, color: SZChatPanel.userColor.opacity(0.55),
                          blocks: [block(start: record.startedAt, duration: record.wallDuration,
                                         title: topLabel)],
                          underlay: nil, expandIndex: nil)]
        for (index, turn) in record.turns.enumerated() {
            let color = SZProfilerTint.major(isDirector: turn.isDirector)
            lanes.append(Lane(label: turn.label, color: color,
                              blocks: [block(start: turn.start, duration: turn.duration ?? 0,
                                             title: turn.label)],
                              underlay: nil, expandIndex: index))
            if expandedTurns.contains(index) {
                lanes.append(Lane(label: "", color: SZProfilerTint.local(isDirector: turn.isDirector),
                                  blocks: phaseBlocks(of: turn, laneColor: color),
                                  underlay: block(start: turn.start, duration: turn.duration ?? 0,
                                                  title: turn.label),
                                  expandIndex: nil))
            }
        }
        return lanes
    }

    var body: some View {
        let lanes = lanes
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("TIMELINE")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                if zoom > 1.01 {
                    Button("reset zoom") { withAnimation(.easeOut(duration: 0.15)) { zoom = 1; zoomAnchor = 1 } }
                        .buttonStyle(.plain)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            GeometryReader { geometry in
                let baseWidth = max(60, geometry.size.width - Self.labelWidth - 8)
                let trackWidth = baseWidth * zoom
                HStack(alignment: .top, spacing: 4) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Color.clear.frame(height: Self.axisHeight)   // row-aligns with the ruler
                        ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
                            labelCell(lane)
                        }
                    }
                    .frame(width: Self.labelWidth)
                    ScrollView(.horizontal, showsIndicators: zoom > 1.01) {
                        VStack(alignment: .leading, spacing: 2) {
                            axisRow(trackWidth: trackWidth)   // zooms + scrolls WITH the tracks
                            ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
                                trackCell(lane, trackWidth: trackWidth)
                            }
                        }
                    }
                    // Trackpad pinch — anchored at the pinch-start zoom so it composes.
                    .gesture(MagnifyGesture()
                        .onChanged { value in
                            zoom = min(max(zoomAnchor * value.magnification, Self.zoomRange.lowerBound),
                                       Self.zoomRange.upperBound)
                        }
                        .onEnded { _ in zoomAnchor = zoom })
                }
            }
            .frame(height: Self.axisHeight + 2 + CGFloat(lanes.count) * (Self.laneHeight + 2))
            // The hover readout — Instruments-style fixed inspector line, instant on hover.
            Text(hoverText.isEmpty ? " " : hoverText)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // Selecting another record is a fresh timeline: stale hover text and zoom from the
        // previous one must not carry over. (`expandedTurns` is the parent's — it resets it.)
        .onChange(of: record.id) {
            hoverText = ""
            hoveredBlockID = nil
            zoom = 1
            zoomAnchor = 1
        }
    }

    private func labelCell(_ lane: Lane) -> some View {
        Group {
            if let index = lane.expandIndex {
                // The WHOLE label row is the disclosure target — not a 6pt chevron.
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        if expandedTurns.contains(index) { expandedTurns.remove(index) }
                        else { expandedTurns.insert(index) }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 6, weight: .bold))
                            .rotationEffect(.degrees(expandedTurns.contains(index) ? 90 : 0))
                            .foregroundStyle(.tertiary)
                        Text(lane.label)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(SZIconHoverStyle())
                .help(expandedTurns.contains(index) ? "Hide phases" : "Show phases")
            } else {
                Text(lane.label)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(height: Self.laneHeight)
    }

    /// The time ruler: ticks at a "nice" interval chosen so labels stay readable at the CURRENT
    /// zoom — zooming in reveals finer ticks, which is when an axis matters most.
    private func axisRow(trackWidth: CGFloat) -> some View {
        let span = max(record.wallDuration, 0.001)
        let step = Self.axisStep(span: span, trackWidth: trackWidth)
        let ticks = Array(stride(from: 0.0, through: span, by: step))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                let x = trackWidth * CGFloat(tick / span)
                let label = tick == 0 ? "0" : SZTurnBreakdown.format(tick)
                // ~4.9pt/glyph at 8pt monospaced — enough to know when a label would clip at
                // the right edge and must sit LEFT of its tick instead.
                let estimatedWidth = CGFloat(label.count) * 4.9
                Rectangle().fill(Color.white.opacity(0.18))
                    .frame(width: 1, height: 4)
                    .offset(x: x, y: Self.axisHeight - 4)
                Text(label)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .offset(x: x + 3 + estimatedWidth > trackWidth ? x - 3 - estimatedWidth : x + 3)
            }
        }
        .frame(width: trackWidth, height: Self.axisHeight, alignment: .topLeading)
    }

    /// The smallest "nice" interval whose ticks sit ≥ ~70pt apart at this width.
    private static func axisStep(span: Double, trackWidth: CGFloat) -> Double {
        let nice: [Double] = [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        for step in nice where trackWidth * CGFloat(step / span) >= 70 { return step }
        return span
    }

    private func trackCell(_ lane: Lane, trackWidth: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.05))
                .frame(width: trackWidth, height: Self.laneHeight)
            if let underlay = lane.underlay {
                blockView(underlay, color: Color.white.opacity(0.07), trackWidth: trackWidth,
                          height: Self.laneHeight)
            }
            ForEach(lane.blocks) { block in
                blockView(block, color: block.tint ?? lane.color, trackWidth: trackWidth,
                          height: Self.laneHeight - 4)
            }
        }
        .contentShape(Rectangle())
        // ONE hover computation per lane, from the cursor's x — per-block `.onHover` on offset
        // views misregistered regions (a cursor at the lane's left highlighted the rightmost
        // block). Math can't be wrong: topmost block containing x wins (draw order).
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                let frac = Double(point.x / max(trackWidth, 1))
                let minFrac = Double(2.5 / max(trackWidth, 1))   // slivers get their drawn width
                let hit = lane.blocks.last { block in
                    frac >= block.offset && frac <= block.offset + max(block.fraction, minFrac)
                }
                hoveredBlockID = hit?.id
                hoveredEventKey = hit?.eventKey   // …and light up the matching detail row
                hoverText = hit?.readout ?? hoverText
            case .ended:
                hoveredBlockID = nil
                hoveredEventKey = nil
                hoverText = ""
            }
        }
    }

    private func blockView(_ block: Block, color: Color, trackWidth: CGFloat, height: CGFloat) -> some View {
        let offset = min(max(block.offset, 0), 1)
        let fraction = min(max(block.fraction, 0), 1 - offset)
        // Lit by direct hover OR by hovering its detail row (the shared event key).
        let hovered = hoveredBlockID == block.id
            || (block.eventKey != nil
                && (block.eventKey == hoveredEventKey || block.eventKey == selectedEventKey))
        // Hover channels: the block brightens + strokes (instant), the readout line updates
        // (instant, fixed position), and the system tooltip follows (`.help`, at rest).
        return RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .brightness(hovered ? 0.18 : 0)
            .overlay(RoundedRectangle(cornerRadius: 2)
                .stroke(Color.white.opacity(hovered ? 0.55 : 0), lineWidth: 1))
            .frame(width: max(2.5, trackWidth * fraction), height: max(2, height - block.inset * 2))
            .offset(x: trackWidth * offset)
            .help(block.readout)
    }

    private func block(start: Date, duration: TimeInterval, title: String,
                       tint: Color? = nil, eventKey: String? = nil) -> Block {
        let span = max(record.wallDuration, 0.001)
        let offset = start.timeIntervalSince(record.startedAt)
        return Block(offset: offset / span, fraction: duration / span,
                     readout: "\(title) — \(SZTurnBreakdown.format(duration))"
                        + (offset >= 0.5 ? " · starts +\(SZTurnBreakdown.format(offset))" : ""),
                     tint: tint, eventKey: eventKey)
    }

    /// The turn's measured phases as blocks (instants get a sliver), PLUS the model's actual
    /// segments: every gap between measured spans is the model/server working — rendered as its
    /// own dim block, hoverable like everything else, not one big lump and not empty space.
    private func phaseBlocks(of turn: SZTurnBreakdown.RunTurn, laneColor: Color) -> [Block] {
        var blocks: [Block] = turn.events.compactMap { event in
            switch event.stage {
            case SZTurnStage.modelTime, SZTurnStage.providerReport, SZTurnStage.queueWait:
                return nil
            default:
                let name = SZTurnStage.displayName(event.stage)
                let label = event.stage == SZTurnStage.toolCall || event.stage == SZTurnStage.mcpTool
                    ? "→ \(event.detail ?? "tool")" : name + (event.detail.map { " (\($0))" } ?? "")
                var made = block(start: event.start, duration: event.duration ?? 0, title: label,
                                 eventKey: SZTurnBreakdown.eventKey(event))
                made.inset = CGFloat(min(SZTurnBreakdown.depth(of: event, in: turn.events), 3)) * 1.5
                return made
            }
        }
        // The model's segments — same SZCore derivation the detail rows use, so the keys match.
        for segment in SZTurnBreakdown.modelSegments(of: turn) {
            blocks.append(block(start: segment.start, duration: segment.duration ?? 0,
                                title: SZTurnStage.displayName(SZTurnStage.modelTime),
                                tint: SZProfilerTint.server(isDirector: turn.isDirector),
                                eventKey: SZTurnBreakdown.eventKey(segment)))
        }
        return blocks
    }
}

// MARK: - Per-turn detail rows

/// One turn's phase list — the Safari-details idiom: name, duration, and a positioned mini bar
/// on the turn's own axis. Columns are FIXED widths shared by every section, so the whole detail
/// area reads as one table; rows are single-line, overflow rides the shared horizontal scroll.
private struct SZTurnDetailSection: View {
    let turn: SZTurnBreakdown.RunTurn
    let record: SZTurnBreakdown.RunRecord
    @Binding var hoveredEventKey: String?
    @Binding var selectedEventKey: String?
    /// Clicking a row opens this turn's phase sub-lane in the timeline — the highlighted block
    /// has to exist to be seen.
    let turnIndex: Int
    @Binding var expandedTurns: Set<Int>
    @Environment(\.szViewTurnPrompt) private var viewTurnPrompt
    @Environment(\.szHeldPromptTurnIDs) private var heldPromptTurnIDs
    @Environment(\.szViewTurnTokens) private var viewTurnTokens

    // The shared column metrics — identical in every section by construction.
    private static let nameWidth: CGFloat = 200
    private static let durationWidth: CGFloat = 56
    private static let rowSpacing: CGFloat = 12
    private static let indent: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(turn.isDirector ? SZChatPanel.directorColor : SZChatPanel.agentColor)
                    .frame(width: 5, height: 5)
                Text(turn.label.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(turn.duration.map(SZTurnBreakdown.format) ?? "")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if let usage = turn.usage {
                    Text("\(SZTurnBreakdown.formatTokens(usage.inputTokens)) in / "
                         + "\(SZTurnBreakdown.formatTokens(usage.outputTokens)) out")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let calls = SZTurnBreakdown.callsDetail(of: [turn]) {
                    Text(calls)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if let viewTurnPrompt, let turnID = turn.turnID,
                   heldPromptTurnIDs.contains(turnID) {   // never render a button into nothing
                    Button { viewTurnPrompt(turnID) } label: {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 9))
                    }
                    .buttonStyle(SZIconHoverStyle())
                    .help("View the prompt this turn sent to its CLI (opens a temp file)")
                }
            }
            // The model's time appears as its SEGMENTS between the measured phases (matching the
            // timeline lanes), not one aggregate block; only the CLI's own report stays a footer.
            let phases = (turn.events.filter { !Self.isDerived($0) }
                          + SZTurnBreakdown.modelSegments(of: turn))
                .sorted { $0.start < $1.start }
            let derived = turn.events.filter { $0.stage == SZTurnStage.providerReport }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(phases.enumerated()), id: \.offset) { _, event in
                    row(event)
                }
            }
            if !derived.isEmpty {
                Rectangle().fill(Color.white.opacity(0.06))
                    .frame(width: Self.indent + Self.nameWidth + Self.durationWidth
                           + SZTurnTimelineBar.width + Self.rowSpacing * 2, height: 1)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(derived.enumerated()), id: \.offset) { _, event in
                        row(event)
                    }
                }
            }
        }
    }

    private static func isDerived(_ event: SZTurnEvent) -> Bool {
        event.stage == SZTurnStage.modelTime || event.stage == SZTurnStage.providerReport
    }

    /// One fixed-column, single-line row: name | duration | bar | detail (overflows rightward).
    /// One fixed-column, single-line row: name | duration | floating bar. Three sleekness rules:
    /// nested spans (compile/promote inside their tool span — `parentID`) indent under it;
    /// model-thinking rows are compact tinted asides, not full-weight entries; duration emphasis
    /// follows magnitude, so the seconds pop and the microseconds recede.
    private func row(_ event: SZTurnEvent) -> some View {
        let depth = SZTurnBreakdown.depth(of: event, in: turn.events)
        let key = SZTurnBreakdown.eventKey(event)
        // Lit by direct hover OR by hovering its timeline block (the shared event key).
        let hovered = hoveredEventKey == key || selectedEventKey == key
        let hoverFill: Double = hovered ? 0.06 : 0
        return HStack(spacing: Self.rowSpacing) {
            // WHEN each phase began, relative to the turn — the rows read as a trace log.
            Text(offsetLabel(for: event))
                .foregroundStyle(.quaternary)
                .frame(width: 54, alignment: .trailing)
            // Thinking rows carry the same weight as every other row — they're usually the
            // bottleneck, and dim read as "ignore me". Parentheses mark them.
            titleText(for: event, depth: depth)
                .frame(width: Self.nameWidth, alignment: .leading)
                .lineLimit(1)
            Text(event.duration.map(SZTurnBreakdown.format) ?? "")
                .foregroundStyle(durationEmphasis(for: event))
                .frame(width: Self.durationWidth, alignment: .trailing)
            if let duration = turn.duration, duration > 0 {
                SZTurnTimelineBar(
                    offset: event.start.timeIntervalSince(turn.start) / duration,
                    fraction: (event.duration ?? 0) / duration,
                    color: barColor(for: event),
                    showsTrack: false)   // dozens of gray tracks read as clutter; bars float
            }
            // A thinking row IS tokens moving — its icon opens the turn's ACTUAL tokens (the
            // prompt in, the streamed output out). Rides AFTER the bar so the fixed columns
            // stay aligned across sections.
            if event.stage == SZTurnStage.modelTime, let usage = turn.usage,
               let turnID = turn.turnID, let viewTurnTokens {
                SZTokenDetailButton(usage: usage, turnID: turnID, action: viewTurnTokens)
            }
        }
        .font(.system(size: 10, design: .monospaced))   // ONE size — mixed sizes read as misalignment
        .foregroundStyle(.secondary)
        // NO .textSelection here: selectable text swallows single clicks before the row's tap
        // gesture (expansion "sometimes not working" = clicks that landed on text). Copying
        // lives in Copy Summary.
        .padding(.leading, Self.indent)
        .padding(.vertical, 1).padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(Color(white: 1).opacity(hoverFill)))
        .contentShape(Rectangle())
        // onContinuousHover, NOT .onHover: plain onHover's tracking areas misregister inside
        // scroll views (rows lit ~3 below the cursor); continuous hover tracks correctly — it's
        // what the timeline lanes use.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if hoveredEventKey != key {
                    hoveredEventKey = key
                    // A click-selection served its purpose (surviving the expansion shift) —
                    // hovering another row retires it, so at most one row is ever lit.
                    if selectedEventKey != key { selectedEventKey = nil }
                }
            case .ended:
                if hoveredEventKey == key { hoveredEventKey = nil }
            }
        }
        // Click → sticky-select THIS row (layout may shift under the cursor as the lane opens;
        // hover would jump to whatever slid underneath) and open the turn's phase sub-lane.
        .onTapGesture {
            selectedEventKey = selectedEventKey == key ? nil : key
            withAnimation(.easeInOut(duration: 0.12)) { _ = expandedTurns.insert(turnIndex) }
        }
        .help(SZTurnBreakdown.rowTitle(for: event, in: turn.events, depth: depth))   // full text when the name column truncates
    }

    /// Big numbers lead the eye; noise recedes — for EVERY stage. A 13s think is the bottleneck
    /// and must read as loud as any other 13s; only its LABEL is the dim aside.
    private func durationEmphasis(for event: SZTurnEvent) -> AnyShapeStyle {
        guard let duration = event.duration else { return AnyShapeStyle(.quaternary) }
        if duration >= 1 { return AnyShapeStyle(.primary) }
        if duration >= 0.05 { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.tertiary)
    }

    /// A thinking row's marker is its parentheses — "(model thinking)" — at normal text weight.
    /// One SZCore-composed title for every surface — chat, Profiler, and summaries render the
    /// same event identically (three local copies had already drifted).
    private func titleText(for event: SZTurnEvent, depth: Int) -> Text {
        Text(SZTurnBreakdown.rowTitle(for: event, in: turn.events, depth: depth))
    }

    /// "+14.2s" on the record's clock: a RUN's rows share the run's zero (so every section
    /// correlates with the timeline axis — a subagent's first output reads "+22s", not "0");
    /// a standalone chat turn is its own zero. "−74ms" = the pre-start queue wait.
    private func offsetLabel(for event: SZTurnEvent) -> String {
        let zero = record.rollup.isEmpty ? turn.start : record.startedAt
        let offset = event.start.timeIntervalSince(zero)
        if offset > 0.0005 { return "+\(SZTurnBreakdown.format(offset))" }
        if offset < -0.0005 { return "−\(SZTurnBreakdown.format(-offset))" }
        return "0"
    }

    // The shared tint system: local harness phases at full strength, the model as the dim
    // same-hue sibling (SZProfilerTint) — bars match the timeline lanes exactly.
    private func barColor(for event: SZTurnEvent) -> Color {
        switch event.stage {
        case SZTurnStage.modelTime: SZProfilerTint.server(isDirector: turn.isDirector)
        case SZTurnStage.providerReport: .clear   // a report line, not a span on this axis
        case SZTurnStage.queueWait: .clear        // precedes the turn — a bar here would lie
        default: SZProfilerTint.major(isDirector: turn.isDirector)
        }
    }
}

/// The thinking row's token affordance: a tiny in/out icon (hover = the quick numbers), and a
/// click opens the turn's ACTUAL tokens — the rendered prompt in, the streamed thinking + reply
/// out — in the app's "Tokens" window (`szViewTurnTokens`, host-built so it can read the prompt
/// ring and the transcript). Selectable, paste-anywhere, guaranteed visible.
private struct SZTokenDetailButton: View {
    let usage: SZTokenUsage       // this row's turn — the hover numbers
    let turnID: UUID
    let action: @Sendable @MainActor (UUID) -> Void

    var body: some View {
        Button { action(turnID) } label: {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 8))
        }
        .buttonStyle(SZIconHoverStyle())
        .help("\(SZTurnBreakdown.formatTokens(usage.inputTokens)) in / "
              + "\(SZTurnBreakdown.formatTokens(usage.outputTokens)) out — click for the turn's actual tokens")
    }
}
