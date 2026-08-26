// SPDX-License-Identifier: AGPL-3.0-only
// Auto-layout for the Agent Graph panel: what each node's card SAYS (its face) and where it
// sits (its frame). Pure and SwiftUI-free (CoreGraphics only) so it is unit-testable
// headlessly — the house split, same as `SZGraphLayout` and `SZCanvasCamera`.
//
// The FACE is one derivation: a node takes exactly one of three forms (step / turn /
// dispatch; the step at the reserved `door` id is the door), and icon, title and outcome
// rows all derive from the form plus the node's own title. A compiled step's declared
// outcome set lives in SZAI (attached at pack load), which this module may not import, so
// a step card draws the outcomes its graph file actually WIRES, and a Run entry's produced
// outcome joins the rows if the wiring never named it (`ensuring`).
//
// The frame algorithm is deliberately boring: rank by longest path from the entry over
// FORWARD edges only, stack within a rank, done. Back edges (the bounded ones — the retry
// loop) are excluded from ranking on purpose: including them would make the rank graph
// cyclic and read backwards.
import CoreGraphics
import Foundation
import SZCore

/// One node's card face — everything the renderers need that the graph model doesn't spell.
public struct SZAgentGraphFace: Equatable, Sendable {
    /// The forms, re-stated flat so renderers can switch without pattern-matching
    /// payloads they don't read. `door` is the step at the reserved entry id — a step in
    /// every mechanical way, told apart so the card can wear the door's identity.
    public enum Form: Equatable, Sendable { case door, step, turn, dispatch }
    /// What the card's source affordance opens: the step's authored Swift, or the brief
    /// template that IS a turn's body. A value, not an action — the host resolves the file.
    public enum Source: Equatable, Sendable {
        case step(name: String)
        case brief(path: String)
        /// A dispatch's "body" is the graph it calls into — the pill LINKS to the target
        /// seat's graph rather than opening a file.
        case dispatch(target: String)
    }
    public var form: Form
    public var title: String
    public var symbol: String
    /// The rows the card draws, in display order.
    public var outcomes: [String]
    /// Declared outcomes NO edge leaves — the graph's "this answer ends the run here",
    /// drawn dimmed so the ending is visible instead of the port simply vanishing.
    public var unwired: Set<String>
    public var source: Source?
    /// The turn's model-slot LABEL ("Planner", "Builder - Normal") — worn as a chip in the
    /// fixed-height header so it never enters `size(of:)`. nil on other forms and slotless turns.
    public var slot: String?

    public init(form: Form, title: String, symbol: String, outcomes: [String],
                unwired: Set<String> = [], source: Source? = nil, slot: String? = nil) {
        self.form = form
        self.title = title
        self.symbol = symbol
        self.outcomes = outcomes
        self.unwired = unwired
        self.source = source
        self.slot = slot
    }

    /// The face with `outcome` guaranteed a row — a Run entry may produce an outcome the
    /// graph file never wired (a step's ending outcome), and the fired port must exist.
    public func ensuring(_ outcome: String?) -> SZAgentGraphFace {
        guard let outcome, !outcomes.contains(outcome) else { return self }
        var grown = self
        grown.outcomes.append(outcome)
        return grown
    }

    /// Used only when a trace names a node its graph no longer carries — keeps layout total.
    public static func fallback(node: String, outcome: String? = nil) -> SZAgentGraphFace {
        SZAgentGraphFace(form: .step, title: node, symbol: "questionmark",
                         outcomes: [outcome ?? "done"])
    }
}

public enum SZAgentGraphLayout {
    /// Column pitch and within-column gap, shared with `SZGraphLayout` so the two canvases
    /// feel like the same app rather than two apps.
    static let layerGap: CGFloat = SZGraphLayout.layerGap
    static let nodeGap: CGFloat = SZGraphLayout.nodeGap

    // Width is content-driven: a card grows until its own header fits WHOLE — the chip must
    // never cost the title its words, and no ceiling clips it. The text is measured with the
    // fonts the header actually draws (`SZCardText`), not estimated per character: a
    // char-count average is wrong by a word on exactly the strings that matter, and it was
    // what cropped "Implement" to "Implem…" on a card with a slot chip.
    public static let minCardWidth: CGFloat = 200

