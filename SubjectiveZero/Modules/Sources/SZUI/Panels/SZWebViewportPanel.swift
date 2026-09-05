// SPDX-License-Identifier: AGPL-3.0-only
// The viewport tile of a web project: a dumb parent for the page view the host owns (a WKWebView, but
// SZUI never learns that; it re-parents an NSView). Panel moves change the rect, never the view, so the
// page never reloads. While the page is not up, the tile says why in plain words. SwiftUI overlays
// draw above the page view as they do above the Metal one (the recording edge and framing editor
// ride on the tile from the workspace); the header title carries the "(Web)" mark.
import AppKit
import SwiftUI

public struct SZWebViewportPanel: View {
    private let pageView: NSView?
    private let status: String?
    private let onRetry: (() -> Void)?

    /// `pageView` is the live page (nil while it is coming up or failed); `status` is the line to show
    /// instead, and `onRetry` an action for a failed download.
    public init(pageView: NSView?, status: String? = nil, onRetry: (() -> Void)? = nil) {
        self.pageView = pageView
        self.status = status
        self.onRetry = onRetry
    }

    public var body: some View {
        ZStack {
            Color.black
            if let pageView {
                SZWebPageHost(view: pageView)
            } else {
                VStack(spacing: 10) {
                    Text(status ?? "Loading the web viewport")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    if let onRetry {
                        Button("Try Again", action: onRetry)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(24)
            }
        }
    }
}

/// Re-parents the host's page view; attach is idempotent so SwiftUI update churn never touches a view
/// that is already parented.
struct SZWebPageHost: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> SZWebPageContainer { SZWebPageContainer() }

    func updateNSView(_ container: SZWebPageContainer, context: Context) {
        container.attach(view)
    }
}

final class SZWebPageContainer: NSView {
    private weak var attached: NSView?

    func attach(_ view: NSView) {
        guard attached !== view else { return }
        attached?.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        attached = view
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // tiles sit at fractional origins; align outward so the page covers the whole tile
        attached?.frame = backingAlignedRect(bounds, options: [.alignAllEdgesOutward])
    }
}
