// SPDX-License-Identifier: AGPL-3.0-only
// One agent-graph node card, and one wire. New views rather than reuse: `SZNodeView` is
// welded to `SZNode` (it reads `node.contract`, `node.kind` and sizes through
// `SZNodeLayout`), so there is nothing to subclass. What IS shared is the visual language —
// `SZNodeCardStyle`'s fills and fonts, the same corner radius, the same shadow — so this
// canvas reads as the same app rather than a bolt-on.
//
// Card STATE is a separate axis from `SZNodeStatus`, deliberately: that enum describes a
// render node's build lifecycle. Here "not run" (a nil phase) is the common case — a static
// plan is entirely un-run — and it must read as quiet rather than broken.
import SwiftUI
import SZCore

/// What one card is told about its visit: nil phase = the Plan view's quiet not-run card.
struct SZAgentGraphCardState: Equatable {
    var phase: SZAgentGraphRun.Entry.Phase?
    var outcome: String?
    /// A failed visit's agent-reported reason — surfaced as the card's tooltip.
    var detail: String?
    /// The dispatch entry's settlement tally (record-level, host-amended post-seal).
    var tally: SZAgentGraphRun.Tally?

    static let notRun = SZAgentGraphCardState()

    init(phase: SZAgentGraphRun.Entry.Phase? = nil, outcome: String? = nil,
         detail: String? = nil, tally: SZAgentGraphRun.Tally? = nil) {
        self.phase = phase
        self.outcome = outcome
        self.detail = detail
        self.tally = tally
    }
}

/// What a Run card says about the cost of one visit: when it started (the live timer's
/// anchor) and its settled wall time — nil while running, the card ticks its own elapsed.
struct SZAgentGraphCardStats: Equatable {
    var startedAt: Date
    var duration: TimeInterval?
    /// The settled visit's envelope receipt ("codex · gpt-5.6-terra · fast") — text on the
    /// footer line, never a height. nil while running and on records without one.
    var generation: String?
}

struct SZAgentGraphCardView: View {
    let face: SZAgentGraphFace
    /// Open the card's authored source (the step's Swift, a turn's brief). nil = no host
    /// wired the affordance — the pill simply isn't drawn.
    var openSource: ((SZAgentGraphFace.Source) -> Void)? = nil
    /// Whether a FILE source (step, brief) offers its pill — a dead pill promises an
    /// editor that never opens. A dispatch link is drawn either way.
    var drawsFileSources: Bool = true
    let state: SZAgentGraphCardState
    /// The Run view's per-visit label ("visit 2"), shown on the subheader line.
    var visitLabel: String? = nil
    /// The Run view's per-visit cost line. Present exactly when
    /// `SZAgentGraphLayout.hasStats` was told this form spends — the frames/pixels pact.
    var stats: SZAgentGraphCardStats? = nil
    /// The transcripts, for the band and the spend to read this visit's turn out of. Handed
    /// in, not fetched through a closure, so the read lands in those leaf views and a
    /// streaming turn re-renders them rather than the canvas.
    var store: SZStore? = nil
    /// The turn this card's visit ran — the message id the band and the spend read.
    var turnID: UUID? = nil
    /// Whether the activity band is showing — the same flag `SZAgentGraphLayout.runFrames`
    /// was given, or the card draws a band its frame did not reserve.
    var activityOpen: Bool = false
    /// Open/close the band. nil = this visit has nothing to show, and no chevron is drawn.
    var onToggleActivity: (() -> Void)? = nil
    /// Whether the footer says what the turn spent (`SZAgentGraphLayout.hasTokenLine`).
    var showsTokenLine: Bool = false
    /// Whether the footer reserves the receipt line (`SZAgentGraphLayout.extraFooterLines`).
    /// Both come from the same predicates the frame was sized by, so the drawn card and its
    /// frame cannot disagree.
    var showsReceiptLine: Bool = false

    /// Only the states you need to FIND get a heavier outline. "Finished" is the common
    /// case in a completed traversal — if it shouts, nothing else can.
    private var emphasised: Bool { state.phase == .running || state.phase == .failed }

