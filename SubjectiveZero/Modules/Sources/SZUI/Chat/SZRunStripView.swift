// SPDX-License-Identifier: AGPL-3.0-only
// The builds' presence in the transcript, pinned between the messages and the composer.
//
// - A run outlives the Director's turn (dispatch waits on the fleet), so without this the only
//   surviving cue that anything was happening was the Stop.
// - One group per live build: the Director's lane, its coding agents under it on a drawn
//   connector. Live children first — the cap must never hide the agents actually working.
// - The ■ on a live Director lane stops THAT build; it is the only per-build stop.
// - Lanes are the strip's own, not the canvas's `SZAgentSubagentLane` (which fills its card's
//   width by design). Shared instead: `SZRunBadge`, one word per state.
// - Deliberately OUTSIDE the transcript's ScrollView — a run is state, not a message, so it must
//   not enter the LazyVStack the bottom-pin anchor drives.
// - Presence, not a lock: the composer stays live and a send simply queues.
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

    /// One build: the Director's traversal, then its fleet on a connector. Rows are flush (the gap
    /// lives inside each row) so the connector's vertical runs unbroken down the group.
    @ViewBuilder
    private func threadGroup(_ thread: UUID) -> some View {
        let leader = runs.first { $0.id == thread }
        let children = SZAgentGraphRun.workChildren(thread: thread, in: runs)
        // LIVE children first: `workChildren` is oldest-first and keeps sealed records, so a plain
        // prefix showed three finished agents and hid the working ones behind "+N more".
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

/// The elbow joining a lane to what it belongs to — drawn, not typed, so the vertical actually
/// meets the row above. `.middle` continues to the next child; `.last` stops at the elbow.
///
/// Two callers, one shape: a coding agent hanging off its Director in the strip, and a build's
/// RECEIPT hanging off the turn that produced it in the transcript. The defaults are the strip's;
/// the transcript re-points the stem at the turn's own rail and rises to meet it.
struct SZLaneConnector: View {
    enum Kind { case middle, last }
    let kind: Kind
    /// Where the vertical runs. The strip's children hang off their group's column (6); a receipt
    /// hangs off the message rail above it, a 2pt capsule whose centre is 1.
    var stemX: CGFloat = 6
    /// How far the elbow reaches. The pill it points at starts 3pt past this, so the line stops
    /// just short of the box rather than butting into it.
    var width: CGFloat = SZLaneMetrics.connectorWidth
    /// The box the elbow centres itself on — a strip ROW, or a bare pill in the transcript.
    var height: CGFloat = SZLaneMetrics.rowHeight
    /// How far the stem climbs ABOVE its own frame to reach what it hangs from. Zero in the strip,
    /// where lanes tile flush; in the transcript it spans the gap the message rhythm leaves, so
    /// the receipt reads as continuing the turn's rail rather than floating under it. Drawn
    /// outside the frame on purpose — a Path is not clipped by `.frame`.
    var stemRise: CGFloat = 0

    var body: some View {
        Path { path in
            let midY = height / 2
            path.move(to: CGPoint(x: stemX, y: -stemRise))
            path.addLine(to: CGPoint(x: stemX, y: kind == .last ? midY : height))
            path.move(to: CGPoint(x: stemX, y: midY))
            path.addLine(to: CGPoint(x: width - 3, y: midY))
        }
        .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        .frame(width: width, height: height)
    }
}

/// One agent, as a pill that hugs its text: who, where they are, what state, how long — and, on a
/// live Director, the ■ that stops that build. A record's worth of `SZLanePill`: the ticking clock
/// and the pulsing badge are the only parts that need the run itself.
struct SZStripLane: View {
    let model: SZLaneModel
    var onOpen: (() -> Void)?
    var onStop: (() -> Void)?

    private var isLive: Bool { model.run.isLive }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            SZLanePill(
                symbol: model.symbol, name: model.name, phase: model.phase,
                tint: model.tint, isLive: isLive,
                clock: model.run.endedAt
                    .map { SZTurnBreakdown.format($0.timeIntervalSince(model.run.startedAt)) }
                    ?? SZAgentGraphClock.stopwatch(context.date.timeIntervalSince(model.run.startedAt)),
                onOpen: onOpen, onStop: onStop, rowHeight: SZLaneMetrics.rowHeight
            ) {
                if isLive {
                    SZPulsingOpacity(range: 0.35...1, halfPeriod: SZPulse.period / 2) {
                        SZRunBadge.running()
                    }
                } else {
                    SZRunBadge.forConclusion(model.run.conclusion)
                }
            }
        }
    }
}