    /// The header's anatomy, in the order `SZAgentGraphCardView.header` stacks it: 12pt
    /// padding, the 22pt glyph, the title, a Spacer, the slot chip (its own 4+4 padding), the
    /// finished badge, 12pt padding.
    ///
    /// The SPACER takes a spacing slot of its own — that is the gap the old estimate dropped,
    /// and being one gap short is what cropped "Implement" to "Implem…" on a slotted card.
    public static func width(of face: SZAgentGraphFace) -> CGFloat {
        // glyph|title, title|spacer, spacer|(chip or badge).
        var width = 12 + 22 + SZCardText.titleWidth(face.title) + statusBadgeWidth + 12
            + headerGap * 3
        if let slot = face.slot {
            width += SZCardText.chipWidth(slot) + 8 + headerGap   // + the chip|badge gap
        }
        return max(minCardWidth, (width + headerSlack).rounded(.up))
    }

    /// `SZAgentGraphCardView.header`'s HStack spacing.
    static let headerGap: CGFloat = 7

    /// A hair of slack on the measured fit. CoreText reports the advance a line WOULD take;
    /// SwiftUI lays the same string out with its own rounding, and landing within a fraction
    /// of a point of exact still ellipsized. Small enough to be invisible, big enough that
    /// the header never loses a character to a rounding difference.
    static let headerSlack: CGFloat = 4

    /// The Run view's finished badge — a fixed 15pt disc, reserved whether or not this card
    /// wears one yet, so a card does not resize when its visit settles.
    static let statusBadgeWidth: CGFloat = 15

    /// The Run view's second header line — `visit N` and the dispatch tally, on their own
    /// line under the title (in the title row they cropped it to "Imple…").
    public static let subheaderHeight: CGFloat = 14

    /// One line of the footer, and the breathing room above and below the block. Text used to
    /// sit on the card's bottom edge with nothing around it, which read as cramped whether or
    /// not the card was open.
    public static let footerRowHeight: CGFloat = 17
    public static let footerVerticalPad: CGFloat = 4

    /// The stats strip under the outcome rows — what the visit COST in wall time. Below the
    /// ports rather than on the subheader: the rows are the card's contract and must not be
    /// pushed around by a number that arrives mid-traversal.
    public static let statsFooterHeight: CGFloat = footerRowHeight + footerVerticalPad * 2

    /// The opened activity band — the agent's own words for this visit, scrolling inside a
    /// fixed height. Fixed on purpose: streaming text that resized its card would drag the
    /// chain's wires around for the whole turn.
    public static let activityBandHeight: CGFloat = 96


    /// The disclosure's column in the footer — its glyph plus the row's spacing. The spend
    /// line indents by it so its text starts where the clock's does, rather than hanging out
    /// under the chevron.
    public static let activityChevronWidth: CGFloat = 12
    public static let activityFooterGap: CGFloat = 5

    // MARK: - Faces

    /// The card face of one node: derived from its form + its own title, nothing stored.
    /// `stepOutcomes` carries the compiled steps' declared outcome sets (host-resolved);
    /// with it a step card shows EVERY answer it can give — the unwired ones dimmed, since
    /// an outcome with no edge is how a graph spells "this ends the run".
    public static func face(of node: SZAgentGraph.Node, in graph: SZAgentGraph,
                            stepOutcomes: [String: [String]] = [:]) -> SZAgentGraphFace {
        switch node.form {
        case .step(let name):
            // The door wears its identity; mechanically it is the same card — outcomes
            // from the declaration when the host has it (declared order, wired first),
            // its pill opening its Step.swift.
            let door = node.id == SZAgentGraph.doorID
            let form: SZAgentGraphFace.Form = door ? .door : .step
            let symbol = door ? "tray.and.arrow.down" : "curlybraces"
            let title = node.title ?? (door ? "On message" : name)
            let wired = wiredOutcomes(of: node.id, in: graph)
            if let declared = stepOutcomes[node.id], !declared.isEmpty {
                let ordered = wired + declared.filter { !wired.contains($0) }
                return SZAgentGraphFace(form: form, title: title, symbol: symbol,
                                        outcomes: ordered,
                                        unwired: Set(declared).subtracting(wired),
                                        source: .step(name: name))
            }
            return SZAgentGraphFace(form: form, title: title, symbol: symbol,
                                    outcomes: wired.isEmpty ? ["done"] : wired,
                                    source: .step(name: name))
        case .turn(let turn):
            // Fixed process-truth rows, in the reading order the model documents. The
            // brief is a stem; the pill opens its prompts file.
            return SZAgentGraphFace(form: .turn, title: node.title ?? turn.brief,
                                    symbol: "text.bubble", outcomes: ["ok", "error"],
                                    source: .brief(path: "prompts/\(turn.brief).md.mustache"),
                                    slot: turn.slot.map { id in
                                        graph.slot(id).map { $0.label ?? $0.id } ?? id
                                    })
        case .dispatch(let dispatch):
            // Fan out and WAIT; `settled` routes onward — dimmed when nothing is wired,
            // the honest "its first settlement concludes".
            return SZAgentGraphFace(form: .dispatch, title: node.title ?? "→ \(dispatch.to)",
                                    symbol: "arrow.triangle.branch", outcomes: ["settled"],
                                    unwired: Set(["settled"])
                                        .subtracting(wiredOutcomes(of: node.id, in: graph)),
                                    source: .dispatch(target: dispatch.to))
        }
    }

