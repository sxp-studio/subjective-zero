// SPDX-License-Identifier: AGPL-3.0-only
// The builds' presence in the transcript, pinned between the messages and the composer while
// anything is in flight. It exists because a run outlives the Director's own turn: the graph's
// dispatch node waits on the fleet, so the Director's turn finishes ("Worked for 24s") while the
// build is very much running.
//
// It draws a small process tree — one group per live build, the Director's own traversal with the
// coding agents it dispatched hanging off it on a drawn connector. Each lane is a door into that
// agent's run, and a live Director lane carries the ■ that stops THAT build (the only per-build
// stop there is; the HUD has none, and ⌘. stops them all).
//
// The lanes are the strip's own, not the Agent Graph's `SZAgentSubagentLane`: inside a dispatch
// card a lane fills the card's width, and out here that read as a stack of full-width buttons.
// What the two surfaces share is the vocabulary — `SZRunBadge` and its one word per state.
//
// Presence, not a lock: the composer stays live throughout and a send simply queues. Deliberately
// OUTSIDE the transcript's ScrollView — a run is a state, not a message, so it must not enter the
// LazyVStack (where it would perturb the bottom-pin anchor) nor scroll away when reading history.
import SwiftUI
import SZCore

struct SZRunStrip: View {
    /// Every live thread, oldest first — builds run concurrently now, so the strip is a list of
    /// them, not a window onto the first one. Each is read out of `runs` as its Director lane plus
    /// the fleet it dispatched.
    let threads: [UUID]
    /// Every run record the app knows; the thread groups are projected out of it.
    let runs: [SZAgentGraphRun]
    /// A lane's work-node title; nil falls the lane back to the node id, as on the canvas.
    let title: (String) -> String?
    /// Open a run in the Agent Graph panel. nil = the surface isn't wired; the strip is a readout.
    let onOpen: ((UUID) -> Void)?
    /// Work SCHEDULED and not yet started, oldest first — the asks that survived being second.
    /// They sit under the live groups because that is the order they will happen in.
    var scheduled: [SZScheduledRow] = []
    /// Drop a scheduled task (its ✕). nil = the surface isn't wired; the rows are a readout.
    var onCancelScheduled: ((UUID) -> Void)?
    /// Interrupt ONE live traversal by its thread — the running counterpart of a scheduled row's ✕,
    /// and the only control that stops a single build.
    var onStopRun: ((UUID) -> Void)?

    /// Past these the strip would own more of the panel than the conversation does; the rest are
    /// one honest line rather than a silent truncation.
    private static let threadCap = 3
    private static let laneCap = 3

    private var shownThreads: [UUID] { Array(threads.prefix(Self.threadCap)) }
    private var hiddenThreads: Int { max(0, threads.count - Self.threadCap) }
    private var shownScheduled: [SZScheduledRow] { Array(scheduled.prefix(Self.laneCap)) }
    private var hiddenScheduled: Int { max(0, scheduled.count - Self.laneCap) }

