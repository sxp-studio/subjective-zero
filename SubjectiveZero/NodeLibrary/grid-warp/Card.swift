// Grid Warp card — sixteen draggable control points over the node's live output, with the mesh
// curves drawn through them. The host draws the output thumbnail under the card (contract
// `card.backdrop`); `state.backdrop` is that rect in card-body points, so a point at normalized
// (x, y) sits at backdrop.origin + (x·w, y·h) and a drag maps straight back. The band below the
// thumb carries a readout of the point in hand and Reset.
//
// Gesture contract: `state.live(port, [x, y])` on every drag tick (the render follows the hand),
// ONE `state.commit(port, [x, y])` on release (the value persists). Points show the committed
// snapshot except while the hand owns them (a local drag value wins until the commit lands).
//
// The curves use the same clamped Catmull-Rom as Node.swift's vertex stage, so what the card draws
// is where the image actually goes — a straight control net would disagree with it under any real warp.
import SwiftUI

struct GridWarpCard: View {
    @ObservedObject var state: SZCardState
    /// Point being dragged → its normalized position; nil when the hand is off.
    @State private var dragging: [String: CGPoint] = [:]
    /// The point most recently touched — what the footer reads out.
    @State private var focused: String = "p00"

    private static let ports = (0..<4).flatMap { r in (0..<4).map { c in "p\(r)\(c)" } }
    private static let handleRadius: CGFloat = 4.5
    private static let range: ClosedRange<CGFloat> = -0.25...1.25
    /// Samples per mesh curve. Enough that a hard pull reads as a curve, not a chain of segments.
    private static let samples = 24
    private static let accent = Color(red: 0.4, green: 0.78, blue: 1.0)
    private static let dim = Color(white: 0.5)

    var body: some View {
        let body = state.bodySize ?? CGSize(width: 288, height: 192)
        let frame = state.backdrop ?? fallbackFrame(body)
        let net = Self.ports.map { point(of: $0) }
        ZStack(alignment: .topLeading) {
            // The mesh, so the surface reads even before an input is wired.
            Path { path in
                for line in Self.curves(net) {
                    guard let first = line.first else { continue }
                    path.move(to: place(first, in: frame))
                    for p in line.dropFirst() { path.addLine(to: place(p, in: frame)) }
                }
            }
            .stroke(Self.accent.opacity(0.7), style: StrokeStyle(lineWidth: 0.75))
            .allowsHitTesting(false)
            ForEach(Array(Self.ports.enumerated()), id: \.element) { index, port in
                handle(port: port).position(place(net[index], in: frame))
            }
            footer(body: body)
        }
        .frame(width: body.width, height: body.height, alignment: .topLeading)
    }

    // MARK: - footer (the band the host leaves under the backdrop)

