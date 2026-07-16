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

/// The preview leaf — the ONE view that reads `frame.image`. Aspect-fills its proposed frame (the
/// card's preview region, or the whole card when zoomed out) over a dark placeholder, clipped rounded.
struct SZNodePreviewThumb: View {
    let frame: SZNodePreviewFrame?
    var cornerRadius: CGFloat = SZNodeCardStyle.previewCornerRadius

    var body: some View {
        Rectangle()
            .fill(SZNodeCardStyle.previewPlaceholderFill)
            .overlay {
                if let image = frame?.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