    /// A Run entry's face: the plan face grown to include the outcome it actually produced,
    /// or a total fallback when the trace names a node the graph no longer carries.
    public static func runFace(for entry: SZAgentGraphRun.Entry,
                               in graph: SZAgentGraph?,
                               stepOutcomes: [String: [String]] = [:]) -> SZAgentGraphFace {
        guard let graph, let node = graph.node(entry.node) else {
            return .fallback(node: entry.node, outcome: entry.outcome)
        }
        return face(of: node, in: graph, stepOutcomes: stepOutcomes).ensuring(entry.outcome)
    }

    /// A step's drawable outcome set: what its graph file wires, first-wire order, deduped.
    static func wiredOutcomes(of node: String, in graph: SZAgentGraph) -> [String] {
        var seen: Set<String> = []
        return graph.edges.filter { $0.from == node }.map(\.outcome).filter { seen.insert($0).inserted }
    }

    // MARK: - Sizing

    /// One anatomy for every node — a form differs by COLOUR, not by shape. `subheader`
    /// reserves the Run view's second header line; `stats` reserves the footer. A Plan card
    /// keeps the plain anatomy, so the two modes stay byte-identical where they can.
    /// - Parameter extraFooterLines: footer lines under the clock's (the envelope receipt).
    public static func size(of face: SZAgentGraphFace, subheader: Bool = false,
                            stats: Bool = false, extraFooterLines: Int = 0) -> CGSize {
        let rows = max(1, face.outcomes.count)
        return CGSize(width: width(of: face),
                      height: SZNodeLayout.headerHeight + (subheader ? subheaderHeight : 0)
                            + SZNodeLayout.bodyTopPadding
                            + CGFloat(rows) * SZNodeLayout.rowHeight + SZNodeLayout.bodyBottomPadding
                            + (stats ? statsFooterHeight : 0)
                            + (stats ? CGFloat(max(0, extraFooterLines)) * footerRowHeight : 0))
    }

    /// Whether a Run entry's card carries the subheader line (visit mark / dispatch tally).
    /// Sizing and rendering both derive from THIS, so the frame a card is given and the
    /// pixels it draws can never disagree.
    public static func hasSubheader(_ entry: SZAgentGraphRun.Entry, in record: SZAgentGraphRun,
                                    face: SZAgentGraphFace) -> Bool {
        record.visits(of: entry.node) > 1 || (face.form == .dispatch && entry.tally != nil)
    }

    /// Whether a Run entry's card carries the stats footer. A spending step gets it from its
    /// FIRST frame — `startedAt` is stamped the moment the entry is first reported — so the
    /// ticking clock appears with the card rather than growing it a second later.
    public static func hasStats(_ entry: SZAgentGraphRun.Entry, spends: Bool) -> Bool {
        spends && entry.startedAt != nil
    }

    /// The footer lines under the clock's — the envelope receipt. Its own line because beside
    /// the clock it truncated to "cla…opus-5", hiding the model it names. Read from the FORM,
    /// not from `entry.generation`: the receipt lands mid-turn, and sizing by it grew the card
    /// under the pointer.
    public static func extraFooterLines(_ face: SZAgentGraphFace) -> Int {
        face.form == .turn ? 1 : 0
    }

    /// Whether a visit's footer says what the turn spent — it has a transcript message behind
    /// it. A step settled in noise and owes nothing.
    public static func hasTokenLine(_ entry: SZAgentGraphRun.Entry) -> Bool {
        entry.turnID != nil
    }

