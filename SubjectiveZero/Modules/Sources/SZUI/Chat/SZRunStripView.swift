// SPDX-License-Identifier: AGPL-3.0-only
// The builds' presence in the transcript, pinned between the messages and the composer.
//
// - A run outlives the Director's turn (dispatch waits on the fleet), so without this the only
//   surviving cue that anything was happening was the Stop.
// - One group per live build: the Director's lane, its coding agents under it on a drawn
//   connector. Live children first — the cap must never hide the agents actually working.
// - Past the cap the rest fold into ONE line that OPENS, so the strip stays short by default and
//   the whole fleet is a click away. `SZStripPlan` lays the band out in one pass, spending a row
//   budget read off the PANEL, not one per group.
// - The ■ on a live Director lane stops THAT build; it is the only per-build stop.
// - Lanes are the strip's own, not the canvas's `SZAgentSubagentLane` (which fills its card's
//   width by design). Shared instead: `SZRunBadge`, one word per state.
// - Deliberately OUTSIDE the transcript's ScrollView — a run is state, not a message, so it must
//   not enter the LazyVStack the bottom-pin anchor drives. Growing the band shrinks that viewport,
//   so it reports through `onLayoutChange` and the panel re-pins.
// - Presence, not a lock: the composer stays live and a send simply queues.
import SwiftUI
import SZCore

/// What the strip draws, in order: which rows survive the caps, where the elbow stops, and which
/// line folds the rest away. Pure, so the truncation rules are testable without a host.
struct SZStripPlan {
    enum Group: Hashable {
        case thread(UUID)   // one build's coding agents
        case running        // builds past the cap
        case queued         // tasks waiting past the cap

        var key: String {
            switch self {
            case .thread(let id): "thread-\(id)"
            case .running: "running"
            case .queued: "queued"
            }
        }
    }

    /// The line that stands in for what is folded away, and the way back to it. Always its group's
    /// LAST row: the band grows upward from the composer, so revealing ABOVE the line is what leaves
    /// it under the cursor that clicked it.
    struct Toggle {
        let group: Group
        let open: Bool
        /// What is not on screen: folded away by the cap while closed, or past the budget while open.
        let hidden: Int
        /// The elbow, when the group hangs off a Director; nil at the strip's top level.
        let connector: SZLaneConnector.Kind?

        var label: String {
            guard open else {
                switch group {
                case .thread: return "+\(hidden) more"
                case .running: return "+\(hidden) more running"
                case .queued: return "+\(hidden) more queued"
                }
            }
            return hidden > 0 ? "show less · \(hidden) not shown" : "show less"
        }

        var help: String {
            switch (group, open) {
            case (.thread, false): "Show every agent on this build"
            case (.running, false): "Show every build running"
            case (.queued, false): "Show everything queued"
            default: "Show fewer"
            }
        }
    }

    /// One line of the band. A Director and a coding agent are the same pill, but only one of them
    /// wears an elbow.
    enum Row: Identifiable {
        case director(SZAgentGraphRun)
        case lane(SZAgentGraphRun, SZLaneConnector.Kind)
        case waiting(UUID)
        case scheduled(SZScheduledRow)
        case toggle(Toggle)

        var id: String {
            switch self {
            case .director(let run): "d-\(run.id)"
            case .lane(let run, _): "l-\(run.id)"
            case .waiting(let thread): "w-\(thread)"
            case .scheduled(let row): "s-\(row.id)"
            case .toggle(let toggle): "t-\(toggle.group.key)"
            }
        }
    }

    /// Past these the strip would own more of the panel than the conversation does. Both cap the
    /// CLOSED band only: opening a group spends the budget instead.
    static let threadCap = 3
    static let laneCap = 3

    /// Rows an expansion may ADD to the closed band: two fifths of the panel, so an open group
    /// cannot crowd out a short window. Whole rows, so a resize drag does not write state per pixel.
    static func budget(panelHeight: CGFloat) -> Int {
        let usable = panelHeight.isFinite ? max(0, panelHeight) : 0
        return max(3, Int(usable * 0.4 / SZLaneMetrics.rowHeight))
    }