    var body: some View {
        card.help(state.detail ?? face.title)
            .overlay(alignment: .bottomLeading) { sourceButton }
    }

    /// The Run view's second header line exists exactly when it has something to say — the
    /// same condition `SZAgentGraphLayout.hasSubheader` feeds the sizing, so the drawn card
    /// and its frame can't disagree.
    private var showsSubheader: Bool { visitLabel != nil || state.tally != nil }

    /// One anatomy for every form. A compiled step is told apart by COLOUR alone — an
    /// opaque violet card among grey ones.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsSubheader { subheader }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(face.outcomes, id: \.self) { outcome in
                    outcomeRow(outcome)
                }
            }
            .padding(.top, SZNodeLayout.bodyTopPadding)
            .padding(.bottom, SZNodeLayout.bodyBottomPadding)
            if activityOpen, let store, let turnID {
                SZAgentGraphActivityBand(store: store, turnID: turnID)
            }
            if let stats { statsFooter(stats) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: SZNodeLayout.cornerRadius, style: .continuous)
            .fill(face.form == .step || face.form == .door
                ? SZAgentGraphStyle.stepFill : SZNodeCardStyle.cardFill))
        .overlay(RoundedRectangle(cornerRadius: SZNodeLayout.cornerRadius, style: .continuous)
            .strokeBorder(borderColor, lineWidth: emphasised ? 1.5 : 1))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }

    /// Glyph, the FULL title, the status badge — nothing else. The visit mark and the
    /// dispatch tally live on the subheader line, so the title never crops.
    private var header: some View {
        HStack(spacing: 7) {
            glyph
            Text(face.title)
                .font(SZNodeCardStyle.titleFont)
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            slotChip
            finishedGlyph
        }
        .padding(.horizontal, 12)
        .frame(height: SZNodeLayout.headerHeight)
    }

    /// The turn's model slot, worn as a quiet chip at the header's trailing edge. Inside the
    /// fixed-height header on purpose, so a slotted card measures exactly like a plain one.
    @ViewBuilder private var slotChip: some View {
        if let slot = face.slot {
            Text(slot)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                // The chip shows whole and the title ellipsizes, never a half-truncated chip.
                .fixedSize()
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
    }

    /// The implementation door, tucked just BELOW the card like the node editor's action
    /// pills — outside the frame, so it neither fights the card's gestures nor crowds the
    /// header. Only drawn when the face carries a source AND a host wired the opener.
    @ViewBuilder
    private var sourceButton: some View {
        if let source = face.source, let openSource,
           drawsFileSources || { if case .dispatch = source { true } else { false } }() {
            SZCardPillButton(
                symbol: "doc.text",
                help: {
                    switch source {
                    case .step: "Open the step's Step.swift"
                    case .brief: "Open the brief template"
                    case .sentPrompt: "Open the prompt this turn sent"
                    case .dispatch(let target): "Open the \(target) seat's graph"
                    }
                }(),
                action: { openSource(source) })
            .offset(x: 2, y: 27)
        }
    }

    /// The Run view's second line, under the title: the re-entry mark (the only thing
    /// telling the loop's second visit apart from its first) and the dispatch's live tally —
    /// with, when members failed, the count that says so without routing anything.
    private var subheader: some View {
        HStack(spacing: 5) {
            if let visitLabel {
                Text(visitLabel)
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(SZEdgeStyle.intentViolet)
                    .lineLimit(1)
            }
            if let tally = state.tally {
                Text("\(tally.settled)/\(tally.total)")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                if tally.failed > 0 {
                    Text("· \(tally.failed) failed")
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(SZAgentGraphStyle.failed)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        // Left-aligned under the TITLE, not the glyph — the line reads as its annotation.
        .padding(.leading, 12 + 22 + 7)
        .padding(.trailing, 12)
        .frame(height: SZAgentGraphLayout.subheaderHeight, alignment: .top)
        // Nudged toward the title (the 40pt header centres its content, leaving air under
        // it), so the line reads as attached rather than floating between title and rows.
        .offset(y: -3)
    }

    /// The cost strip along the card's bottom edge, under the ports — a measurement is a
    /// different KIND of fact from a port, and its own darker ground says so without
    /// competing with the outcome rows. Only the bottom corners round, so it reads as part
    /// of the card rather than a chip sitting on it.
    private func statsFooter(_ stats: SZAgentGraphCardStats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SZAgentGraphLayout.activityFooterGap) {
                statLine(stats)
                Spacer(minLength: 0)
            }
            .frame(height: SZAgentGraphLayout.footerRowHeight)
            // The envelope receipt, on the line the frame reserved for every turn card. Empty
            // until the turn opens and names its model.
            if showsReceiptLine {
                Text(stats.generation ?? "")
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(height: SZAgentGraphLayout.footerRowHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, footerIndent)
                    .help(stats.generation ?? "")
            }
            // Under the clock, open or folded, indented past the chevron so the lines share
            // a left edge.
        }
        .padding(.vertical, SZAgentGraphLayout.footerVerticalPad)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: SZNodeLayout.cornerRadius,
                                   bottomTrailingRadius: SZNodeLayout.cornerRadius,
                                   style: .continuous)
                .fill(Color.black.opacity(0.28))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                })
    }

    /// A RUNNING visit ticks its own elapsed on a row-local `TimelineView`, so only this
    /// card re-renders each second, and the number freezes into the settled duration when
    /// the visit ends.
    /// The footer's lower lines start where the clock's text does, not under the chevron.
    private var footerIndent: CGFloat {
        SZAgentGraphLayout.activityChevronWidth + SZAgentGraphLayout.activityFooterGap
    }

    @ViewBuilder private func statLine(_ stats: SZAgentGraphCardStats) -> some View {
        if let onToggleActivity { activityChevron(onToggleActivity) }
        if let duration = stats.duration {
            statText(SZTurnBreakdown.format(duration))
            // What it cost, beside how long it took.
            if showsTokenLine, let store, let turnID {
                statText("·")
                SZAgentGraphActivityTokens(store: store, turnID: turnID)
            }
        } else {
            SZAgentGraphCardDots()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(SZAgentGraphClock.stopwatch(context.date.timeIntervalSince(stats.startedAt)))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .contentTransition(.identity)
            }
        }
    }

    private func activityChevron(_ toggle: @escaping () -> Void) -> some View {
        SZAgentGraphActivityChevron(open: activityOpen, action: toggle)
    }

    private func statText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.72))
            .lineLimit(1)
            // The clock ticks INSIDE an animated context, and a cross-faded Text puts the
            // old second and the new one on screen at once — swap the string, don't blend.
            .contentTransition(.identity)
    }

    /// One outcome, right-aligned against its socket — the artifact card's output-row
    /// rhythm, so a port here reads the same as a port there.
    private func outcomeRow(_ outcome: String) -> some View {
        // Once a node has run, the port it LEFT BY is the interesting fact. Before it runs,
        // no row is privileged — dimming one then would imply a decision not yet made.
        let fired = state.outcome == outcome
        let decided = state.outcome != nil
        let hue = SZAgentGraphStyle.colour(for: outcome, in: face.form)
        return HStack(spacing: 5) {
            Spacer(minLength: 0)
            if fired {
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(hue)
            }
            Text(outcome)
                .font(SZNodeCardStyle.labelFont)
                .foregroundStyle(hue.opacity(decided ? (fired ? 1 : 0.4) : 0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: SZNodeLayout.rowHeight)
    }

    private var glyph: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .frame(width: 22, height: 22)
            .overlay(Image(systemName: face.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85)))
    }

    /// "This visit settled." A BADGE — white glyph on a filled circle — rather than a bare
    /// glyph: fixed-size, so it can never wrap the header. Violet for a step — a step
    /// ANSWERED, it did not succeed; which way it went is the lit row's job.
    @ViewBuilder private var finishedGlyph: some View {
        switch state.phase {
        case .none:
            EmptyView()
        case .running:
            SZPulsingOpacity(range: 0.35...1, halfPeriod: SZPulse.period / 2) {
                Circle().fill(SZAgentGraphStyle.running).frame(width: 7, height: 7)
            }
        case .done:
            statusBadge("checkmark", face.form == .step || face.form == .door
                ? SZEdgeStyle.intentViolet : SZAgentGraphStyle.done)
        case .failed:
            statusBadge("xmark", SZAgentGraphStyle.failed)
        case .cancelled:
            // Neither finished nor failed — the traversal stopped here. Neutral on purpose.
            statusBadge("minus", SZAgentGraphStyle.neutral)
        }
    }

    private func statusBadge(_ symbol: String, _ colour: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(Circle().fill(colour))
    }

    private var borderColor: Color {
        // A step's border is violet like its fill — the colour IS its identity.
        let resting = face.form == .step || face.form == .door
            ? SZAgentGraphStyle.stepStroke : SZNodeCardStyle.cardStroke
        switch state.phase {
        case .none, .cancelled: return resting
        case .running: return SZAgentGraphStyle.running
        // A step that ran keeps its own hue: it did not "succeed", it answered.
        case .done:    return resting
        case .failed:  return SZAgentGraphStyle.failed
        }
    }
}