    /// Which forms SPEND — the ones whose cards carry wall time. A mid-graph step settles
    /// in sub-millisecond noise; the door may ask the model, so it counts.
    public static func spends(_ form: SZAgentGraphFace.Form) -> Bool {
        form == .turn || form == .dispatch || form == .door
    }

    // MARK: - The Run view's chain

    /// The Run view's chain frames: one per trace entry, in traversal order, centred on
    /// y = 0 so mixed heights share a spine. Sized by the same `size(of:)` the plan uses.
    /// Pure and here (not in the renderer) so the panel's follow-cam and the canvas content
    /// can never disagree about where the live card sits.
    /// The scrolling region of an OPEN card, in the same space its frame is in. The band
    /// scrolls its own text, so a scroll landing here must not also pan the canvas — the
    /// panel reads this to leave the camera alone. Measured from the bottom: the footer sits
    /// under the band, and carries a second line while the band is open.
    /// - Parameter extraFooterLines: the same count the frame was sized with, so the band
    ///   stops where the footer block starts.
    public static func activityBandRect(in frame: CGRect, extraFooterLines: Int) -> CGRect {
        let bottom = frame.maxY - statsFooterHeight
            - CGFloat(max(0, extraFooterLines)) * footerRowHeight
        return CGRect(x: frame.minX, y: bottom - activityBandHeight,
                      width: frame.width, height: activityBandHeight)
    }

    /// - Parameter opened: the entries whose activity band is showing, by ordinal. View state,
    ///   unlike the subheader and footer, so it arrives as an argument — and BOTH readers (the
    ///   canvas and the panel's follow-cam) must pass the same set or the camera lands wrong.
    public static func runFrames(for record: SZAgentGraphRun, graph: SZAgentGraph?,
                                 stepOutcomes: [String: [String]] = [:],
                                 opened: Set<Int> = []) -> [CGRect] {
        var x: CGFloat = 0
        var frames: [CGRect] = []
        for entry in record.trace {
            let face = runFace(for: entry, in: graph, stepOutcomes: stepOutcomes)
            let closed = size(of: face, subheader: hasSubheader(entry, in: record, face: face),
                              stats: hasStats(entry, spends: spends(face.form)),
                              extraFooterLines: extraFooterLines(face))
            // Opening a band grows the card DOWNWARD: y stays on the closed height, so the
            // header, the ports and every wire into them hold still while you read.
            let height = closed.height + (opened.contains(entry.ordinal) ? activityBandHeight : 0)
            frames.append(CGRect(origin: CGPoint(x: x, y: -closed.height / 2),
                                 size: CGSize(width: closed.width, height: height)))
            x += closed.width + layerGap
        }
        return frames
    }

    // MARK: - The Plan view's placement

    /// Where every node sits, in world space. Frames are top-left origin (this graph has no
    /// persisted positions to be compatible with, and top-left is what the renderer wants).
    public struct Placement: Equatable, Sendable {
        public var frames: [String: CGRect]
        /// The union of every frame — what the initial framing needs. `.null` when empty.
        public var bounds: CGRect
    }

    public static func lay(out graph: SZAgentGraph,
                           stepOutcomes: [String: [String]] = [:]) -> Placement {
        lay(out: graph, from: entryNode(of: graph), stepOutcomes: stepOutcomes)
    }

