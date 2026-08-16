// Corner Pin card — four draggable corner handles over the node's live output. The host draws
// the output thumbnail under the card (contract `card.backdrop`); `state.backdrop` is that
// rect in card-body points, so a handle at normalized corner (x, y) sits at
// backdrop.origin + (x·w, y·h) and a drag maps straight back to normalized coordinates. The band
// below the thumb (the host leaves a footer) carries a readout of the corner in hand and Reset.
//
// Gesture contract: `state.live(port, [x, y])` on every drag tick (the render follows the hand),
// ONE `state.commit(port, [x, y])` on release (the value persists). Handles show the committed
// snapshot except while the hand owns them (a local drag value wins until the commit lands).
import SwiftUI

struct CornerPinCard: View {
    @ObservedObject var state: SZCardState
    /// Corner being dragged → its normalized position; nil when the hand is off.
    @State private var dragging: [String: CGPoint] = [:]
    /// The corner most recently touched — what the footer reads out.
    @State private var focused: String = "tl"

    private static let ports = ["tl", "tr", "br", "bl"]
    private static let handleRadius: CGFloat = 6
    private static let range: ClosedRange<CGFloat> = -0.25...1.25
    private static let accent = Color(red: 0.4, green: 0.78, blue: 1.0)
    private static let dim = Color(white: 0.5)

    var body: some View {
        let body = state.bodySize ?? CGSize(width: 288, height: 192)
        let frame = state.backdrop ?? fallbackFrame(body)
        let corners = Self.ports.map { port in (port, position(of: port, in: frame)) }
        ZStack(alignment: .topLeading) {
            // The projected quad's outline, so the surface reads even before an input is wired.
            Path { path in
                guard let first = corners.first?.1 else { return }
                path.move(to: first)
                for (_, point) in corners.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
            }
            .stroke(Self.accent.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .allowsHitTesting(false)
            ForEach(corners, id: \.0) { port, point in
                handle(port: port).position(point)
            }
            footer(body: body)
        }
        .frame(width: body.width, height: body.height, alignment: .topLeading)
    }

    // MARK: - footer (the band the host leaves under the backdrop)

    private func footer(body: CGSize) -> some View {
        let n = dragging[focused] ?? committed(focused)
        let unwired = state.input("input") != nil && !state.connectedInputs.contains("input")
        return HStack(spacing: 8) {
            if unwired {
                Image(systemName: "cable.connector.slash")
                    .font(.system(size: 9, weight: .semibold))
                Text("wire a texture into input")
                    .font(.system(size: 9))
            } else {
                Text(focused.uppercased())
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
            .help("Reset the four corners to the full frame")
        }
        .foregroundStyle(Self.dim)
        .frame(width: body.width - 16)
        .position(x: body.width / 2, y: body.height - 6 - 10)   // centered in the footer band under the plate
    }

    // MARK: - handles

    private func handle(port: String) -> some View {
        let wired = state.connectedInputs.contains(port)
        let live = dragging[port] != nil
        return ZStack {
            Circle()
                .fill(wired ? Color(white: 0.35) : (live ? Color(red: 0.55, green: 0.85, blue: 1.0) : Self.accent))
                .frame(width: Self.handleRadius * 2, height: Self.handleRadius * 2)
                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
            Text(port)
                .font(.system(size: 6.5, weight: .bold))
                .foregroundStyle(.black.opacity(0.8))
        }
        .frame(width: 24, height: 24)   // a bigger hit target than the dot
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

    // MARK: - geometry

    /// The committed corner (or the hand's), placed on the backdrop.
    private func position(of port: String, in frame: CGRect) -> CGPoint {
        let n = dragging[port] ?? committed(port)
        return CGPoint(x: frame.minX + n.x * frame.width, y: frame.minY + n.y * frame.height)
    }

    private func committed(_ port: String) -> CGPoint {
        let v = state.input(port)?.defaultDoubles ?? []
        guard v.count >= 2 else { let h = Self.home(port); return CGPoint(x: h[0], y: h[1]) }
        return CGPoint(x: v[0], y: v[1])
    }

    private func normalized(_ location: CGPoint) -> CGPoint {
        let frame = state.backdrop ?? fallbackFrame(state.bodySize ?? CGSize(width: 288, height: 192))
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let x = ((location.x - frame.minX) / frame.width).clamped(to: Self.range)
        let y = ((location.y - frame.minY) / frame.height).clamped(to: Self.range)
        return CGPoint(x: x, y: y)
    }

    /// Without a host backdrop (previews off), stage the handles where the thumb would sit:
    /// 8pt margins, then an 8pt gap, a 20pt footer band and 6pt bottom breathing.
    private func fallbackFrame(_ body: CGSize) -> CGRect {
        CGRect(x: 8, y: 8, width: body.width - 16, height: body.height - 8 - 8 - 20 - 6)
    }

    private static func home(_ port: String) -> [Double] {
        switch port {
        case "tl": [0, 0]
        case "tr": [1, 0]
        case "br": [1, 1]
        default: [0, 1]
        }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}

enum SZCardMain {
    static func make(_ state: SZCardState) -> AnyView { AnyView(CornerPinCard(state: state)) }
}