    var body: some View {
        VStack(spacing: 0) {
            // No rule above it. A hairline said "another section starts here", but the strip is
            // not a section — it is the same conversation's state, and the pills already read as
            // objects rather than prose. What separates it is the same 10pt the composer keeps
            // below it, so the three bands of the panel breathe evenly.
            VStack(alignment: .leading, spacing: SZLaneMetrics.groupGap) {
                ForEach(shownThreads, id: \.self) { thread in threadGroup(thread) }
                if hiddenThreads > 0 { overflowLine("+\(hiddenThreads) more running") }
                if !shownScheduled.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(shownScheduled) { row in scheduledRow(row) }
                    }
                }
                if hiddenScheduled > 0 { overflowLine("+\(hiddenScheduled) more queued") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
    }

    /// One build: the Director's own traversal, then the fleet hanging off it on a connector. The
    /// rows are flush (spacing 0, the gap lives inside each row) so the connector's vertical is
    /// CONTINUOUS down the group instead of dashing between lanes.
    @ViewBuilder
    private func threadGroup(_ thread: UUID) -> some View {
        let leader = runs.first { $0.id == thread }
        let children = SZAgentGraphRun.workChildren(thread: thread, in: runs)
        // The cap keeps the LIVE children first. `workChildren` is oldest-first and keeps sealed
        // records, so a plain prefix showed the first three agents the build ever dispatched —
        // grey, finished — and hid every agent actually working behind "+N more", which is the one
        // thing this strip exists to show. Within each group the dispatch order is kept.
        let lanes = Array((children.filter(\.isLive) + children.filter { !$0.isLive })
                            .prefix(Self.laneCap))
        let overflow = max(0, children.count - lanes.count)
        VStack(alignment: .leading, spacing: 0) {
            if let leader {
                laneRow(SZLaneModel(run: leader, name: "Director", symbol: "eyeglasses",
                                    tint: SZEdgeStyle.intentViolet),
                        stop: leader.isLive
                            ? onStopRun.map { stop in { stop(leader.thread ?? leader.id) } }
                            : nil)
            }
            if lanes.isEmpty {
                if leader == nil { waitingLine(thread: thread) }
            } else {
                ForEach(Array(lanes.enumerated()), id: \.element.id) { index, run in
                    laneRow(SZLaneModel(run: run, name: run.work.flatMap(title) ?? "work",
                                        symbol: "hammer", tint: SZAgentGraphStyle.live),
                            connector: (index == lanes.count - 1 && overflow == 0) ? .last : .middle)
                }
                if overflow > 0 {
                    HStack(spacing: 0) {
                        SZLaneConnector(kind: .last)
                        overflowLine("+\(overflow) more")
                    }
                }
            }
        }
    }

    /// One lane: the pill, and the connector column to its left when it hangs off a Director. The
    /// pill hugs its content — a build's width is its own name's width, not the panel's.
    private func laneRow(_ model: SZLaneModel,
                         connector: SZLaneConnector.Kind? = nil,
                         stop: (() -> Void)? = nil) -> some View {
        HStack(spacing: 0) {
            if let connector { SZLaneConnector(kind: connector) }
            SZStripLane(model: model,
                        onOpen: onOpen.map { open in { open(model.run.id) } },
                        onStop: stop)
            Spacer(minLength: 0)
        }
    }

    private func overflowLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(height: SZLaneMetrics.rowHeight, alignment: .leading)
    }

    /// One scheduled task: what was asked, and why it has not started. Deliberately quieter than a
    /// running lane — it is waiting, not working — with a ✕ because an ask you changed your mind
    /// about should cost nothing to drop.
    private func scheduledRow(_ row: SZScheduledRow) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 8))
                    .foregroundStyle(.quaternary)
                Text(row.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if let waiting = row.waitingOn {
                    Text("· behind \(waiting)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                }
                if let onCancelScheduled {
                    SZLaneActionButton(symbol: "xmark", help: "Drop this scheduled task") {
                        onCancelScheduled(row.id)
                    }
                }
            }
            .padding(.leading, SZLaneMetrics.padH)
            .padding(.trailing, onCancelScheduled == nil ? SZLaneMetrics.padH : 3)
            .frame(height: SZLaneMetrics.pillHeight)
            .background(RoundedRectangle(cornerRadius: SZLaneMetrics.radius)
                .fill(Color.white.opacity(0.035)))
            Spacer(minLength: 0)
        }
        .frame(height: SZLaneMetrics.rowHeight)
    }

    /// Before the fleet goes out — the Director is deciding, and the build is still the thing in
    /// flight. Quiet by design: the Director's own turn is already streaming in the transcript
    /// right above, and this must not shout over it.
    private func waitingLine(thread: UUID) -> some View {
        HStack(spacing: 6) {
            // The same dot as a working scope, cadence included, so the strip and the transcript
            // read as one state rather than two opinions.
            SZPulsingOpacity(range: 0.35...0.95, halfPeriod: 0.79) {
                Circle().fill(SZNodeStatus.building.color).frame(width: 4.5, height: 4.5)
            }
            Text("graph running")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(height: SZLaneMetrics.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?(thread) }
        .help("Open this run in the Agent Graph")
    }
}

/// The strip's one set of numbers. A row is taller than its pill: the difference is the gap between
/// pills, and it belongs to the ROW so the connector can draw through it.
enum SZLaneMetrics {
    static let pillHeight: CGFloat = 21
    static let rowHeight: CGFloat = 24
    static let radius: CGFloat = 6
    static let padH: CGFloat = 7
    static let connectorWidth: CGFloat = 15
    /// Every small control in the strip — a lane's ■, a scheduled row's ✕ — is this size.
    static let controlSize: CGFloat = 16
    /// Zero: a row already carries its own gap (rowHeight − pillHeight), so anything here made
    /// the step BETWEEN builds bigger than the step from a Director to its own agents — which
    /// reads as the child belonging to the group below it.
    static let groupGap: CGFloat = 0
}

/// What a lane says, gathered so the row and the view agree on it.
struct SZLaneModel {
    let run: SZAgentGraphRun
    let name: String
    let symbol: String
    let tint: Color