/// THE lane, driven by plain values instead of a record.
///
/// A build is a state while it runs and a receipt once it is over, and this is what makes those
/// one object rather than two look-alikes: the strip wraps it in a clock (`SZStripLane`), and a
/// finished build's turn in the transcript renders the same pill with a fixed one
/// (`SZChatReceiptRow`). Colour rides as a wash, not an outline: at four lanes an outline each was
/// the loudest thing in the panel.
struct SZLanePill<Badge: View>: View {
    let symbol: String
    let name: String
    var phase: String?
    let tint: Color
    /// Live lanes wear their agent's tint; a settled one goes to the neutral wash. Also what the
    /// hover states are scaled against.
    let isLive: Bool
    let clock: String
    var onOpen: (() -> Void)?
    var onStop: (() -> Void)?
    /// The height the lane OCCUPIES, when that is more than the pill it draws. A strip row is
    /// taller than its pill and the difference is the gap `SZLaneConnector` draws through — and
    /// that band is part of the lane: at `groupGap == 0` the rows tile the strip contiguously, so
    /// the hover wash hands straight from one lane to the next and a click between two pills still
    /// opens a run. It has to be applied HERE, before `contentShape`, or the interaction area is
    /// the bare pill and the band becomes a 3pt dead zone that makes the wash flicker as you drag
    /// down a group. nil = take the pill flush, which is what a receipt in the transcript wants:
    /// no connector, no neighbours, nothing to tile with.
    var rowHeight: CGFloat?
    @ViewBuilder let badge: () -> Badge
    @State private var hover = false

    /// No `onOpen` means the pill is a readout. It must not light up under the cursor either —
    /// hover feedback on something that does nothing is a promise the row cannot keep.
    private var interactive: Bool { onOpen != nil }
    private var lit: Bool { hover && interactive }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 8))
                .foregroundStyle(isLive ? tint : Color.secondary)
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let phase {
                Text(phase)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            // State, then how long it has been in it, then the control: the badge is what you
            // read first, and the clock qualifies it.
            badge()
            Text(clock)
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.secondary)
                // Beside a pulsing badge: swap the string, never cross-fade it.
                .contentTransition(.identity)
            if let onStop {
                SZLaneActionButton(symbol: "stop.fill",
                                   help: "Stop this build. The others keep going",
                                   action: onStop)
            }
        }
        .padding(.leading, SZLaneMetrics.padH)
        .padding(.trailing, onStop == nil ? SZLaneMetrics.padH : 3)
        .frame(height: SZLaneMetrics.pillHeight)
        .background(RoundedRectangle(cornerRadius: SZLaneMetrics.radius)
            .fill(isLive ? tint.opacity(lit ? 0.20 : 0.14)
                         : Color.white.opacity(lit ? 0.075 : 0.04)))
        .frame(height: rowHeight ?? SZLaneMetrics.pillHeight)
        // Tap gesture, not a Button: the ■ inside is its own button and the two must not nest.
        .contentShape(Rectangle())
        .onTapGesture { onOpen?() }
        .trackingHover($hover)
        .help(interactive ? "Open this run in the Agent Graph" : "")
    }
}

/// The strip's small trailing control — a lane's ■, a scheduled row's ✕. One size for both, with a
/// real hit target and hover state.
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
