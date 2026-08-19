// SPDX-License-Identifier: AGPL-3.0-only
// The run's presence in the transcript, pinned between the messages and the composer while a run is
// in flight. It exists because a run outlives the Director's own turn: the graph's dispatch node
// waits on the fleet, so the Director's turn finishes ("Worked for 24s") and its tab dot goes out
// while the build is still very much running. Until this, the only surviving cue was the Stop.
//
// It shows the SAME sub-agent lanes the Agent Graph draws under a dispatch card
// (`SZAgentSubagentLane`, reused verbatim) — who is working, the node they are on right now, their
// clock, and the pulsing live badge — so the two surfaces are one picture at two zoom levels.
// Every lane is a door into that agent's own run.
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
    /// They sit under the live lanes because that is the order they will happen in.
    var scheduled: [SZScheduledRow] = []
    /// Drop a scheduled task (its ✕). nil = the surface isn't wired; the rows are a readout.
    var onCancelScheduled: ((UUID) -> Void)?
    /// Interrupt ONE live traversal by its thread — the running counterpart of a scheduled row's ✕,
    /// and the only control that stops a single build. The HUD's Stop is deliberately the other
    /// scope: everything in flight.
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
            Divider().overlay(Color.white.opacity(0.08))
            VStack(spacing: SZAgentGraphLayout.laneGap) {
                ForEach(shownThreads, id: \.self) { thread in threadGroup(thread) }
                if hiddenThreads > 0 { overflowLine("+\(hiddenThreads) more running") }
                ForEach(shownScheduled) { row in scheduledRow(row) }
                if hiddenScheduled > 0 { overflowLine("+\(hiddenScheduled) more queued") }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    /// One build: the Director's own traversal, then the fleet hanging off it. The children are
    /// indented because with several builds in flight the grouping is the whole point — which
    /// agents belong to which ask.
    @ViewBuilder
    private func threadGroup(_ thread: UUID) -> some View {
        let leader = runs.first { $0.id == thread }
        let lanes = SZAgentGraphRun.workChildren(thread: thread, in: runs)
        VStack(spacing: SZAgentGraphLayout.laneGap) {
            if let leader {
                HStack(spacing: 5) {
                    SZAgentSubagentLane(run: leader, title: "Director",
                                        symbol: "eyeglasses", tint: SZEdgeStyle.intentViolet,
                                        action: { onOpen?(leader.id) })
                    if leader.isLive, let onStopRun {
                        // This traversal only. Stopping one build must not end the others,
                        // which is the whole reason runs are scoped.
                        SZLaneActionButton(symbol: "stop.fill",
                                           help: "Stop this build — the others keep going") {
                            onStopRun(leader.thread ?? leader.id)
                        }
                    }
                }
                .frame(height: SZAgentGraphLayout.laneHeight)
            }
            if lanes.isEmpty {
                if leader == nil { waitingLine(thread: thread) }
            } else {
                ForEach(lanes.prefix(Self.laneCap)) { run in
                    SZAgentSubagentLane(run: run,
                                        title: run.work.flatMap(title),
                                        action: { onOpen?(run.id) })
                        .frame(height: SZAgentGraphLayout.laneHeight)
                        .padding(.leading, leader == nil ? 0 : 12)
                }
                if lanes.count > Self.laneCap {
                    overflowLine("+\(lanes.count - Self.laneCap) more")
                        .padding(.leading, leader == nil ? 0 : 12)
                }
            }
        }
    }

    private func overflowLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One scheduled task: what was asked, and why it has not started. Deliberately quieter than
    /// a live lane — it is waiting, not working — with a ✕ because an ask you changed your mind
    /// about should cost nothing to drop.
    private func scheduledRow(_ row: SZScheduledRow) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)
            Text(row.title)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if let waiting = row.waitingOn {
                Text("· behind \(waiting)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let onCancelScheduled {
                SZLaneActionButton(symbol: "xmark", help: "Drop this scheduled task") {
                    onCancelScheduled(row.id)
                }
            }
        }
        .frame(height: SZAgentGraphLayout.laneHeight)
    }

    /// Before the fleet goes out — the Director is deciding, and the run is still the thing in
    /// flight. Quiet by design: the Director's own turn is already streaming in the transcript
    /// right above, and this must not shout over it.
    private func waitingLine(thread: UUID) -> some View {
        HStack(spacing: 6) {
            // The same dot as a working tab (SZChatPanel.tabActivityDot), cadence included, so the
            // strip and the tab strip read as one state rather than two opinions.
            SZPulsingOpacity(range: 0.35...0.95, halfPeriod: 0.79) {
                Circle().fill(SZNodeStatus.building.color).frame(width: 4.5, height: 4.5)
            }
            Text("graph running")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .frame(height: SZAgentGraphLayout.laneHeight)
        .contentShape(Rectangle())
        .onTapGesture { onOpen?(thread) }
        .help("Open this run in the Agent Graph")
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


/// The strip's small trailing control — a lane's ■, a scheduled row's ✕. It reads as a button: a
/// hit target you can land on, and a hover state, rather than a bare tinted glyph floating beside
/// the row (which read as an orange rectangle nobody could name).
private struct SZLaneActionButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hover ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white.opacity(hover ? 0.14 : 0.06)))
        }
        .buttonStyle(.plain)
        .trackingHover($hover)
        .help(help)
    }
}
