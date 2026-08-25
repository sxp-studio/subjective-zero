// SPDX-License-Identifier: AGPL-3.0-only
// The custom-card body region: the node's live-output thumbnail as a backdrop (when the contract
// asks for one), the mounted card's SwiftUI content on top at `.ready`, a spinner while its dylib
// compiles, a warning chip when the latest edit failed but the previous build still runs, and the
// error chip + "Hide Custom Card" at `.failed`. The failed frame KEEPS its committed footprint — geometry
// is graph truth; reverting is an explicit body commit through the provider.
//
// Card content arrives as the dylib's root view VALUE (AnyView), not an embedded NSView: it joins
// this hierarchy as first-class SwiftUI content, so the camera's `.scaleEffect` re-renders it at
// the effective composite scale every frame. The mount is an observable per-node box (the
// `SZNodePreviewFrame` pattern): the host writes it, this leaf reads it, so a state/content/backdrop
// change re-renders exactly this region — never the card, never the canvas.
import SwiftUI
import SZCore

/// The lifecycle of one node's mounted custom card. `ready.warning` is the keep-last-good rule made
/// visible: a red hot reload keeps the previous build mounted and rides its first error line here;
/// `failed` is only for a card that never mounted (first compile red, or no Card.swift on disk).
public enum SZCardMountState: Equatable, Sendable {
    case loading
    case ready(warning: String?)
    case failed(message: String)
}

/// One node's mount, as the host writes it and the card region reads it. Stable per node.
@Observable
@MainActor
public final class SZCardMount {
    public var state: SZCardMountState = .loading
    /// The dylib's root view VALUE while `.ready`.
    public var content: AnyView?
    /// Where the live-output thumbnail sits under the card, in region points (nil = no backdrop).
    public var backdrop: CGRect?
    public init() {}
}

/// The node panel's window into the app's card host — a stable object ref (the
/// `SZNodePreviewFrames` pattern), excluded from every view `==`.
@MainActor
public protocol SZCustomCardProvider: AnyObject {
    /// The node's mount box, nil when nothing is mounted (yet).
    func mount(for node: SZNodeID) -> SZCardMount?
    /// Whether `node`'s folder holds a `Card.swift` — gates the context-menu rows and the file button's tooltip.
    func hasCardSource(for node: SZNodeID) -> Bool
    /// Show the custom card (`on`) or fall back to port rows: an explicit body commit; the
    /// `Card.swift` on disk is never touched.
    func setCardShown(node: SZNodeID, _ on: Bool)
    /// Open the node's `Card.swift` in the user's editor (saving hot-reloads the card).
    func openCardSource(node: SZNodeID)
    /// Scaffold a starter `Card.swift` into the node's folder, show the card, and open the file.
    func createCard(node: SZNodeID)
}

struct SZCustomCardView: View {
    let nodeID: SZNodeID
    let bodySize: CGSize                       // committed footprint (SZNodeLayout custom terms)
    var mount: SZCardMount?                    // observed here, never compared
    var backdropFrame: SZNodePreviewFrame?     // the node's thumb box (excluded from ==)
    var provider: (any SZCustomCardProvider)?  // actions only

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let rect = mount?.backdrop {
                // Square: overlay handles sit ON the image corners, and a rounded thumb would put
                // them over the card background instead of pixels.
                SZNodePreviewThumb(frame: backdropFrame, cornerRadius: 0)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
            }
            switch mount?.state {
            case .ready(let warning):
                if let content = mount?.content {
                    content
                } else {
                    spinner
                }
                if let warning { warningChip(warning) }
            case .failed(let message):
                errorChip(message)
            case .loading, .none:
                spinner
            }
        }
        .frame(width: bodySize.width, height: bodySize.height, alignment: .topLeading)
        // The card's own space: its gestures resolve against it (top-aligned, so content y == body
        // y while the frame clips overflow that auto-size hasn't committed yet).
        .coordinateSpace(name: "sz-card-body")
        .clipped()
    }

    private var spinner: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: bodySize.width, height: bodySize.height)
    }

    /// The keep-last-good badge: the mounted build is stale because the latest edit didn't compile.
    private func warningChip(_ message: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(message)
                .font(.system(size: 9))
                .lineLimit(1)
        }
        .foregroundStyle(.black.opacity(0.85))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.yellow.opacity(0.9), in: Capsule())
        .padding(6)
        .frame(width: bodySize.width, alignment: .topTrailing)
        .allowsHitTesting(false)
        .help(message)
    }

    private func errorChip(_ message: String) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.yellow.opacity(0.9))
                Text("card failed to load")
                    .font(SZNodeCardStyle.labelFont)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text(message)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
            Button("Hide Custom Card") {
                provider?.setCardShown(node: nodeID, false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(width: bodySize.width, height: bodySize.height)
    }
}