/// One wire. Reuses `SZCubic`'s control-point rule so its curvature matches the artifact
/// canvas exactly; drawn directly rather than through `SZConnectionStrokeView`, which would
/// mean adding a third case to `SZConnectionKind` — an SZCore enum persisted in every
/// project file.
struct SZAgentGraphWire: View {
    let path: (CGPoint, CGPoint)
    let outcome: String
    let bounded: Bool
    let zoom: CGFloat
    /// The FROM node's form — a wire takes the form-aware hue of the socket it leaves, so a
    /// step's branches render violet like their ports rather than as verdicts.
    var fromForm: SZAgentGraphFace.Form? = nil
    /// A Run-view forecast wire: part of the projected future, not something that happened —
    /// dashed and neutral so it cannot be mistaken for a step the traversal took.
    var projected: Bool = false
    /// Overrides the back-edge pill's word. A bounded edge is a `loop`; the derived return
    /// from a dispatch to its agent's door is not a loop but a reply, and says so.
    var labelText: String? = nil

    var body: some View {
        ZStack {
            shape.stroke(colour, style: StrokeStyle(lineWidth: max(1.5, 2 / zoom),
                                                    lineCap: .round, dash: dash))
            label
        }
    }

    /// ONLY a back edge gets a pill. Outcome names live on the cards as labelled rows, so a
    /// pill repeating them would be duplication.
    @ViewBuilder private var label: some View {
        if bounded {
            let z = max(zoom, 0.1)
            Text(labelText ?? "loop")
                .font(.system(size: max(7, 10 / z), weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.82))
                .padding(.horizontal, max(3, 5 / z))
                .padding(.vertical, max(1, 2 / z))
                .background(Capsule().fill(colour))
                .position(labelPoint)
        }
    }

