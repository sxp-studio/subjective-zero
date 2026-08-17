// SPDX-License-Identifier: AGPL-3.0-only
// The popped-out panel window's content: the panel full-bleed under ONE slim glass strip — the
// titlebar row itself, shared with the native traffic lights (name after the lights, dock-back
// button trailing). No second header below it: a floating window's chrome budget is one strip,
// matching the docked tiles' 26pt headers in weight. Window moving and drag-to-dock are native
// window drags (movable-by-background covers the strip's passive areas too), reconstructed by the
// window manager (SZApp), not a gesture here.
//
// Deliberately its own view, not more modes on SZPanelChromeView: no maximize, no grid-space
// drag, no tile clipping — a floating window is a window, its corners and resize behavior come
// from AppKit. Auto-hide (View ▸ Auto-Hide Panel Headers) DOES apply, sharing the tile's reveal
// model: the strip slides away and the top band summons it; the traffic lights stay, as they do
// over the main window's top-left tile.
import SwiftUI

/// Header metrics the window manager needs before the view exists (content min-size math).
/// 28pt = the titled window's titlebar height; the glass strip owns exactly that row.
public enum SZPopoutPanelShellMetrics {
    public static let headerHeight: CGFloat = 28
}

/// The window's live strip state, pushed by AppKit: the title (retitled on panel-set changes —
/// the numbering is positional) and the auto-hide pref. A tiny box rather than rebuilding the
/// root view: replacing the hosting view's root would tear down the Metal viewport inside.
public final class SZPopoutWindowShellState: ObservableObject {
    @Published public var title: String
    /// View ▸ Auto-Hide Panel Headers, mirrored live from the host.
    @Published public var autoHideHeader: Bool
    public init(title: String, autoHideHeader: Bool) {
        self.title = title
        self.autoHideHeader = autoHideHeader
    }
}

public struct SZPopoutPanelShell<Content: View>: View {
    @ObservedObject private var state: SZPopoutWindowShellState
    /// Leading room for the window's traffic lights, which share the strip.
    private let headerLeadingInset: CGFloat
    private let onDock: () -> Void
    private let content: () -> Content
    @StateObject private var reveal = SZHeaderRevealModel()

    public init(state: SZPopoutWindowShellState, headerLeadingInset: CGFloat,
                onDock: @escaping () -> Void,
                @ViewBuilder content: @escaping () -> Content) {
        self.state = state
        self.headerLeadingInset = headerLeadingInset
        self.onDock = onDock
        self.content = content
    }

    private var headerShown: Bool { reveal.shown(autoHide: state.autoHideHeader) }

    public var body: some View {
        ZStack(alignment: .top) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            header
                // Slides up out of the titlebar row with a fade; hidden, the top band belongs to
                // the content (and to the native traffic lights) — never an invisible strip.
                .opacity(headerShown ? 1 : 0)
                .offset(y: headerShown ? 0 : -SZPopoutPanelShellMetrics.headerHeight)
                .allowsHitTesting(headerShown)
        }
        .ignoresSafeArea()   // one coordinate space: the strip IS the titlebar row, content under it
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard state.autoHideHeader else { return }
            reveal.hover(phase, triggerBand: SZHeaderRevealModel.defaultTriggerBand,
                         headerHeight: SZPopoutPanelShellMetrics.headerHeight)
        }
        .background(Color(white: 0.09).ignoresSafeArea())   // the tile body color — same surface
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(state.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            SZPanelHeaderButton(systemName: "arrow.down.backward.square",
                                help: "Move \(state.title) Back to the Main Window",
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
