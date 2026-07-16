// SPDX-License-Identifier: AGPL-3.0-only
// The edge layer: one cubic-bezier curve per connection, drawn between the two ports' world-space socket
// points (resolved by SZGraphCanvasModel). Two visual languages:
//   • DATA (committed) — a solid blue wire with a single glowing cyan-white "comet" head gliding toward
//     the target: the realized pipeline reads as real AND alive (agentic).
//   • FLOW (drawing intent) — a bold violet dashed edge whose dashes flow toward the target, tagged with a
//     "then" pill at the midpoint. It's the user's intent that the agent realizes into a data wire (which
//     resolves it away). Violet keeps it distinct from the blue wire and clear of the app's greens.
// Motion is one TimelineView + one overlay stroke per edge, so animating costs a single timer per edge.
// Control points are horizontal (edges leave/enter sockets flat); stroke weight divides by zoom so edges
// hold a constant on-screen weight at any zoom.
import SwiftUI
import SZCore

struct SZConnectionShape: Shape {
    var from: CGPoint
    var to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        let (c1, c2) = SZCubic.controls(from, to)
        path.addCurve(to: to, control1: c1, control2: c2)
        return path
    }
}

/// Cubic-bezier sampling shared by the edge shape and the midpoint "then" pill. Control points are
/// horizontal handles offset by `dx`, matching `SZConnectionShape`.
enum SZCubic {
    static func controls(_ from: CGPoint, _ to: CGPoint) -> (CGPoint, CGPoint) {
        let dx = max(60, abs(to.x - from.x) * 0.5)
        return (CGPoint(x: from.x + dx, y: from.y), CGPoint(x: to.x - dx, y: to.y))
    }

    static func point(_ from: CGPoint, _ to: CGPoint, _ t: CGFloat) -> CGPoint {
        let (c1, c2) = controls(from, to)
        let u = 1 - t, a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * from.x + b * c1.x + c * c2.x + d * to.x,
                       y: a * from.y + b * c1.y + c * c2.y + d * to.y)
    }
}

/// A thick stroked version of the edge, as a fillable Shape, used to give connections a forgiving
/// tap target for selection (→ unwire).
struct SZConnectionHitShape: Shape {
    var from: CGPoint
    var to: CGPoint
    var lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        SZConnectionShape(from: from, to: to)
            .path(in: rect)
            .strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}

struct SZConnectionLayer: View {
    let graph: SZGraph
    var zoom: CGFloat = 1
    var selectedID: SZConnectionID?
    var hiddenID: SZConnectionID?      // a picked-up edge: invisible (the drag preview stands in), but the
                                       // view STAYS in the tree — removing it would cancel its live drag gesture
    var hiddenNodeIDs: Set<SZNodeID> = []   // mid-drag (ghosted) nodes: their edges hide the same way —
                                            // the panel's drag overlay draws the moving copies
    var space = ""                     // the editor's named gesture coordinate space (drag locations)
    var onSelect: (SZConnectionID) -> Void = { _ in }
    var onDragChanged: (SZConnection, CGPoint) -> Void = { _, _ in }   // grab along the path → pick up
    var onDragEnded: () -> Void = {}

    /// Above this many edges the per-edge motion freezes (static strokes) — the continuous animation cost
    /// scales linearly with edge count, and a very dense graph reads fine without it.
    static let animationEdgeLimit = 60

    var body: some View {
        let animated = graph.connections.count <= Self.animationEdgeLimit
        ZStack {
            ForEach(graph.connections) { connection in
                if let points = SZGraphCanvasModel.endpoints(of: connection, in: graph) {
                    // The visual stroke is an Equatable subtree: a drag tick re-strokes only the edges
                    // whose endpoints actually moved. The hit shape + gestures stay OUT here so their
                    // closures are rebuilt every render and never capture a stale graph.
                    SZConnectionStrokeView(from: points.from, to: points.to, kind: connection.kind,
                                           selected: connection.id == selectedID,
                                           hidden: connection.id == hiddenID
                                               || hiddenNodeIDs.contains(connection.from.node)
                                               || hiddenNodeIDs.contains(connection.to.node),
                                           zoom: zoom, animated: animated)
                        .equatable()
                        .contentShape(SZConnectionHitShape(from: points.from, to: points.to,
                                                           lineWidth: max(14, 18 / max(zoom, 0.1))))
                        .onTapGesture { onSelect(connection.id) }
                        // minimumDistance keeps plain clicks flowing to the tap (select) above.
                        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
                            .onChanged { onDragChanged(connection, $0.location) }
                            .onEnded { _ in onDragEnded() })
                }
            }
        }
    }
}