    /// - Parameter extraBudget: rows the expansions may add across the WHOLE strip. Per group would
    ///   bound nothing, since three open groups would still stack past the panel.
    static func rows(threads: [UUID], runs: [SZAgentGraphRun], scheduled: [SZScheduledRow],
                     expanded: Set<Group>, extraBudget: Int) -> [Row] {
        var rows: [Row] = []
        var pool = max(0, extraBudget)
        var openGroups = expanded.count { hidden(in: $0, threads: threads, runs: runs,
                                                 scheduled: scheduled) > 0 }
        /// An equal share of what is left, and never less than one row while any is: a fold that
        /// opens onto nothing is the dead end this line exists to remove.
        func share(of want: Int) -> Int {
            guard want > 0, openGroups > 0, pool > 0 else { return 0 }
            let spent = min(want, max(1, pool / openGroups))
            pool -= spent
            openGroups -= 1
            return spent
        }

        for thread in threads.prefix(threadCap) {
            rows += group(thread: thread, runs: runs, expanded: expanded, share: share)
        }
        if threads.count > threadCap {
            let extras = Array(threads.dropFirst(threadCap))
            // Whole builds only: half a group reads as a defect, not as a budget.
            var admitted: [[Row]] = []
            var allowance = expanded.contains(.running)
                ? share(of: extras.reduce(0) { $0 + closedRowCount(thread: $1, runs: runs) })
                : 0
            for thread in extras {
                let cost = closedRowCount(thread: thread, runs: runs)
                guard cost <= allowance else { break }
                allowance -= cost
                admitted.append(group(thread: thread, runs: runs, expanded: expanded,
                                      share: { _ in 0 }))
            }
            rows += admitted.flatMap { $0 }
            rows.append(.toggle(Toggle(group: .running, open: expanded.contains(.running),
                                       hidden: extras.count - admitted.count, connector: nil)))
        }

        // The asks that survived being second. They sit under the live groups because that is the
        // order they will happen in.
        let base = min(scheduled.count, laneCap)
        let granted = expanded.contains(.queued) ? share(of: scheduled.count - base) : 0
        rows += scheduled.prefix(base + granted).map(Row.scheduled)
        if scheduled.count > laneCap {
            rows.append(.toggle(Toggle(group: .queued, open: expanded.contains(.queued),
                                       hidden: scheduled.count - base - granted, connector: nil)))
        }
        return rows
    }

    /// What a group folds away while closed: the share-out and the key pruning both read it.
    static func hidden(in group: Group, threads: [UUID], runs: [SZAgentGraphRun],
                       scheduled: [SZScheduledRow]) -> Int {
        switch group {
        case .thread(let id):
            max(0, SZAgentGraphRun.workChildren(thread: id, in: runs).count - laneCap)
        case .running: max(0, threads.count - threadCap)
        case .queued: max(0, scheduled.count - laneCap)
        }
    }

    /// One build: the Director's traversal, then its fleet on a connector, then the fold line.
    private static func group(thread: UUID, runs: [SZAgentGraphRun], expanded: Set<Group>,
                              share: (Int) -> Int) -> [Row] {
        let leader = runs.first { $0.id == thread }
        let children = SZAgentGraphRun.workChildren(thread: thread, in: runs)
        let base = min(children.count, laneCap)
        let open = expanded.contains(.thread(thread))
        let granted = open ? share(children.count - base) : 0
        let hidden = children.count - base - granted
        // Live first whenever ANY are folded away, open or closed: the fold must never hide the
        // agents actually working. Showing all of them keeps dispatch order, which stops the pills
        // reshuffling as agents settle.
        let ordered = hidden > 0 ? children.filter(\.isLive) + children.filter { !$0.isLive }
                                 : children
        let lanes = Array(ordered.prefix(base + granted))
        let folds = children.count > laneCap

        var rows: [Row] = []
        if let leader {
            rows.append(.director(leader))
        } else if lanes.isEmpty {
            rows.append(.waiting(thread))
        }
        for (offset, run) in lanes.enumerated() {
            rows.append(.lane(run, !folds && offset == lanes.count - 1 ? .last : .middle))
        }
        if folds {
            rows.append(.toggle(Toggle(group: .thread(thread), open: open, hidden: hidden,
                                       connector: .last)))
        }
        return rows
    }