    /// Where this agent is: the last entry still running, else the last one it finished.
    var phase: String? { run.trace.last { $0.phase == .running }?.node ?? run.trace.last?.node }
}

/// The elbow joining a coding agent to the Director that dispatched it — drawn, not typed, so the
/// vertical actually meets the row above it. `.middle` continues past this lane to the next child;
/// `.last` stops at the elbow.
struct SZLaneConnector: View {
    enum Kind { case middle, last }
    let kind: Kind

    var body: some View {
        Path { path in
            let x: CGFloat = 6
            let midY = SZLaneMetrics.rowHeight / 2
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: kind == .last ? midY : SZLaneMetrics.rowHeight))
            path.move(to: CGPoint(x: x, y: midY))
            path.addLine(to: CGPoint(x: SZLaneMetrics.connectorWidth - 3, y: midY))
        }
        .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        .frame(width: SZLaneMetrics.connectorWidth, height: SZLaneMetrics.rowHeight)
    }
}

/// One agent, as a pill that hugs its own text: who, where they are, how long, what state — and, on
/// a live Director, the ■ that stops that build. The pill carries the agent's colour as a wash
/// rather than an outline; at four lanes an outline each was the loudest thing in the panel.
struct SZStripLane: View {
    let model: SZLaneModel
    var onOpen: (() -> Void)?
    var onStop: (() -> Void)?
    @State private var hover = false

    private var isLive: Bool { model.run.isLive }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Image(systemName: model.symbol)
                    .font(.system(size: 8))
                    .foregroundStyle(isLive ? model.tint : Color.secondary)
                Text(model.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let phase = model.phase {
                    Text(phase)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                // State, then how long it has been in it, then the control: the badge is what you
                // read first, and the clock qualifies it.
                if isLive {
                    SZPulsingOpacity(range: 0.35...1, halfPeriod: SZPulse.period / 2) {
                        SZRunBadge.running()
                    }
                } else {
                    SZRunBadge.forConclusion(model.run.conclusion)
                }
                Text(model.run.endedAt
                        .map { SZTurnBreakdown.format($0.timeIntervalSince(model.run.startedAt)) }
                     ?? SZAgentGraphClock.stopwatch(context.date.timeIntervalSince(model.run.startedAt)))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    // Beside a pulsing badge: swap the string, never cross-fade it.
                    .contentTransition(.identity)
                if let onStop {
                    SZLaneActionButton(symbol: "stop.fill",
                                       help: "Stop this build — the others keep going",
                                       action: onStop)
                }
            }
            .padding(.leading, SZLaneMetrics.padH)
            .padding(.trailing, onStop == nil ? SZLaneMetrics.padH : 3)
            .frame(height: SZLaneMetrics.pillHeight)
            .background(RoundedRectangle(cornerRadius: SZLaneMetrics.radius)
                .fill(isLive ? model.tint.opacity(hover ? 0.20 : 0.14)
                             : Color.white.opacity(hover ? 0.075 : 0.04)))
        }
        .frame(height: SZLaneMetrics.rowHeight)
        // The pill opens the run; the ■ inside it is its own button, so the two must not nest — a
        // tap gesture on the row leaves the control clickable where a Button label would not.
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .trackingHover($hover)
        .help(onOpen == nil ? "" : "Open this run in the Agent Graph")
    }
}

/// The strip's small trailing control — a lane's ■, a scheduled row's ✕. ONE size for both, and a
/// real hit target with a hover state rather than a bare tinted glyph floating beside the row.
struct SZLaneActionButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            // Sits ON a tinted wash, so it needs its own contrast: a light glyph on a dark disc,
            // not a grey glyph on a barely-there one.
            Image(systemName: symbol)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Color.white.opacity(hover ? 1 : 0.8))
                .frame(width: SZLaneMetrics.controlSize, height: SZLaneMetrics.controlSize)
                .background(Circle().fill(Color.black.opacity(hover ? 0.45 : 0.28)))
        }
        .buttonStyle(.plain)
        .trackingHover($hover)
        .help(help)
    }
}

/// One row of the strip's scheduled section — a task waiting its turn.
public struct SZScheduledRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// What was asked, in one line.
    public let title: String
    /// What it is waiting for, when something holds its work ("Blur"); nil when it is simply next.
    public let waitingOn: String?

    public init(id: UUID, title: String, waitingOn: String? = nil) {
        self.id = id
        self.title = title
        self.waitingOn = waitingOn
    }
}
