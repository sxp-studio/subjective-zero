// SPDX-License-Identifier: AGPL-3.0-only
// The node-editor mini map — a glass card in the canvas corner drawing every node card as a tinted
// rect, wires as hairlines and the current viewport as a cyan rectangle. Click = animated recenter
// there (zoom kept); drag = live pan by the same world distance. One `Canvas` (like SZDotGridView),
// not a view per node. Geometry lives on SZMiniMapLayout; the camera stays panel-owned — this view
// only proposes cameras through `onNavigate`.
import SwiftUI
import SZCore

struct SZMiniMapView: View {
    let graph: SZGraph
    let camera: SZCanvasCamera
    let viewSize: CGSize
    /// Graph ▸ Live Previews — card geometry derives from it, so the map's rects do too.
    let previewsEnabled: Bool
    let isRunning: Bool
    let isSelected: (SZNodeID) -> Bool
    let statusOf: (SZNode) -> SZNodeStatus
    /// A proposed camera; `animated` for a click's reframe, false for a drag's live follow.
    let onNavigate: (_ camera: SZCanvasCamera, _ animated: Bool) -> Void
    /// The corner button — frame the whole graph (Graph ▸ Zoom to Fit, animated by the panel).
    let onFit: () -> Void

    static let cornerRadius: CGFloat = 2   // deliberately NOT the node-card radius — a well, not a card
    static let padding: CGFloat = 0        // the map IS the frame: no bezel between pane and content
    /// The card's outer size (map + padding) — the panel uses it to place/hit-test the overlay.
    static var cardSize: CGSize {
        CGSize(width: SZMiniMapLayout.size.width + padding * 2, height: SZMiniMapLayout.size.height + padding * 2)
    }

    /// The camera + layout captured at drag start. The layout is FROZEN for the drag: the extent
    /// re-fits around the moving viewport otherwise, and then the rectangle stands still while the
    /// nodes slide under it. Frozen, the rectangle follows the pointer; release re-fits.
    @State private var dragStart: (camera: SZCanvasCamera, layout: SZMiniMapLayout)?

    private var layout: SZMiniMapLayout {
        dragStart?.layout
            ?? SZMiniMapLayout(graphBounds: SZGraphCanvasModel.worldBounds(of: graph,
                                                                         previewsEnabled: previewsEnabled),
                               viewport: SZMiniMapLayout.viewportWorldRect(camera: camera, viewSize: viewSize))
    }

    var body: some View {
        let layout = layout
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            // The pane: a solid darker cut-out in the canvas (an inset well, not a raised plate).
            context.fill(Path(roundedRect: bounds, cornerRadius: Self.cornerRadius), with: .color(Color(white: 0.055)))
            var wires = Path()
            for connection in graph.connections {
                guard let ends = SZGraphCanvasModel.endpoints(of: connection, in: graph,
                                                             previewsEnabled: previewsEnabled)
                else { continue }
                wires.move(to: layout.mapPoint(world: ends.from))
                wires.addLine(to: layout.mapPoint(world: ends.to))
            }
            context.stroke(wires, with: .color(.white.opacity(0.25)), lineWidth: 0.75)
            for node in graph.nodes {
                let rect = layout.mapRect(world: SZNodeLayout.cardRect(of: node,
                                                                      previewsEnabled: previewsEnabled))
                let status = statusOf(node)
                let fill: Color = SZNodeCanvasContentView.showPill(status, isRunning: isRunning)
                    ? status.color.opacity(0.85)
                    : (node.kind == .prompt ? Color(white: 0.34) : Color(white: 0.28))
                let path = Path(roundedRect: rect, cornerRadius: 1.5)
                context.fill(path, with: .color(fill))
                if isSelected(node.id) {
                    context.stroke(path, with: .color(SZNodeCardStyle.selectionStroke), lineWidth: 1)
                }
            }
            let viewport = layout.mapRect(world: SZMiniMapLayout.viewportWorldRect(camera: camera, viewSize: viewSize))
                .intersection(bounds)
            context.fill(Path(viewport), with: .color(.cyan.opacity(0.08)))
            context.stroke(Path(viewport.insetBy(dx: 0.5, dy: 0.5)), with: .color(.cyan.opacity(0.9)), lineWidth: 1)
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .padding(Self.padding)
        // Recessed edge: a dark line just inside, a whisper of light just outside. No shadow, no glass.
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(.black.opacity(0.6), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius + 0.5).stroke(.white.opacity(0.05), lineWidth: 1).padding(-0.5))
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))   // swallow taps: never clear-selection/marquee
        .gesture(navigationGesture(layout))
        .help("Mini map — click to center, drag to pan")
        // Declared after the gesture so the button, not the map drag, takes the click.
        .overlay(alignment: .topTrailing) { SZMiniMapFitButton(action: onFit).padding(4) }
    }

    /// Click (no travel) → animated recenter under the click; drag → live pan from the drag-start
    /// camera. Locations are card-local; the map is inset by `padding`.
    private func navigationGesture(_ layout: SZMiniMapLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? (camera: camera, layout: layout)
                if dragStart == nil { dragStart = start }
                guard value.translation != .zero else { return }
                onNavigate(start.layout.cameraDragging(by: value.translation, from: start.camera), false)
            }
            .onEnded { value in
                defer { dragStart = nil }
                if value.translation == .zero {
                    let local = CGPoint(x: value.location.x - Self.padding, y: value.location.y - Self.padding)
                    onNavigate(layout.cameraCentering(mapPoint: local, camera: camera, viewSize: viewSize), true)
                }
            }
    }
}

/// The map's recenter control: a small glass circle (the HUD icon recipe at map scale) that frames
/// the whole graph.
private struct SZMiniMapFitButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "scope")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.white.opacity(hover ? 0.22 : 0.10)))
        }
        .buttonStyle(.plain)
        .trackingHover($hover)
        .help("Zoom to fit")
    }
}