    /// The rows a build takes while folded — what admitting one more of them costs.
    private static func closedRowCount(thread: UUID, runs: [SZAgentGraphRun]) -> Int {
        let children = SZAgentGraphRun.workChildren(thread: thread, in: runs).count
        let leader = runs.contains { $0.id == thread }
        return (leader || children == 0 ? 1 : 0) + min(children, laneCap) + (children > laneCap ? 1 : 0)
    }
}

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
    var scheduled: [SZScheduledRow] = []
    /// Drop a scheduled task (its ✕). nil = the surface isn't wired; the rows are a readout.
    var onCancelScheduled: ((UUID) -> Void)?
    /// Interrupt ONE live traversal by its thread — the running counterpart of a scheduled row's ✕,
    /// and the only control that stops a single build.
    var onStopRun: ((UUID) -> Void)?
    /// Rows an expansion may add, from `SZStripPlan.budget`. The floor stands in until the panel
    /// has been measured.
    var extraBudget: Int = 3
    /// Fired whenever the band gains or loses a row, by a click or by the fleet. Each one resizes
    /// the transcript above, and nothing else re-pins it.
    var onLayoutChange: (() -> Void)?

    /// Which groups are OPEN. Closed by default, and the set dies with the strip, so every build
    /// starts folded. Thread ids are never reused, so a leftover key cannot open a future group.
    @State private var expanded: Set<SZStripPlan.Group> = []

    var body: some View {
        let rows = SZStripPlan.rows(threads: threads, runs: runs, scheduled: scheduled,
                                    expanded: expanded, extraBudget: extraBudget)
        VStack(spacing: 0) {
            // No rule above it. A hairline said "another section starts here", but the strip is
            // not a section — it is the same conversation's state, and the pills already read as
            // objects rather than prose. What separates it is the same 10pt the composer keeps
            // below it, so the three bands of the panel breathe evenly.
            VStack(alignment: .leading, spacing: SZLaneMetrics.groupGap) {
                ForEach(rows) { row($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
        // A dispatched agent grows an open group the way a click does, so follow the row COUNT.
        .onChange(of: rows.count) { onLayoutChange?() }
        // A fold with nothing behind it must not reopen itself when the next build overflows.
        .onChange(of: threads.count) { prune() }
        .onChange(of: scheduled.count) { prune() }
    }

    private func prune() {
        for group in [SZStripPlan.Group.running, .queued]
        where expanded.contains(group) && SZStripPlan.hidden(in: group, threads: threads,
                                                             runs: runs, scheduled: scheduled) == 0 {
            expanded.remove(group)
        }
    }

    @ViewBuilder
    private func row(_ row: SZStripPlan.Row) -> some View {
        switch row {
        case .director(let run):
            laneRow(SZLaneModel(run: run, name: "Director", symbol: "eyeglasses",
                                tint: SZEdgeStyle.intentViolet),
                    stop: run.isLive
                        ? onStopRun.map { stop in { stop(run.thread ?? run.id) } }
                        : nil)
        case .lane(let run, let connector):
            laneRow(SZLaneModel(run: run, name: run.work.flatMap(title) ?? "work",
                                symbol: "hammer", tint: SZAgentGraphStyle.running),
                    connector: connector)
        case .waiting(let thread):
            waitingLine(thread: thread)
        case .scheduled(let task):
            scheduledRow(task)
        case .toggle(let toggle):
            SZStripToggleRow(toggle: toggle) {
                // The band changing height is the one motion here worth showing: it moves the
                // conversation above it, and a jump reads as a glitch rather than as a fold.
                withAnimation(.easeOut(duration: SZLaneMetrics.foldDuration)) {
                    if expanded.contains(toggle.group) { expanded.remove(toggle.group) }
                    else { expanded.insert(toggle.group) }
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

/// The line that folds a group away, and opens it again. A real Button, unlike a lane: nothing
/// nests inside it, so there is no pair of buttons to resolve.
private struct SZStripToggleRow: View {
    let toggle: SZStripPlan.Toggle
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            if let connector = toggle.connector { SZLaneConnector(kind: connector) }
            Button(action: action) {
                HStack(spacing: 4) {
                    // Open points UP, at the rows it folds away: the band grows upward from the
                    // composer, so what this line reveals sits above it, not below.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                        .rotationEffect(.degrees(toggle.open ? -90 : 0))
                    Text(toggle.label)
                        .font(.system(size: 9, design: .monospaced))
                }
                .foregroundStyle(hover ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                // A pill like everything else in this band, quieter. Bare text read as a caption
                // and gave the pointer nothing to aim at: you cannot see where a caption ends.
                .padding(.horizontal, SZLaneMetrics.padH)
                .frame(height: SZLaneMetrics.pillHeight)
                .background(RoundedRectangle(cornerRadius: SZLaneMetrics.radius)
                    .fill(Color.white.opacity(hover ? 0.075 : 0.03)))
                .frame(height: SZLaneMetrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .trackingHover($hover)
            .help(toggle.help)
            Spacer(minLength: 0)
        }
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
    /// How long the band takes to fold or open. The transcript above re-pins on the same curve, so
    /// the two move together instead of the message drifting while the strip settles.
    static let foldDuration: Double = 0.16
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
                    SZRunBadge.forRun(model.run)
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