    /// Mid-wire. A back edge's midpoint is on its flat run underneath, not on a cubic
    /// between its ends — that would drop the label on top of the cards it routes around.
    private var labelPoint: CGPoint {
        guard bounded else { return SZCubic.point(path.0, path.1, 0.5) }
        return CGPoint(x: (path.0.x + path.1.x) / 2,
                       y: max(path.0.y, path.1.y) + SZAgentGraphBackEdgeShape.dip)
    }

    /// A forward wire is the artifact canvas's cubic, unchanged. A BACK edge is routed
    /// under the graph instead: it travels right-to-left across everything between its
    /// ends, and the plain cubic would draw it straight through every card in between.
    private var shape: some Shape {
        bounded ? AnyShape(SZAgentGraphBackEdgeShape(from: path.0, to: path.1))
                : AnyShape(SZConnectionShape(from: path.0, to: path.1))
    }

    private var colour: Color {
        if projected { return SZAgentGraphStyle.neutral.opacity(0.9) }
        // A bounded edge is the loop, and reads as structure rather than flow.
        if bounded { return SZEdgeStyle.intentViolet.opacity(0.95) }
        return SZAgentGraphStyle.colour(for: outcome, in: fromForm).opacity(0.95)
    }

    /// Dashed for the loop and the projected future — a wire that isn't a step the
    /// traversal took shouldn't read as one.
    private var dash: [CGFloat] {
        bounded || projected ? [max(4, 6 / zoom), max(3, 5 / zoom)] : []
    }
}

