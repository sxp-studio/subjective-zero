// SPDX-License-Identifier: AGPL-3.0-only
// The per-turn debug breakdown disclosure under chat replies, and its shared pieces: the
// mini timeline bar (also the Profiler's detail-row bar) and the caption action buttons.
// Split from SZChatPanel.swift purely for size — same idiom, same palette.
import AppKit
import SwiftUI
import SZCore

/// The per-turn debug breakdown (Debug ▸ Show Turn Breakdown): the "Worked for …" caption becomes a
/// disclosure over the phases the host recorded for the turn (queue wait, first output, tool spans,
/// compile/promote, the CLI's own numbers). On the Director's run-complete narration (`caption:
/// nil`) the caption is derived from the rollup's `run.total` row — "Ran for 50s · 458k in / …" —
/// so turn and run disclosures read as the same idiom at their two levels. Rows are selectable and
/// a copy button (expanded state) puts the whole breakdown on the pasteboard as plain text. Row
/// identity is the message id (ForEach in the panel), so `expanded` survives re-renders.
struct SZTurnBreakdownView: View {
    /// The row's already-composed "Worked for …" line (the row renders the same string plain when
    /// breakdowns are hidden, and it carries the Show Token Counts choice — recomposing it here
    /// would duplicate that). nil = the run-rollup case: derived from the `run.total` row instead.
    let turnCaption: String?
    let events: [SZTurnEvent]
    /// The Profiler record this breakdown belongs to (the runID for run-owned data, else the
    /// message id) — a VALUE, so the row's Equatable render skip survives; the action arrives
    /// via the environment and renders only where the Profiler surface exists.
    let profilerTarget: UUID
    /// The turn's own message id — the prompt-inspection key (distinct from `profilerTarget`,
    /// which resolves run-owned turns to their run).
    let turnID: UUID
    @Environment(\.szRevealInProfiler) private var revealInProfiler
    @Environment(\.szViewTurnPrompt) private var viewTurnPrompt
    @Environment(\.szHeldPromptTurnIDs) private var heldPromptTurnIDs
    @State private var expanded = false
    @State private var captionHovered = false

    /// One shape for every expanded action: an 8pt icon whose word appears on hover (plus the
    /// tooltip) — at rest the row stays glyphs-only quiet.
    private func captionAction(_ label: String, icon: String, help: String,
                               action: @escaping () -> Void) -> some View {
        SZCaptionActionButton(label: label, icon: icon, help: help, action: action)
    }