    /// Laid out from an explicit seed — what the Run view's forecast needs, since a
    /// projection is a fragment of a traversal already past its door and carries no message
    /// node to seed from.
    public static func lay(out graph: SZAgentGraph, from seed: String,
                           stepOutcomes: [String: [String]] = [:]) -> Placement {
        let ranks = ranks(of: graph, from: seed)
        // Within a rank, order by DECLARATION order in the file. Stable, and it hands the
        // author a real lever: reordering the `nodes` array reorders the column.
        var byRank: [Int: [SZAgentGraph.Node]] = [:]
        for node in graph.nodes {
            byRank[ranks[node.id] ?? 0, default: []].append(node)
        }

        let bypassed = bypassedRanks(of: graph, ranks: ranks)
        // Sized with the same face the renderer draws — an enriched card (declared
        // outcomes attached) must grow its frame, or its sockets slide off the rows.
        let sizesByRank = byRank.mapValues { nodes in
            nodes.map { size(of: face(of: $0, in: graph, stepOutcomes: stepOutcomes)) }
        }
        // Columns are as wide as their widest card, and each starts where the previous
        // ends — a long-titled card widens its own layer, not the whole graph.
        var xByRank: [Int: CGFloat] = [:]
        var columnWidth: [Int: CGFloat] = [:]
        var running: CGFloat = 0
        for rank in byRank.keys.sorted() {
            let width = sizesByRank[rank]?.map(\.width).max() ?? minCardWidth
            xByRank[rank] = running
            columnWidth[rank] = width
            running += width + layerGap
        }

        var frames: [String: CGRect] = [:]
        for (rank, nodes) in byRank {
            let sizes = sizesByRank[rank] ?? []
            let total = sizes.reduce(0) { $0 + $1.height } + nodeGap * CGFloat(max(0, nodes.count - 1))
            // A rank something SKIPS over lifts off the main line, so the bypassing wire has
            // clear air instead of being drawn straight through the card it is bypassing.
            var y = -total / 2 - (bypassed.contains(rank) ? bypassLift : 0)
            let x = xByRank[rank] ?? 0
            for (node, size) in zip(nodes, sizes) {
                frames[node.id] = CGRect(x: x + ((columnWidth[rank] ?? size.width) - size.width) / 2,
                                         y: y, width: size.width, height: size.height)
                y += size.height + nodeGap
            }
        }
        return Placement(frames: frames, bounds: frames.values.reduce(.null) { $0.union($1) })
    }

    // MARK: - The call band

    /// One sub-agent lane's height, and the gap between the dispatch card and its band —
    /// sized to clear the card's source pill, which hangs 27pt below the bottom edge.
    public static let laneHeight: CGFloat = 30
    public static let laneGap: CGFloat = 4
    static let bandGap: CGFloat = 34

    /// Where a dispatch's sub-agents are drawn: a stack of lanes in the VERTICAL AIR under
    /// the dispatch card, one per dispatched item. Under, not inline between ranks — an
    /// inline sub-graph would have to reserve horizontal room, reflowing every downstream
    /// rank and making the return wire's geometry depend on the callee's width.
    ///
    /// Pure geometry: the caller supplies how many lanes, this says where they sit.
    public static func callBand(under dispatch: CGRect, lanes: Int) -> [CGRect] {
        guard lanes > 0 else { return [] }
        let top = dispatch.maxY + bandGap
        return (0..<lanes).map { index in
            CGRect(x: dispatch.minX, y: top + CGFloat(index) * (laneHeight + laneGap),
                   width: dispatch.width, height: laneHeight)
        }
    }

    /// How far a bypassed rank lifts off the main line. One card height plus a gap — enough
    /// that a wire passing underneath is unambiguous.
    static let bypassLift: CGFloat = SZNodeLayout.headerHeight + 2 * SZNodeLayout.rowHeight + nodeGap

    /// Ranks that some edge jumps clean over: an edge from a rank strictly before to a rank
    /// strictly after — the nodes a wire would otherwise be drawn straight through.
    private static func bypassedRanks(of graph: SZAgentGraph, ranks: [String: Int]) -> Set<Int> {
        var skipped = Set<Int>()
        for edge in graph.edges where edge.maxTraversals == nil {
            guard let from = ranks[edge.from], let to = ranks[edge.to], to - from > 1 else { continue }
            skipped.formUnion((from + 1)..<to)
        }
        return skipped
    }

    /// The rank seed: the door, guaranteed by validation. The fallback keeps layout total
    /// on a hand-broken file rather than crashing on it.
    static func entryNode(of graph: SZAgentGraph) -> String {
        graph.door?.id ?? graph.nodes.first?.id ?? ""
    }

    /// Longest-path depth from the seed, over forward edges only. Longest rather than
    /// shortest so a node never sits left of something that feeds it.
    private static func ranks(of graph: SZAgentGraph, from seed: String) -> [String: Int] {
        let forward = graph.edges.filter { $0.maxTraversals == nil }
        var indegree: [String: Int] = [:]
        var outgoing: [String: [String]] = [:]
        for node in graph.nodes { indegree[node.id] = 0; outgoing[node.id] = [] }
        for edge in forward where indegree[edge.to] != nil && outgoing[edge.from] != nil {
            indegree[edge.to]! += 1
            outgoing[edge.from]!.append(edge.to)
        }
        // Kahn, seeded with the entry first so a disconnected fragment can't claim column 0
        // ahead of it. Validation guarantees the forward subgraph is acyclic, so this drains.
        // The `enqueued` set keeps a seed from being processed TWICE — a valid graph may
        // have a forward edge INTO its entry (a settled lane), and re-enqueueing it when its
        // indegree drains would double-decrement its successors.
        var rank: [String: Int] = [:]
        let entry = seed
        var queue = [entry] + graph.nodes.map(\.id).filter { $0 != entry && indegree[$0] == 0 }
        var enqueued = Set(queue)
        for id in queue { rank[id] = 0 }
        var head = 0
        while head < queue.count {
            let id = queue[head]; head += 1
            for next in outgoing[id] ?? [] {
                rank[next] = max(rank[next] ?? 0, (rank[id] ?? 0) + 1)
                indegree[next]! -= 1
                if indegree[next]! == 0, enqueued.insert(next).inserted { queue.append(next) }
            }
        }
        return rank
    }

