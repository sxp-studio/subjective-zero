// SPDX-License-Identifier: AGPL-3.0-only
// The Agent Graph panel's WORLD SPACE — the subtree the camera transforms. Split out of
// `SZAgentGraphPanel`, which keeps the camera, the mode and the sidebar: nothing here reads
// the camera except as a zoom NUMBER, so the seam was already there.
import SwiftUI
import SZCore

/// The world-space subtree: wires under cards under sockets, BOTH modes drawn by the same
/// card / wire / socket renderers over the same layout metrics — the views differ only in
/// where the frames come from (the plan's ranked layout vs the record's unrolled chain).
struct SZAgentGraphCanvasContent: View {
    let graph: SZAgentGraph
    /// The record whose trace the Run view unrolls; nil = the Plan view (no live state).
    let record: SZAgentGraphRun?
    let mode: SZAgentGraphPanelMode
    let zoom: CGFloat
    let nudges: [String: CGSize]
    let onNudge: (String, CGSize) -> Void

    @State private var dragging: (id: String, from: CGSize)?

    var body: some View {
        Group {
            switch mode {
            case .plan: planView
            case .run: runView
            }
        }
        // A mode switch can tear the plan subtree down mid-drag, and `.onEnded` never
        // fires — without this the next drag of the same card resumes from the aborted
        // gesture's base.
        .onChange(of: mode) { _, _ in dragging = nil }
    }

    // MARK: Shared renderers — one card, one socket layer, for both modes

    private func card(_ face: SZAgentGraphFace, state: SZAgentGraphCardState, frame: CGRect,
                      visitLabel: String? = nil,
                      stats: SZAgentGraphCardStats? = nil) -> some View {
        SZAgentGraphCardView(face: face, state: state, visitLabel: visitLabel, stats: stats)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
    }

    /// The same 12pt dots the artifact canvas puts on its cards — an input on the left, one
    /// per outcome row on the right, so a node visibly has PORTS rather than just wires
    /// arriving somewhere near it. Drawn last so they sit ABOVE the cards; decorative only.
    @ViewBuilder
    private func socketLayer(face: SZAgentGraphFace, frame: CGRect,
                             fired: String? = nil, decided: Bool = false,
                             subheader: Bool = false) -> some View {
        let input = SZAgentGraphLayout.inputPoint(frame)
        SZAgentGraphSocket(colour: SZAgentGraphStyle.neutral)
            .position(x: input.x, y: input.y)
        ForEach(face.outcomes, id: \.self) { outcome in
            let point = SZAgentGraphLayout.outcomePoint(frame, outcome: outcome, in: face,
                                                        subheader: subheader)
            // A dot follows its row: once a node has decided, the port it did NOT take
            // recedes with its label rather than staying bright.
            let faded = decided && fired != outcome
            SZAgentGraphSocket(colour: SZAgentGraphStyle.colour(for: outcome, in: face.form),
                               faded: faded)
                .position(x: point.x, y: point.y)
        }
    }

    // MARK: Plan — the authored graph, a static document

    /// No trace state on purpose: live ticks made a loop's second round overwrite its first
    /// on the plan's single card, which is exactly the ambiguity the Run view exists to
    /// resolve. The plan answers "what is the graph"; the run answers "what happened".
    private var planView: some View {
        let placement = nudged(SZAgentGraphLayout.lay(out: graph))
        return ZStack(alignment: .topLeading) {
            ForEach(graph.edges.indices, id: \.self) { i in
                let edge = graph.edges[i]
                if let path = wirePath(edge, placement: placement, in: graph) {
                    SZAgentGraphWire(path: path, outcome: edge.outcome,
                                     bounded: edge.maxTraversals != nil, zoom: zoom,
                                     fromForm: fromForm(of: edge, in: graph))
                }
            }
            ForEach(graph.nodes) { node in
                if let frame = placement.frames[node.id] {
                    card(SZAgentGraphLayout.face(of: node, in: graph), state: .notRun,
                         frame: frame)
                        .gesture(drag(node.id))
                }
            }
            ForEach(graph.nodes) { node in
                if let frame = placement.frames[node.id] {
                    socketLayer(face: SZAgentGraphLayout.face(of: node, in: graph), frame: frame)
                }
            }
            .allowsHitTesting(false)

            planEntryStubs(placement: placement)
                .allowsHitTesting(false)
        }
    }