/// A back edge, routed below: drop out of the source, run flat under the graph, rise into
/// the target. Drawn with the same rounded feel as the cubics so it reads as one language.
struct SZAgentGraphBackEdgeShape: Shape {
    var from: CGPoint
    var to: CGPoint
    /// Far enough below the tallest card to clear it, close enough to still read attached.
    static let dip: CGFloat = 150

    func path(in _: CGRect) -> Path {
        let low = max(from.y, to.y) + Self.dip
        let bend: CGFloat = 46
        var path = Path()
        path.move(to: from)
        path.addCurve(to: CGPoint(x: from.x, y: low),
                      control1: CGPoint(x: from.x + bend, y: from.y),
                      control2: CGPoint(x: from.x + bend, y: low))
        path.addLine(to: CGPoint(x: to.x, y: low))
        path.addCurve(to: to,
                      control1: CGPoint(x: to.x - bend, y: low),
                      control2: CGPoint(x: to.x - bend, y: to.y))
        return path
    }
}

enum SZAgentGraphStyle {
    static let done = Color(red: 0.29, green: 0.75, blue: 0.36)
    /// Orange-red rather than pure red: on this canvas a step's honest "no" branch is an
    /// ordinary fact, and hard red would read as breakage every time one answers.
    static let failed = Color(red: 0.93, green: 0.44, blue: 0.26)
    /// IN FLIGHT — one blue for every surface that says "this is going right now": a
    /// traversing card's pulse and border, the RUNS badge, a live lane's stroke. It used to
    /// be blue on the cards and orange on the badges, which made the same fact wear two
    /// colours, and the orange sat one hue away from `failed`.
    static let running = Color(red: 0.30, green: 0.55, blue: 0.95)
    /// A VALID conclusion — the `complete` capsule of a traversal that ended on purpose, and
    /// the RUNS badge that says the same thing: ONE constant, so the list and the canvas can
    /// never disagree about an ending. GREEN, the same green a settled card's checkmark
    /// wears: finishing a run and finishing a node are the same kind of good news.
    static let ended = done
    static let neutral = Color(white: 0.50)

    /// The one place an outcome becomes a colour, so wires and their sockets can never
    /// disagree. `form` matters: a STEP's branches are neutral facts, not verdicts — its
    /// ports take its own violet, and only the taken one is bright. For the rest, the
    /// dispatch card's rule generalized: `ok`-prefixed is done, error/failed/defect broke.
    static func colour(for outcome: String, in form: SZAgentGraphFace.Form? = nil) -> Color {
        if form == .step || form == .door { return SZEdgeStyle.intentViolet }
        if outcome == "ok" || outcome.hasPrefix("ok:") { return done }
        if outcome == "error" || outcome.hasPrefix("error")
            || outcome.hasPrefix("failed") || outcome.hasPrefix("defect") { return failed }
        return neutral   // `sent`, `done` — plain flow
    }

    /// OPAQUE — a translucent violet let the canvas grid bleed through, which read as
    /// unfinished. A ~30 % violet-over-card mix, pre-composited: unmistakably a different
    /// colour from the grey work cards, dark enough that white text still carries.
    static let stepFill = Color(red: 0.29, green: 0.25, blue: 0.38)
    static let stepStroke = SZEdgeStyle.intentViolet.opacity(0.55)
}

/// Small wall-clock formatters for this panel's live rows — a ticking stopwatch and a
/// relative age. Local: `SZTurnBreakdown.format` owns settled durations app-wide; these two
/// only exist where something on screen counts.
enum SZAgentGraphClock {
    /// "0:07", "1:23:45" — a clock counting up.
    static func stopwatch(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return "\(s / 3600):" + String(format: "%02d:%02d", (s % 3600) / 60, s % 60) }
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// "12s ago", "3m ago" — the row's relative age.
    static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(Int(s))s ago" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86_400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86_400))d ago"
    }
}

