// SPDX-License-Identifier: AGPL-3.0-only
// Live node-preview plumbing: per-node observable frame boxes + the thumb leaf view. The host's
// capture driver writes `SZNodePreviewFrame.image` at ~15 Hz; ONLY `SZNodePreviewThumb` reads it, so
// Observation invalidates that leaf alone — the Equatable-gated card around it never re-renders on a
// frame tick. Leaf-only writes are what keep a continuous stream off the card render path.
import CoreGraphics
import SwiftUI
import SZCore

/// One node's latest preview frame. A stable per-node box: the card stores the reference (excluded
/// from its `==`, like its closures) and the driver mutates the contents.
@Observable @MainActor
public final class SZNodePreviewFrame {
    public var image: CGImage?
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
    public func clearImages() {
        for box in boxes.values { box.image = nil }
    }

    /// Drop boxes for nodes that no longer exist (deletes / project switch).
    public func prune(keeping ids: Set<SZNodeID>) {
        boxes = boxes.filter { ids.contains($0.key) }
    }
}

/// The preview leaf — the ONE consumer of `frame.image`. A layer-backed NSView whose CALayer
/// `contents` IS the frame: a new frame is one GPU texture swap, composited by Core Animation at
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

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        layer?.cornerRadius = cornerRadius
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// Point at (or away from) a frame box. Idempotent per box: re-binding the same box (every
    /// SwiftUI update pass) must not stack observations.
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
            return
        }
        withObservationTracking {
            layer?.contents = box.image
        } onChange: { [weak self] in
            // Observation fires once per change and must re-arm; hop to main — the write side
            // (the host driver) is already MainActor, but the closure contract is nonisolated.
            Task { @MainActor [weak self] in
                self?.observeBox(generation: generation)
            }
        }
    }
}
