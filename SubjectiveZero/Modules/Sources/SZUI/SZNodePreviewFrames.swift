// SPDX-License-Identifier: AGPL-3.0-only
// Live node-preview plumbing: per-node observable frame boxes + the thumb leaf view. The host
// writes `SZNodePreviewFrame.surface` (~15 Hz, IOSurfaces published by the runtime's preview
// stream); ONLY `SZPreviewLayerView` reads it, so Observation invalidates that leaf alone — the
// Equatable-gated card around it never re-renders on a frame tick. The surface goes straight to
// `CALayer.contents`: a thumb frame is GPU-composited end to end, no CPU pixels anywhere.
import CoreGraphics
import IOSurface
import SwiftUI
import SZCore

/// One node's latest preview frame. A stable per-node box: the card stores the reference (excluded
/// from its `==`, like its closures) and the host mutates the contents. The surfaces alternate per
/// pass (double buffer), so assigning `contents` always changes identity — which is exactly what
/// makes CA recomposite.
@Observable @MainActor
public final class SZNodePreviewFrame {
    public var surface: IOSurface?
    public init() {}
}

/// The per-node registry of preview boxes, owned by the host and threaded (as an uncompared ref) down
/// to the cards. Boxes are stable per node id — handing the SAME box to every render is what keeps the
/// card views' `==` exclusion sound.
@MainActor
public final class SZNodePreviewFrames {
    private var boxes: [SZNodeID: SZNodePreviewFrame] = [:]
    public init() {}

    /// The (stable) box for a node, created on first ask.
    public func frame(for id: SZNodeID) -> SZNodePreviewFrame {
        if let box = boxes[id] { return box }
        let box = SZNodePreviewFrame()
        boxes[id] = box
        return box
    }

    /// Blank every thumb (gate off / project closed) without dropping the boxes — cards keep their
    /// stable refs and just show the placeholder.
    public func clear() {
        for box in boxes.values { box.surface = nil }
    }

    /// Drop boxes for nodes that no longer exist (deletes / project switch).
    public func prune(keeping ids: Set<SZNodeID>) {
        boxes = boxes.filter { ids.contains($0.key) }
    }
}

/// The preview leaf — the ONE consumer of `frame.surface`. A layer-backed NSView whose CALayer
/// `contents` IS the surface: a new frame is one GPU texture swap, composited by Core Animation at
/// whatever scale the canvas zoom imposes. Routing the 15 Hz stream through a SwiftUI `Image`
/// instead re-rasterized the thumb at SCREEN resolution on every frame — cost ∝ zoom², which read
/// as "lag when zoomed in". The view observes its box directly (withObservationTracking), so a
/// frame tick never re-enters SwiftUI at all.
struct SZNodePreviewThumb: NSViewRepresentable {
    let frame: SZNodePreviewFrame?
    var cornerRadius: CGFloat = SZNodeCardStyle.previewCornerRadius

    func makeNSView(context: Context) -> SZPreviewLayerView { SZPreviewLayerView() }

    func updateNSView(_ view: SZPreviewLayerView, context: Context) {
        view.cornerRadius = cornerRadius
        view.bind(to: frame)
    }
}

/// The backing view: dark placeholder fill, aspect-fill contents, rounded clip. `bind(to:)` installs
/// a self-re-arming observation on the box — each image write lands as a bare `layer.contents`
/// assignment on the main actor.
final class SZPreviewLayerView: NSView {
    private var box: SZNodePreviewFrame?
    /// Bumped on every rebind; a pending re-arm from a PREVIOUS binding sees a stale generation and
    /// dies instead of stacking a second live observation on the current box.
    private var generation = 0

    var cornerRadius: CGFloat = SZNodeCardStyle.previewCornerRadius {
        didSet { layer?.cornerRadius = cornerRadius }
    }

    /// "No signal": a dim glyph over the placeholder while no frame has arrived — distinguishes
    /// "nothing captured yet / nothing to capture" from a node whose real output is black.
    private let noSignalLayer = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(SZNodeCardStyle.previewPlaceholderFill).cgColor
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        layer?.cornerRadius = cornerRadius
        noSignalLayer.contents = Self.noSignalGlyph
        noSignalLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(noSignalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        let side: CGFloat = 20
        noSignalLayer.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                                     width: side, height: side)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        noSignalLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// The glyph image, rendered once (dim white `video.slash`).
    private static let noSignalGlyph: CGImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "video.slash", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let size = CGSize(width: 40, height: 40)   // 2x headroom for Retina
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.withAlphaComponent(0.3).set()
            symbol.draw(in: rect.insetBy(dx: 4, dy: 4))
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }()

    /// Point at (or away from) a frame box. Idempotent per box: re-binding the same box (every
    /// SwiftUI update pass) must not stack observations — each surface write re-arms exactly one.
    func bind(to newBox: SZNodePreviewFrame?) {
        guard box !== newBox else { return }
        box = newBox
        generation += 1
        observeBox(generation: generation)
    }

    private func observeBox(generation: Int) {
        guard generation == self.generation else { return }   // superseded by a later bind
        guard let box else {
            layer?.contents = nil
            noSignalLayer.isHidden = false
            return
        }
        withObservationTracking {
            layer?.contents = box.surface
            noSignalLayer.isHidden = box.surface != nil
        } onChange: { [weak self] in
            // Observation fires once per change and must re-arm; hop to main — the write side
            // (the host's frame sink) is already MainActor, but the closure contract is nonisolated.
            Task { @MainActor [weak self] in
                self?.observeBox(generation: generation)
            }
        }
    }
}