/// The chat panel's typing-indicator recipe at card scale: three dots on a traveling wave.
/// Duplicated rather than shared on the chat panel's own reasoning — the chrome in common
/// is ten lines against unrelated hosts.
/// The footer's disclosure: opens this visit's own words under the outcome rows. Sits where
/// the clock is because that is the line that already says what the visit is doing.
private struct SZAgentGraphActivityChevron: View {
    let open: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            // Open points UP, at what clicking it folds away — the same rule the run strip's
            // fold line follows, so the two disclosures read as one gesture.
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .bold))
                .rotationEffect(.degrees(open ? -90 : 0))
                .foregroundStyle(Color.white.opacity(hover ? 1 : 0.55))
                .frame(width: SZAgentGraphLayout.activityChevronWidth,
                       height: SZAgentGraphLayout.footerRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .trackingHover($hover)
        // `.help` is inert under the canvas's scale transform, so the tip is drawn by hand.
        .hoverTip(open ? "Hide what this agent said" : "Show what this agent is doing", edge: .bottom)
    }
}

/// What this turn spent, beside the clock. Its own view so the transcript read lands here and
/// not in the canvas's body. Silent for a CLI that reports no usage.
private struct SZAgentGraphActivityTokens: View {
    let store: SZStore
    let turnID: UUID

    var body: some View {
        if let usage = store.chatMessage(id: turnID)?.usage {
            // The unit once, up front: after each number it no longer fitted beside the clock.
            Text("tok \(szFormatTokensCompact(usage.inputTokens)) in / \(szFormatTokensCompact(usage.outputTokens)) out")
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1)
                .contentTransition(.identity)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("\(usage.inputTokens) tokens in, \(usage.outputTokens) out")
        }
    }
}

/// What the agent said on this visit, in a box of its own. THE leaf that reads the live
/// transcript: the thunk is called in here and nowhere above, so a streaming turn re-renders
/// this band instead of the whole canvas. Fixed height (the frame reserved exactly
/// `activityBandHeight`), so the text scrolls rather than growing the card.
private struct SZAgentGraphActivityBand: View {
    let store: SZStore
    let turnID: UUID
    private static let bottomID = "bottom"

    /// THE read, and the reason this is its own view: it touches the live transcript, so the
    /// observation lands here and a streaming turn re-renders this band instead of the canvas.
    private var turn: SZChatMessage? { store.chatMessage(id: turnID) }

    var body: some View {
        let turn = turn
        let steps = SZAgentActivityStep.steps(thinking: turn?.thinking ?? "")
        let reply = (turn?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(steps) { step in
                        switch step.kind {
                        case .tool:
                            // A tool call is a step: its own row, so the trace reads as a
                            // list of what the agent did, not one paragraph.
                            HStack(alignment: .top, spacing: 5) {
                                Text("→").foregroundStyle(SZAgentGraphStyle.running.opacity(0.9))
                                Text(step.text).foregroundStyle(Color.white.opacity(0.72))
                            }
                        case .thought:
                            Text(step.text).foregroundStyle(Color.white.opacity(0.42))
                        }
                    }
                    if !reply.isEmpty {
                        if !steps.isEmpty { Divider().opacity(0.12).padding(.vertical, 2) }
                        Text(reply).foregroundStyle(Color.white.opacity(0.85))
                    }
                    if steps.isEmpty, reply.isEmpty {
                        Text(turn == nil ? "no turn to read" : "working…")
                            .foregroundStyle(Color.white.opacity(0.3))
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .font(.system(size: 8.5, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            // Newest at the bottom, and pinned WITHOUT animation: at flush cadence an
            // interruptible scroll restarted per chunk reads as a jitter, not as a follow.
            .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .onChange(of: (turn?.thinking.count ?? 0) + (turn?.text.count ?? 0)) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
        .frame(height: SZAgentGraphLayout.activityBandHeight)
        .background(Color.black.opacity(0.18))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
    }
}

private struct SZAgentGraphCardDots: View {
    @State private var bright = false
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 3.5, height: 3.5)
                    .opacity(bright ? 0.9 : 0.28)
                    .scaleEffect(bright ? 1.0 : 0.82)
                    .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.21), value: bright)
            }
        }
        .onAppear { bright = true }
    }
}