    private func footer(body: CGSize) -> some View {
        let n = point(of: focused)
        let unwired = state.input("input") != nil && !state.connectedInputs.contains("input")
        return HStack(spacing: 8) {
            if unwired {
                Image(systemName: "cable.connector.slash")
                    .font(.system(size: 9, weight: .semibold))
                Text("wire a texture into input")
                    .font(.system(size: 9))
            } else {
                Text(focused)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Self.accent)
                Text(String(format: "%.3f  %.3f", n.x, n.y))
                    .font(.system(size: 9, design: .monospaced))
            }
            Spacer(minLength: 0)
            Button {
                for port in Self.ports { state.commit(port, Self.home(port)) }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 8, weight: .semibold))
                    Text("Reset")
                        .font(.system(size: 9, weight: .medium))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Flatten the mesh back to the full frame")
        }
        .foregroundStyle(Self.dim)
        .frame(width: body.width - 16)
        .position(x: body.width / 2, y: body.height - 6 - 10)   // centered in the footer band under the plate
    }

    // MARK: - handles

    private func handle(port: String) -> some View {
        let wired = state.connectedInputs.contains(port)
        let live = dragging[port] != nil
        let corner = ["p00", "p03", "p30", "p33"].contains(port)
        let r = Self.handleRadius + (corner ? 1.5 : 0)   // the four corners are the ones people grab first
        return Circle()
            .fill(wired ? Color(white: 0.35) : (live ? Color(red: 0.55, green: 0.85, blue: 1.0) : Self.accent))
            .frame(width: r * 2, height: r * 2)
            .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
            .frame(width: 20, height: 20)   // a bigger hit target than the dot
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("sz-card-body"))
                    .onChanged { value in
                        focused = port
                        guard !wired else { return }
                        let n = normalized(value.location)
                        dragging[port] = n
                        state.live(port, [Double(n.x), Double(n.y)])
                    }
                    .onEnded { value in
                        guard !wired else { return }
                        let n = normalized(value.location)
                        state.commit(port, [Double(n.x), Double(n.y)])
                        dragging[port] = nil
                    })
            .help(wired ? "\(port) is driven by a wire" : "drag \(port)")
    }

    // MARK: - the mesh

    /// The four row curves and four column curves through the control net, as sampled polylines.
    private static func curves(_ net: [CGPoint]) -> [[CGPoint]] {
        var lines: [[CGPoint]] = []
        for r in 0..<4 {
            let row = (0..<4).map { net[r * 4 + $0] }
            lines.append((0...samples).map { curve(row, CGFloat($0) / CGFloat(samples)) })
        }
        for c in 0..<4 {
            let column = (0..<4).map { net[$0 * 4 + c] }
            lines.append((0...samples).map { curve(column, CGFloat($0) / CGFloat(samples)) })
        }
        return lines
    }

    /// Node.swift's `cr4`: the interpolating curve through all four points, ends clamped by
    /// reflecting a phantom neighbour, t = 0 at the first point and 1 at the last.
    private static func curve(_ p: [CGPoint], _ t: CGFloat) -> CGPoint {
        let before = CGPoint(x: 2 * p[0].x - p[1].x, y: 2 * p[0].y - p[1].y)
        let after = CGPoint(x: 2 * p[3].x - p[2].x, y: 2 * p[3].y - p[2].y)
        let s = min(max(t, 0), 1) * 3
        let i = Int(min(s.rounded(.down), 2))
        let u = s - CGFloat(i)
        let window = [[before, p[0], p[1], p[2]], [p[0], p[1], p[2], p[3]], [p[1], p[2], p[3], after]][i]
        return segment(window, u)
    }

    private static func segment(_ w: [CGPoint], _ u: CGFloat) -> CGPoint {
        func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * (2 * b + (-a + c) * u + (2 * a - 5 * b + 4 * c - d) * u * u
                   + (-a + 3 * b - 3 * c + d) * u * u * u)
        }
        return CGPoint(x: axis(w[0].x, w[1].x, w[2].x, w[3].x),
                       y: axis(w[0].y, w[1].y, w[2].y, w[3].y))
    }

    // MARK: - geometry

    /// The committed point (or the hand's), in normalized coordinates.
    private func point(of port: String) -> CGPoint {
        if let live = dragging[port] { return live }
        let v = state.input(port)?.defaultDoubles ?? []
        guard v.count >= 2 else { let h = Self.home(port); return CGPoint(x: h[0], y: h[1]) }
        return CGPoint(x: v[0], y: v[1])
    }

    private func place(_ n: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + n.x * frame.width, y: frame.minY + n.y * frame.height)
    }

    private func normalized(_ location: CGPoint) -> CGPoint {
        let frame = state.backdrop ?? fallbackFrame(state.bodySize ?? CGSize(width: 288, height: 192))
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let x = ((location.x - frame.minX) / frame.width).clamped(to: Self.range)
        let y = ((location.y - frame.minY) / frame.height).clamped(to: Self.range)
        return CGPoint(x: x, y: y)
    }

    /// Without a host backdrop (previews off), stage the points where the thumb would sit:
    /// 8pt margins, then an 8pt gap, a 20pt footer band and 6pt bottom breathing.
    private func fallbackFrame(_ body: CGSize) -> CGRect {
        CGRect(x: 8, y: 8, width: body.width - 16, height: body.height - 8 - 8 - 20 - 6)
    }

    /// Where a point sits on the flat mesh, from its name.
    private static func home(_ port: String) -> [Double] {
        let digits = port.dropFirst().compactMap { $0.wholeNumberValue }
        guard digits.count == 2 else { return [0, 0] }
        return [Double(digits[1]) / 3, Double(digits[0]) / 3]
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}

enum SZCardMain {
    static func make(_ state: SZCardState) -> AnyView { AnyView(GridWarpCard(state: state)) }
}