    /// One `start` stub per declared entry, labelled with the kind that enters there — the
    /// entry map drawn as the front doors it is. Two kinds entering the SAME node stack
    /// their capsules rather than overprinting.
    @ViewBuilder
    private func planEntryStubs(placement: SZAgentGraphLayout.Placement) -> some View {
        let entries = graph.entry.sorted { entryRank($0.key) < entryRank($1.key) }
        ForEach(Array(entries.enumerated()), id: \.element.key) { index, entry in
            if let frame = placement.frames[entry.value] {
                let stacked = entries.prefix(index).filter { $0.value == entry.value }.count
                let end = CGPoint(x: SZAgentGraphLayout.inputPoint(frame).x,
                                  y: SZAgentGraphLayout.inputPoint(frame).y + CGFloat(stacked) * 16)
                let start = CGPoint(x: end.x - 46, y: end.y)
                let z = max(zoom, 0.1)
                SZAgentGraphWire(path: (start, end), outcome: "ok", bounded: false, zoom: zoom)
                Text(entry.key.rawValue)
                    .font(.system(size: max(7, 10 / z), weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .padding(.horizontal, max(3, 5 / z))
                    .padding(.vertical, max(1, 2 / z))
                    .background(Capsule().fill(SZAgentGraphStyle.done))
                    .position(x: start.x - 16, y: start.y)
            }
        }
    }

    /// CAUSE order, not alphabetical: a `build`/`request` starts a thread, `item` is its
    /// work, `settled` answers — in that order the doors face their lanes.
    private func entryRank(_ kind: SZMessageKind) -> Int {
        switch kind {
        case .build: 0
        case .request: 1
        case .chat: 2
        case .item: 3
        case .settled: 4
        case .steer: 5
        }
    }

    // MARK: Run — the executed trace, loops unrolled, the future projected

    /// One card per trace ENTRY, in traversal order, left to right. A node visited twice is
    /// two cards, each with its own outcome — the whole reason the trace exists. Wires and
    /// sockets are the plan's own renderers over chain frames; wires take the colour of the
    /// outcome that actually moved the traversal forward.
    @ViewBuilder
    private var runView: some View {
        if let record {
            let frames = SZAgentGraphLayout.runFrames(for: record, graph: graph)
            // POSITIONS, not ordinals, index the frames: ordinals are the producer's naming
            // and nothing here may assume they are 1…n — the panel renders what it was
            // handed rather than crashing on a slipped invariant.
            ZStack(alignment: .topLeading) {
                ForEach(Array(record.trace.enumerated()), id: \.element.id) { position, entry in
                    let face = SZAgentGraphLayout.runFace(for: entry, in: graph)
                    let frame = frames[position]
                    if position > 0 {
                        let prev = record.trace[position - 1]
                        let prevFace = SZAgentGraphLayout.runFace(for: prev, in: graph)
                        let prevOutcome = SZAgentGraphLayout.terminalPort(prev.outcome, in: prevFace)
                        SZAgentGraphWire(
                            path: (SZAgentGraphLayout.outcomePoint(
                                       frames[position - 1], outcome: prevOutcome, in: prevFace,
                                       subheader: hasSubheader(prev, record)),
                                   SZAgentGraphLayout.inputPoint(frame)),
                            outcome: prevOutcome, bounded: false, zoom: zoom,
                            fromForm: prevFace.form)
                    }
                    card(face, state: entryState(entry, record), frame: frame,
                         visitLabel: record.visits(of: entry.node) > 1
                             ? "visit \(record.visitNumber(of: entry))" : nil,
                         stats: stats(for: entry, face: face))
                }
                ForEach(Array(record.trace.enumerated()), id: \.element.id) { position, entry in
                    let face = SZAgentGraphLayout.runFace(for: entry, in: graph)
                    socketLayer(face: face, frame: frames[position],
                                fired: entry.outcome, decided: entry.outcome != nil,
                                subheader: hasSubheader(entry, record))
                }
                .allowsHitTesting(false)

                if let firstFrame = frames.first {
                    origin(into: firstFrame)
                }
                if let last = record.trace.last, let lastFrame = frames.last {
                    let lastFace = SZAgentGraphLayout.runFace(for: last, in: graph)
                    // The record's CONCLUSION picks the terminal — every ending is
                    // classified, and each classification gets its honest capsule. Still
                    // traversing = the future.
                    switch record.conclusion {
                    case .none:
                        futureLayer(from: last, frame: lastFrame, face: lastFace,
                                    subheader: hasSubheader(last, record))
                    case .ended:
                        // A traversal that ended on purpose exits BLUE; one that ended on an
                        // error outcome keeps the failed orange — the capsule states
                        // validity, the port hue stays the wire's business.
                        let outcome = SZAgentGraphLayout.terminalPort(last.outcome, in: lastFace)
                        let invalid = outcome == "error" || outcome.hasPrefix("error")
                            || outcome.hasPrefix("failed")
                        terminal(after: lastFrame, face: lastFace, outcome: last.outcome,
                                 label: "end",
                                 colour: invalid ? SZAgentGraphStyle.failed : SZAgentGraphStyle.ended,
                                 subheader: hasSubheader(last, record))
                    case .failed, .defect:
                        terminal(after: lastFrame, face: lastFace, outcome: last.outcome,
                                 label: "failed", colour: SZAgentGraphStyle.failed,
                                 subheader: hasSubheader(last, record))
                    case .cancelled:
                        terminal(after: lastFrame, face: lastFace, outcome: last.outcome,
                                 label: "stopped", colour: SZAgentGraphStyle.neutral,
                                 subheader: hasSubheader(last, record))
                    case .declined:
                        // A refusal in the graph's own words rides the transcript; the
                        // canvas keeps the neutral capsule — deliberately not red.
                        terminal(after: lastFrame, face: lastFace, outcome: last.outcome,
                                 label: "declined", colour: SZAgentGraphStyle.neutral,
                                 subheader: hasSubheader(last, record))
                    }
                }
            }
        }
    }

    private func hasSubheader(_ entry: SZAgentGraphRun.Entry, _ record: SZAgentGraphRun) -> Bool {
        SZAgentGraphLayout.hasSubheader(entry, in: record,
                                        face: SZAgentGraphLayout.runFace(for: entry, in: graph))
    }

    private func entryState(_ entry: SZAgentGraphRun.Entry,
                            _ record: SZAgentGraphRun) -> SZAgentGraphCardState {
        let face = SZAgentGraphLayout.runFace(for: entry, in: graph)
        return SZAgentGraphCardState(phase: entry.phase, outcome: entry.outcome,
                                     detail: entry.detail,
                                     tally: face.form == .dispatch ? record.tally : nil)
    }

    /// The stat line a Run card carries: wall time, ticking while the visit runs, frozen
    /// once it settles. nil on a form that spends nothing — the SAME condition the layout
    /// sizes the footer by.
    private func stats(for entry: SZAgentGraphRun.Entry,
                       face: SZAgentGraphFace) -> SZAgentGraphCardStats? {
        guard SZAgentGraphLayout.spends(face.form), let startedAt = entry.startedAt else { return nil }
        return SZAgentGraphCardStats(startedAt: startedAt, duration: entry.duration)
    }

    /// "The traversal entered here" — the `end` capsule's mirror image. GREEN, deliberately
    /// apart from the outcome-coloured `end`: entering is "go".
    @ViewBuilder
    private func origin(into frame: CGRect) -> some View {
        let end = SZAgentGraphLayout.inputPoint(frame)
        let start = CGPoint(x: end.x - 46, y: end.y)
        let z = max(zoom, 0.1)
        SZAgentGraphWire(path: (start, end), outcome: "ok", bounded: false, zoom: zoom)
        Text("start")
            .font(.system(size: max(7, 10 / z), weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.82))
            .padding(.horizontal, max(3, 5 / z))
            .padding(.vertical, max(1, 2 / z))
            .background(Capsule().fill(SZAgentGraphStyle.done))
            .position(x: start.x - 14, y: start.y)
    }

    /// "What's coming up next": the plan's forward continuation from the live node,
    /// projected as a faded, dash-wired subgraph after the chain. It is the SAME ranked
    /// layout the plan uses, re-rooted at the live node and aligned onto its card — a
    /// forecast drawn in the plan's own hand, visibly not yet real. Forward edges only.
    @ViewBuilder
    private func futureLayer(from last: SZAgentGraphRun.Entry, frame: CGRect,
                             face liveFace: SZAgentGraphFace, subheader: Bool) -> some View {
        if let future = SZAgentGraphLayout.projectedPlan(of: graph, from: last.node) {
            let placement = SZAgentGraphLayout.lay(out: future)
            if let entryFrame = placement.frames[last.node] {
                let dx = frame.midX - entryFrame.midX
                let dy = frame.midY - entryFrame.midY
                Group {
                    ForEach(future.edges.indices, id: \.self) { i in
                        let edge = future.edges[i]
                        if let path = wirePath(edge, placement: placement, in: future) {
                            let start = SZAgentGraphLayout.futureWireOrigin(
                                edge: edge, liveNode: last.node, liveFrame: frame,
                                liveFace: liveFace, liveSubheader: subheader,
                                projected: path.0, offset: CGSize(width: dx, height: dy))
                            SZAgentGraphWire(path: (start, path.1.offsetBy(dx: dx, dy: dy)),
                                             outcome: edge.outcome,
                                             bounded: false, zoom: zoom,
                                             fromForm: fromForm(of: edge, in: future),
                                             projected: true)
                        }
                    }
                    ForEach(future.nodes) { node in
                        if node.id != last.node, let nodeFrame = placement.frames[node.id] {
                            let moved = nodeFrame.offsetBy(dx: dx, dy: dy)
                            card(SZAgentGraphLayout.face(of: node, in: future), state: .notRun,
                                 frame: moved)
                            socketLayer(face: SZAgentGraphLayout.face(of: node, in: future),
                                        frame: moved)
                        }
                    }
                }
                .opacity(0.4)
            }
        }
    }

    /// "The traversal stopped here" — a short stub out of the port it left by, into a
    /// capsule styled exactly like the back edge's `loop` pill: wire annotations are the
    /// flow's one vocabulary for words.
    @ViewBuilder
    private func terminal(after frame: CGRect, face: SZAgentGraphFace,
                          outcome: String?, label: String,
                          colour: Color?, subheader: Bool = false) -> some View {
        let port = SZAgentGraphLayout.terminalPort(outcome, in: face)
        let capsule = colour ?? SZAgentGraphStyle.colour(for: port, in: face.form)
        let start = SZAgentGraphLayout.outcomePoint(frame, outcome: port, in: face,
                                                    subheader: subheader)
        let end = CGPoint(x: start.x + 46, y: start.y)
        let z = max(zoom, 0.1)
        // The stub carries the last node's form so it matches its capsule and socket.
        SZAgentGraphWire(path: (start, end), outcome: port, bounded: false, zoom: zoom,
                         fromForm: face.form)
        Text(label)
            .font(.system(size: max(7, 10 / z), weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.82))
            .padding(.horizontal, max(3, 5 / z))
            .padding(.vertical, max(1, 2 / z))
            .background(Capsule().fill(capsule))
            .position(x: end.x + 12 + CGFloat(label.count - 3) * 3, y: end.y)
    }

    // MARK: Plumbing

    /// Nodes are draggable so a dense stretch can be pulled apart to read it. Divided by
    /// `zoom` so a card tracks the cursor rather than sliding faster than it zoomed out.
    private func drag(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragging?.id != id { dragging = (id, nudges[id] ?? .zero) }
                let base = dragging?.from ?? .zero
                onNudge(id, CGSize(width: base.width + value.translation.width / zoom,
                                   height: base.height + value.translation.height / zoom))
            }
            .onEnded { _ in dragging = nil }
    }

    private func nudged(_ placement: SZAgentGraphLayout.Placement) -> SZAgentGraphLayout.Placement {
        guard !nudges.isEmpty else { return placement }
        var frames = placement.frames
        for (id, delta) in nudges where frames[id] != nil {
            frames[id] = frames[id]!.offsetBy(dx: delta.width, dy: delta.height)
        }
        return .init(frames: frames, bounds: frames.values.reduce(.null) { $0.union($1) })
    }

    /// The FROM node's form, so a wire colours like the socket it leaves.
    private func fromForm(of edge: SZAgentGraph.Edge,
                          in graph: SZAgentGraph) -> SZAgentGraphFace.Form? {
        graph.node(edge.from).map { SZAgentGraphLayout.face(of: $0, in: graph).form }
    }

    private func wirePath(_ edge: SZAgentGraph.Edge, placement: SZAgentGraphLayout.Placement,
                          in graph: SZAgentGraph) -> (CGPoint, CGPoint)? {
        guard let from = placement.frames[edge.from], let to = placement.frames[edge.to],
              let fromNode = graph.node(edge.from) else { return nil }
        return (SZAgentGraphLayout.outcomePoint(from, outcome: edge.outcome,
                                                in: SZAgentGraphLayout.face(of: fromNode, in: graph)),
                SZAgentGraphLayout.inputPoint(to))
    }
}

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}

/// A port dot, matching `SZPortSocket`'s size and its unconnected dimming.
struct SZAgentGraphSocket: View {
    let colour: Color
    var faded: Bool = false
    var body: some View {
        Circle()
            .fill(colour.opacity(faded ? 0.3 : 0.85))
            .frame(width: SZNodeLayout.socketSize, height: SZNodeLayout.socketSize)
            .overlay(Circle().strokeBorder(SZDotGridView.canvasBackground, lineWidth: 1.5))
    }
}