    // MARK: - Ports

    /// The control-flow input rides the HEADER's left edge — the node's "in", not a row.
    public static func inputPoint(_ frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX, y: frame.minY + SZNodeLayout.headerHeight / 2)
    }

    /// One outcome per row, in display order. `subheader` must match the flag the frame was
    /// sized with, or the socket lands a line above its row.
    public static func outcomePoint(_ frame: CGRect, outcome: String,
                                    in face: SZAgentGraphFace, subheader: Bool = false) -> CGPoint {
        let index = face.outcomes.firstIndex(of: outcome) ?? 0
        return CGPoint(x: frame.maxX, y: rowCenterY(frame, row: index, subheader: subheader))
    }

    /// Centre of the `row`-th outcome row.
    public static func rowCenterY(_ frame: CGRect, row: Int, subheader: Bool = false) -> CGFloat {
        frame.minY + SZNodeLayout.headerHeight + (subheader ? subheaderHeight : 0)
            + SZNodeLayout.bodyTopPadding
            + CGFloat(row) * SZNodeLayout.rowHeight + SZNodeLayout.rowHeight / 2
    }

    /// Which port a traversal's TERMINAL stub leaves by: the outcome the last entry actually
    /// produced, else the face's first declared port. One home, because the capsule's colour
    /// and the stub's origin must name the same port.
    public static func terminalPort(_ outcome: String?, in face: SZAgentGraphFace) -> String {
        outcome ?? face.outcomes.first ?? "done"
    }

    // MARK: - The projected future

    /// Where a projected ("what's coming up next") wire STARTS. An edge leaving the live
    /// node leaves that card's real port — the projection is laid out plan-sized and dropped
    /// onto the chain by centring, but the live card carries what only a run has (the visit
    /// mark, the tally, the stats strip), so its rows sit at a different height than the
    /// translated plan frame's. Every other edge is entirely inside the forecast and rides
    /// the same translation as the cards.
    public static func futureWireOrigin(edge: SZAgentGraph.Edge, liveNode: String,
                                        liveFrame: CGRect, liveFace: SZAgentGraphFace,
                                        liveSubheader: Bool,
                                        projected: CGPoint, offset: CGSize) -> CGPoint {
        guard edge.from == liveNode else {
            return CGPoint(x: projected.x + offset.width, y: projected.y + offset.height)
        }
        return outcomePoint(liveFrame, outcome: edge.outcome, in: liveFace,
                            subheader: liveSubheader)
    }

    /// The plan, re-rooted at `id`: every node reachable over FORWARD edges. The loop back
    /// is a possibility the bounded edge already states, not a path to draw twice — so
    /// bounded edges are dropped from both the reachability and the result. nil when nothing
    /// follows (the live node is the last stage — the terminal will say so when it ends).
    public static func projectedPlan(of graph: SZAgentGraph, from id: String) -> SZAgentGraph? {
        var reach: Set<String> = [id]
        var queue = [id]
        while let current = queue.popLast() {
            for edge in graph.edges
            where edge.from == current && edge.maxTraversals == nil && !reach.contains(edge.to) {
                reach.insert(edge.to)
                queue.append(edge.to)
            }
        }
        guard reach.count > 1 else { return nil }
        // Re-rooted at `id` — a fragment of a traversal already past its door, laid out
        // from `id` by `lay(out:from:)`.
        return SZAgentGraph(nodes: graph.nodes.filter { reach.contains($0.id) },
                            edges: graph.edges.filter {
                                $0.maxTraversals == nil
                                    && reach.contains($0.from) && reach.contains($0.to)
                            })
    }
}
