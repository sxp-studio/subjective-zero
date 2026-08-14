// SPDX-License-Identifier: AGPL-3.0-only
// The Agent Graph panel's RUNS section: every recorded traversal, grouped BY THREAD — one
// Build press and everything it caused reads as one entry with its traversals nested under
// it, instead of confetti (a build traversal, N item traversals, and a settled re-entry are
// one conversation, and the list should say so). Standalone traversals (records carrying no
// thread) stay plain rows.
//
// Its metrics are the Profiler's session list verbatim, because it is the same idea: an
// accumulating list of executions beside the detail of the selected one. Deliberately NOT
// sharing a row primitive with it — the chrome the two have in common is about ten lines
// against two unrelated bodies.
//
// Content-only on purpose (no ScrollView of its own): the panel's sidebar owns the one
// scroll, with the agent tree above this section.
import SwiftUI
import SZCore

/// What a record is CALLED, resolved against the live pack library. The record itself
/// denormalizes no display facts (see `SZAgentGraphRunRow.glyph`), so a row that wants to
/// say "Director · Agentic" joins back through the same `planAgents` the Plan view browses
/// — the join `agentGraphResolve` already does host-side, done here where the agents are.
///
/// A value rather than closures so the rule is constructible in tests. Both lookups degrade
/// to the raw string: an agent the library dropped reads as its pack id, a graph with no
/// authored `label` as its file stem — the same honesty the canvas shows a vanished pack.
struct SZAgentGraphNaming: Equatable {
    var agents: [SZAgentGraphPlanAgent]

    /// The traversing agent's display name — "Director", not "director".
    func agentTitle(_ run: SZAgentGraphRun) -> String {
        agents.first { $0.id == run.agent }?.title ?? run.agent
    }

    /// The traversed graph's authored label — "Agentic", "Implement one node".
    func graphLabel(_ run: SZAgentGraphRun) -> String {
        agents.first { $0.id == run.agent }?
            .graphs.first { $0.name == run.graphName }?
            .graph.label ?? run.graphName
    }
}

/// The RUNS section: thread groups and standalone traversals, the live one first (see
/// `SZAgentGraphRun.ordered`).
struct SZAgentGraphRunList: View {
    let runs: [SZAgentGraphRun]
    let names: SZAgentGraphNaming
    /// The record the canvas is drawing — which row reads as selected. nil = the Plan view
    /// has the canvas, and no run row should claim selection.
    let shownID: UUID?
    let onPick: (SZAgentGraphRun) -> Void

    /// Which threads are OPEN — collapsed by default: a thread reads as ONE run (its header
    /// carries the state that matters) until its traversals are asked for.
    @State private var expandedThreads: Set<String> = []

    /// One list entry: a THREAD (≥1 traversals sharing a thread id) or a standalone
    /// traversal. Grouped by first appearance so the ordering rule (live first, then
    /// newest) keeps deciding placement.
    private struct Entry: Identifiable {
        var id: String
        var traversals: [SZAgentGraphRun]
        var isThread: Bool { traversals.count > 1 || traversals.first?.thread != nil }
    }

    private var entries: [Entry] {
        var out: [Entry] = []
        var index: [UUID: Int] = [:]
        for run in runs {
            if let thread = run.thread {
                if let i = index[thread] {
                    out[i].traversals.append(run)
                } else {
                    index[thread] = out.count
                    out.append(Entry(id: thread.uuidString, traversals: [run]))
                }
            } else {
                out.append(Entry(id: run.id.uuidString, traversals: [run]))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entries) { entry in
                if entry.isThread {
                    threadHeader(entry, expanded: expandedThreads.contains(entry.id),
                                 selected: entry.traversals.contains { $0.id == shownID })
                    if expandedThreads.contains(entry.id) {
                        ForEach(entry.traversals) { traversal in
                            SZAgentGraphRunRow(run: traversal, names: names,
                                               selected: traversal.id == shownID,
                                               indented: true) { onPick(traversal) }
                        }
                    }
                } else if let traversal = entry.traversals.first {
                    SZAgentGraphRunRow(run: traversal, names: names,
                                       selected: traversal.id == shownID,
                                       indented: false) { onPick(traversal) }
                }
            }
        }
    }