/// One edge's visible stroke. Equatable over its value inputs, so SwiftUI skips re-stroking every unmoved
/// edge on each drag tick. Internal (not private): the panel's drag-ghost overlay reuses it to draw a
/// moving node's incident edges with identical styling.
struct SZConnectionStrokeView: View, Equatable {
    let from: CGPoint
    let to: CGPoint
    let kind: SZConnectionKind
    let selected: Bool
    let hidden: Bool
    let zoom: CGFloat
    var animated: Bool = true   // false on very dense graphs → static strokes (see SZConnectionLayer)

    var body: some View {
        let z = max(zoom, 0.1)
        return Group {
            if kind == .data { dataBody } else { flowBody }
        }
        // Selection cue on the line itself — a soft glow in the edge's own hue (never a blue/cyan flip
        // for flow). The connected socket dots are separately lit by the panel overlay.
        .shadow(color: selected ? selectionGlow : .clear, radius: selected ? max(2, 5 / z) : 0)
        .opacity(hidden ? 0 : 1)
    }

    private var selectionGlow: Color { (kind == .flow ? SZEdgeStyle.intentViolet : .cyan).opacity(0.75) }

    // MARK: Data (committed) — solid blue wire + a gliding glow head.

    private var dataBody: some View {
        let z = max(zoom, 0.1)
        let width = max(2, (selected ? 5 : 3) / z)
        let base = selected ? Color.cyan : Color.blue
        let lit = max(6, 8 / z), gap = max(90, 130 / z)
        return ZStack {
            SZConnectionShape(from: from, to: to)
                .stroke(base, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            if animated {
                // The comet: a bright core dash + a wider, fainter halo dash (same pattern & phase,
                // so they travel together; the halo replaces a per-frame `.shadow`). Motion runs on
                // the render server — see SZEdgeMotionView.
                SZEdgeMotionView(from: from, to: to, strokes: [
                    SZEdgeDashStroke(color: NSColor(SZEdgeStyle.dataGlow).withAlphaComponent(0.22),
                                     lineWidth: width * 2.0, dash: [lit, gap]),
                    SZEdgeDashStroke(color: NSColor(SZEdgeStyle.dataGlow)
                                         .withAlphaComponent(selected ? 0.7 : 0.95),
                                     lineWidth: width * 0.85, dash: [lit, gap]),
                ], period: 1.6, animated: true, zoom: z)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: Flow (intent) — bold violet dashes flowing to the target + a "then" pill at the midpoint.

    private var flowWidth: CGFloat { max(1.8, 3.2 / max(zoom, 0.1)) }

    private var flowBody: some View {
        ZStack {
            flowingLine
            pill
        }
    }

    private var flowingLine: some View {
        let z = max(zoom, 0.1)
        let dash: [CGFloat] = [max(4, 6 / z), max(3, 5 / z)]
        // Full-length (no end-trim) so dashes flow INTO the socket dots rather than popping into
        // existence in mid-air. `animated: false` freezes the dash phase (a static dashed line) on
        // very dense graphs. Motion runs on the render server — see SZEdgeMotionView.
        return SZEdgeMotionView(from: from, to: to,
                                strokes: [SZEdgeDashStroke(color: NSColor(SZEdgeStyle.intentViolet),
                                                           lineWidth: flowWidth, dash: dash)],
                                period: 1.0, animated: animated, zoom: z)
            .allowsHitTesting(false)
    }

    private var pill: some View {
        let z = max(zoom, 0.1)
        return Text("then")
            .font(.system(size: max(7, 10 / z), weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.82))
            .padding(.horizontal, max(3, 5 / z))
            .padding(.vertical, max(1, 2 / z))
            .background(Capsule().fill(SZEdgeStyle.intentViolet))
            .position(SZCubic.point(from, to, 0.5))
    }
}

/// Edge colours shared by the connection layer, the drag preview, socket dots, and the target/selection
/// highlights, so the whole flow system reads as one hue.
enum SZEdgeStyle {
    /// Violet for the flow/intent edge — reads as sequence/logic rather than a caution amber. Distinct from
    /// the blue data wire, colourblind-separable from it (violet keeps a red channel the blue lacks), and
    /// clear of the app's greens (Ready / Coding / status).
    static let intentViolet = Color(red: 0.60, green: 0.47, blue: 0.90)
    /// Bright cyan-white highlight that rides the blue data wire (the comet head).
    static let dataGlow = Color(red: 0.68, green: 0.90, blue: 1.0)
}