    private var runTotal: SZTurnEvent? { events.last { $0.stage == SZTurnStage.runTotal } }
    private var effectiveCaption: String {
        if let turnCaption { return turnCaption }
        guard let total = runTotal else { return "Run breakdown" }
        let head = total.duration.map { "Ran for \(SZTurnBreakdown.format($0))" } ?? "Run breakdown"
        return total.detail.map { "\(head) · \($0)" } ?? head
    }
    /// Rollup rows render as a hierarchy: the `run.total` row leads spanning the whole track, its
    /// children (director turns, node fleets) sorted by start beneath it. Sorted at RENDER, not
    /// just at fold, so rollups persisted by older builds read correctly too.
    private var rows: [SZTurnEvent] {
        guard turnCaption == nil else { return events }
        var sorted = events.filter { $0.stage != SZTurnStage.runTotal }.sorted { $0.start < $1.start }
        if let total = runTotal { sorted.insert(total, at: 0) }
        return sorted
    }
    /// The rollup's time base for the mini timeline: the run's start + wall span. nil (turn case,
    /// or a degenerate span) hides the bar column.
    private var timelineBase: (start: Date, span: TimeInterval)? {
        guard turnCaption == nil, let total = runTotal, let span = total.duration, span > 0
        else { return nil }
        return (total.start, span)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(effectiveCaption)
                        // Points DOWN collapsed (the detail expands below), up once open — at the
                        // line's end a right-chevron reads as navigation, not disclosure.
                        Image(systemName: "chevron.down")
                            .font(.system(size: 6.5, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .foregroundStyle(captionHovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { captionHovered = $0 }
                // Collapsed = just the caption + chevron; the actions appear on expand — every
                // one an icon + word in the same style, never a row of mystery glyphs.
                if expanded {
                    captionAction("copy", icon: "doc.on.doc", help: "Copy breakdown") {
                        copyBreakdown()
                    }
                    // Prompt inspection — only while the host still HOLDS this turn's prompt, so
                    // it can never click into nothing.
                    if let viewTurnPrompt, turnCaption != nil, heldPromptTurnIDs.contains(turnID) {
                        captionAction("prompt", icon: "doc.text.magnifyingglass",
                                      help: "View the prompt this turn sent to its CLI (opens a temp file)") {
                            viewTurnPrompt(turnID)
                        }
                    }
                    // The "see more" link, spelled out — the Profiler is the detail view.
                    if let revealInProfiler {
                        captionAction("profiler", icon: "waveform.path.ecg", help: "Open in Profiler") {
                            revealInProfiler(profilerTarget)
                        }
                    }
                }
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.tertiary)
            if expanded {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                    // Offsets, not ids: two same-stage events (three compiles, repeated tool spans)
                    // are distinct rows, and the array is immutable once rendered.
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, event in
                        GridRow {
                            // Details fold INTO the name ("compile · ok"; a thinking row wears
                            // parentheses) — no fourth column to clip in a narrow chat panel,
                            // and thinking keeps full weight (it's usually the bottleneck).
                            titleText(for: event)
                                .lineLimit(1)
                            Text(event.duration.map(SZTurnBreakdown.format) ?? "")
                                .gridColumnAlignment(.trailing)
                            if let base = timelineBase {
                                // Where this row sat in the run — makes the parallel coding agents'
                                // overlap visible at a glance. Width is the row's summed time from
                                // its first start (exact for one turn; understates reconcile gaps).
                                SZTurnTimelineBar(
                                    offset: event.start.timeIntervalSince(base.start) / base.span,
                                    fraction: (event.duration ?? 0) / base.span,
                                    color: barColor(for: event))
                            }
                        }
                    }
                }
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }

    /// One SZCore-composed title for every surface (Profiler and text summaries render the same
    /// event identically); the depth prefix rides inside it.
    private func titleText(for event: SZTurnEvent) -> Text {
        Text(SZTurnBreakdown.rowTitle(for: event, in: events))
    }

    /// Timeline color-coding mirrors the transcript's semantic palette: Director violet, coding
    /// agents orange, everything else neutral.
    private func barColor(for event: SZTurnEvent) -> Color {
        switch event.stage {
        case SZTurnStage.runDirector: SZChatPanel.directorColor
        case SZTurnStage.runNode: SZChatPanel.agentColor
        case SZTurnStage.runTotal: Color.secondary.opacity(0.5)
        default: Color.secondary
        }
    }

    private func copyBreakdown() {
        var lines = [effectiveCaption]
        for event in rows {
            let duration = event.duration.map(SZTurnBreakdown.format) ?? ""
            // Details already live in the title ("compile · ok") — no third column to duplicate.
            lines.append("  " + [SZTurnBreakdown.rowTitle(for: event, in: rows), duration]
                .filter { !$0.isEmpty }.joined(separator: "  "))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

/// One row of the rollup's mini timeline: a shared full-run track (visible, so every bar reads as
/// a position on the same axis) with the row's span placed on it. Fixed-width (no GeometryReader —
/// it lives inside a Grid cell) and clamped so a row that started before/ran past the measured
/// window can't escape the track.
struct SZTurnTimelineBar: View {
    let offset: Double     // 0…1, the row's start within the run
    let fraction: Double   // 0…1, the row's share of the run's wall time
    let color: Color
    /// false → the bar floats with no gray track (the Profiler's detail rows — dozens of
    /// repeated tracks read as clutter; position still communicates).
    var showsTrack: Bool = true

    /// Internal: the Profiler's detail-section separator spans name + duration + this bar.
    static let width: CGFloat = 150

    var body: some View {
        let clampedOffset = min(max(offset, 0), 1)
        let clampedFraction = min(max(fraction, 0), 1 - clampedOffset)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.primary.opacity(showsTrack ? 0.10 : 0))
                .frame(width: Self.width, height: 3)
            RoundedRectangle(cornerRadius: 1.5).fill(color.opacity(0.9))
                .frame(width: max(3, Self.width * clampedFraction), height: 3)
                .offset(x: Self.width * clampedOffset)
        }
    }
}

/// A breakdown caption action: icon at rest, icon + word on hover (and the system tooltip).
/// `internal` (not private) — the transcript's run link is the same affordance one level up.
struct SZCaptionActionButton: View {
    let label: String
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 8))
                if hovering {
                    Text(label).transition(.opacity)
                }
            }
        }
        .buttonStyle(SZIconHoverStyle())
        .onHover { value in
            withAnimation(.easeInOut(duration: 0.1)) { hovering = value }
        }
        .help(help)
    }
}