    /// The thread's own line: the run graph it traversed, its span, and how the
    /// conversation stands — live while anything in it still traverses, else the deciding
    /// traversal's ending. Clicking it shows that deciding traversal.
    @ViewBuilder private func threadHeader(_ entry: Entry, expanded: Bool,
                                           selected: Bool) -> some View {
        // The DECIDING traversal: the newest build-kind traversal — the list is ordered
        // newest-first, so `first` is the traversal that concluded (or is concluding) the
        // thread. Its ending is the thread's ending; a declined or failed decider must wear
        // its badge HERE, where the collapsed default shows it.
        // NOT the build traversal: that one ended the moment it dispatched. The thread's
        // verdict belongs to the newest DIRECTOR traversal — a settled re-entry, when the
        // fleet came back and the graph ruled on what it found.
        let director = entry.traversals.first { $0.kind != .work } ?? entry.traversals[0]
        let live = entry.traversals.contains(where: \.isLive)
        let began = entry.traversals.map(\.startedAt).min() ?? director.startedAt
        let ended = entry.traversals.compactMap(\.endedAt).max()
        // Chevron and row are SIBLINGS (the agent tree's shape) — nested buttons resolve by
        // SwiftUI-version grace, siblings by construction.
        HStack(alignment: .top, spacing: 0) {
            Button {
                if expanded { expandedThreads.remove(entry.id) }
                else { expandedThreads.insert(entry.id) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 14, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                onPick(entry.traversals.first(where: \.isLive) ?? director)
            } label: {
                HStack(alignment: .top, spacing: 5) {
                    // The member rows' selection rail, worn by the header while its
                    // traversals are folded away — without it a collapsed thread shows a
                    // canvas the sidebar seems not to contain.
                    Capsule()
                        .fill(selected && !expanded ? SZChatPanel.directorColor.opacity(0.8) : .clear)
                        .frame(width: 2)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Image(systemName: SZAgentGraphRunRow.glyph(for: director))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                // WHO, not which file: the agent leads the row and the
                                // graph it traversed rides the line below. A name is not
                                // an identifier, so it is not set in monospace.
                                Text(names.agentTitle(director))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("· \(entry.traversals.count)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Spacer(minLength: 0)
                                if !live, let ended {
                                    Text(SZAgentGraphClock.age(context.date.timeIntervalSince(ended)))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            HStack(spacing: 5) {
                                Text(names.graphLabel(director) + " ·")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                Text(live || ended == nil
                                    ? SZAgentGraphClock.stopwatch(context.date.timeIntervalSince(began))
                                    : SZTurnBreakdown.format(ended!.timeIntervalSince(began)))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .contentTransition(.identity)
                                if live {
                                    SZPulsingOpacity(range: 0.35...1, halfPeriod: SZPulse.period / 2) {
                                        SZRunBadge(label: "live", colour: SZAgentGraphStyle.live)
                                    }
                                } else {
                                    // The thread's ending is its deciding traversal's —
                                    // declined and stopped stay visible at thread level.
                                    SZRunBadge.forConclusion(director.conclusion)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .padding(.vertical, 5).padding(.trailing, 8)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(selected && !expanded ? 0.06 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .help("One build — \(entry.traversals.count) traversals · started "
              + began.formatted(date: .abbreviated, time: .standard))
    }
}

/// Which run the canvas draws. Pure so the rule can be tested without a panel: an explicit
/// pick wins while that run still exists, and a pick that has aged out of the capped list
/// falls back to the head — the same discipline the Profiler's session list follows.
enum SZAgentGraphRunSelection {
    static func select(_ runs: [SZAgentGraphRun], id: UUID?) -> SZAgentGraphRun? {
        runs.first { $0.id == id } ?? runs.first
    }
}

/// The ending capsule, shared by traversal rows and thread headers so a conversation and
/// the traversal that concluded it agree on their colours.
struct SZRunBadge: View {
    let label: String
    let colour: Color

    var body: some View {
        Text(label)
            .font(.system(size: 7, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 3)
            .padding(.vertical, 0.5)
            .background(Capsule().fill(colour))
    }

    @ViewBuilder static func forConclusion(_ conclusion: SZAgentGraphRun.Conclusion?) -> some View {
        switch conclusion {
        case .failed, .defect: SZRunBadge(label: "failed", colour: SZAgentGraphStyle.failed)
        case .cancelled:       SZRunBadge(label: "stopped", colour: SZAgentGraphStyle.neutral)
        case .declined:        SZRunBadge(label: "declined", colour: SZAgentGraphStyle.neutral)
        // A record sealed without a conclusion cannot happen through the host's seal; drawn
        // as a plain ending rather than left blank. The SAME blue the canvas gives a clean
        // exit — a list badge and the terminal capsule are two views of one fact.
        case .ended, .none:    SZRunBadge(label: "end", colour: SZAgentGraphStyle.ended)
        }
    }
}

/// One traversal row — `SZSessionRow`'s anatomy (accent rail, row-local hover, a ticking
/// relative age, the absolute clock in the tooltip) over a run record: which graph was
/// traversed on which kind, how long it took, and how it ended. `indented` = a thread
/// member, nested under its header.
struct SZAgentGraphRunRow: View {
    let run: SZAgentGraphRun
    let names: SZAgentGraphNaming
    let selected: Bool
    var indented = false
    let action: () -> Void
    @State private var hovered = false

    /// The record's kind as a glyph — the record deliberately denormalizes no display
    /// facts, so the row draws what it carries: what KIND of traversal this was.
    static func glyph(for run: SZAgentGraphRun) -> String {
        switch run.kind {
        case .build: "play.circle"
        case .work: "wrench.and.screwdriver"
        case .chat: "bubble.left"
        case .request: "envelope"
        case .steer: "arrow.triangle.turn.up.right.diamond"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 7) {
                Capsule()
                    .fill(selected ? SZChatPanel.directorColor.opacity(0.8) : .clear)
                    .frame(width: 2)
                // ONE clock for the row: the relative age and a live run's growing wall
                // time both read it, so a row re-lays out once a tick rather than twice.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        // WHAT was traversed, and how long ago it ended.
                        HStack(spacing: 5) {
                            Image(systemName: Self.glyph(for: run))
                                .font(.system(size: 9))
                                .foregroundStyle(selected ? .primary : .secondary)
                            Text(names.agentTitle(run))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(selected ? .primary : .secondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            // A live run has no "ago" — its pulse and its growing wall time
                            // say where it is.
                            if let ended = run.endedAt {
                                Text(SZAgentGraphClock.age(context.date.timeIntervalSince(ended)))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        HStack(spacing: 5) {
                            // WHAT it traversed, demoted off the title line — the authored
                            // label ("Node chat"), not the file stem the tooltip keeps.
                            Text(names.graphLabel(run) + " ·")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            // Ticking while it traverses, measured once it has ended — the
                            // row's clock and its cards' clocks read in the same units.
                            Text(run.endedAt.map { SZTurnBreakdown.format($0.timeIntervalSince(run.startedAt)) }
                                ?? SZAgentGraphClock.stopwatch(context.date.timeIntervalSince(run.startedAt)))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                // Beside a pulsing badge — same cross-fade hazard as the
                                // card's clock: swap the string, don't dissolve it.
                                .contentTransition(.identity)
                            badge
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(selected ? 0.06 : (hovered ? 0.035 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .padding(.leading, indented ? 16 : 4)
        .padding(.trailing, 4)
        // The absolute clock (and an item's work-node id) live in the hover tooltip — the
        // row itself stays relative. The raw pack id and graph STEM live here too, so the
        // strings the row displays as names stay reachable in their authored spelling.
        .help("\(run.agent)/\(run.graphName) · \(run.kind.rawValue)"
              + (run.work.map { " · \($0.prefix(8))" } ?? "")
              + " · \(run.startedAt.formatted(date: .abbreviated, time: .standard))")
    }

    /// How it ended, in the canvas terminal's own words and colours — or a pulse while it
    /// traverses.
    @ViewBuilder private var badge: some View {
        if run.isLive {
            SZPulsingOpacity(range: 0.35...1, halfPeriod: SZPulse.period / 2) {
                SZRunBadge(label: "live", colour: SZAgentGraphStyle.live)
            }
        } else {
            SZRunBadge.forConclusion(run.conclusion)
        }
    }
}
