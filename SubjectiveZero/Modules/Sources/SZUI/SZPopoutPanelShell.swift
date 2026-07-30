// SPDX-License-Identifier: AGPL-3.0-only
// The popped-out panel window's content: the panel full-bleed under ONE slim glass strip — the
// titlebar row itself, shared with the native traffic lights (name after the lights, dock-back
// button trailing). No second header below it: a floating window's chrome budget is one strip,
// matching the docked tiles' 26pt headers in weight. Window moving and drag-to-dock are native
// window drags (movable-by-background covers the strip's passive areas too), reconstructed by the
// window manager (SZApp), not a gesture here.
//
// Deliberately its own view, not more modes on SZPanelChromeView: no auto-hide, no maximize, no
// grid-space drag, no tile clipping — a floating window is a window, its corners and resize
// behavior come from AppKit.
import SwiftUI

/// Header metrics the window manager needs before the view exists (content min-size math).
/// 28pt = the titled window's titlebar height; the glass strip owns exactly that row.
public enum SZPopoutPanelShellMetrics {
    public static let headerHeight: CGFloat = 28
}

/// The window's live title, shared between AppKit (which retitles on panel-set changes — the
/// numbering is positional) and the SwiftUI strip. A tiny box rather than rebuilding the root
/// view: replacing the hosting view's root would tear down the Metal viewport inside.
public final class SZPopoutWindowTitle: ObservableObject {
    @Published public var text: String
    public init(_ text: String) { self.text = text }
}

public struct SZPopoutPanelShell<Content: View>: View {
    @ObservedObject private var title: SZPopoutWindowTitle
    /// Leading room for the window's traffic lights, which share the strip.
    private let headerLeadingInset: CGFloat
    private let onDock: () -> Void
    private let content: () -> Content

    public init(title: SZPopoutWindowTitle, headerLeadingInset: CGFloat,
                onDock: @escaping () -> Void,
                @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.headerLeadingInset = headerLeadingInset
        self.onDock = onDock
        self.content = content
    }

    public var body: some View {
        ZStack(alignment: .top) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            header
        }
        .ignoresSafeArea()   // one coordinate space: the strip IS the titlebar row, content under it
        .background(Color(white: 0.09).ignoresSafeArea())   // the tile body color — same surface
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(title.text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            SZPanelHeaderButton(systemName: "arrow.down.backward.square",
                                help: "Move \(title.text) Back to the Main Window",
                                size: 7.5, weight: .semibold, action: onDock)
        }
        .padding(.leading, 10 + headerLeadingInset)
        .padding(.trailing, 10)
        .frame(height: SZPopoutPanelShellMetrics.headerHeight)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)   // the panel-header glass — content glows through
        .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.03)) }
    }
}
