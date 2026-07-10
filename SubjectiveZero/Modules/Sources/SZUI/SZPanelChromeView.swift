// SPDX-License-Identifier: AGPL-3.0-only
// Panel chrome — the thin header every top-level panel wears in the rearrangeable layout: the
// panel's name (the drag handle for moving the panel — gesture added by the container) and a ✕ that
// closes it (collapsing its split; disabled on the last panel). With View ▸ Auto-Hide Panel
// Headers on (a per-machine app-state.json pref), the header stays hidden until the cursor nears
// the tile's top edge, then slides down over the content (and back out when the cursor leaves),
// so tiles read as pure content at rest; off, every header is permanent and chat's tab strip lays
// out below it as before.
import SwiftUI
import SZCore

struct SZPanelChromeView<Content: View>: View {
    let kind: SZPanelKind
    let canClose: Bool
    /// Whether the maximize/restore button is offered — true once more than one panel is present,
    /// so maximizing this one actually hides something (stays true while maximized, unlike canClose).
    let canMaximize: Bool
    /// This panel currently fills the window (others hidden) — flips the button to the restore glyph.
    let isMaximized: Bool
    /// View ▸ Auto-Hide Panel Headers (SZHost.autoHidePanelHeaders, via the container).
    let autoHideEnabled: Bool
    /// View ▸ Rounded Viewport Corners (SZHost.viewportRoundedCorners, via the container). Only the
    /// viewport tile honors it — off squares its corners; every other tile stays rounded.
    let viewportRoundedCorners: Bool
    /// Extra leading room in the header — the container sets it when the window's traffic lights
    /// float over this tile, so the name starts after them.
    let headerLeadingInset: CGFloat
    let onClose: () -> Void
    let onToggleMaximize: () -> Void
    /// Header drag, reported in the container's grid space — the container resolves the hovered
    /// panel + drop zone and commits the move. A sub-threshold release never fires either callback,
    /// so the ✕ button keeps winning plain clicks (the chat-tab-drag interaction pattern).
    let onHeaderDragChanged: (CGPoint) -> Void
    let onHeaderDragEnded: (CGPoint) -> Void
    @ViewBuilder let content: () -> Content

    static var headerHeight: CGFloat { 26 }
    /// Grace before sliding away once the cursor leaves the band — absorbs brief overshoots
    /// (reaching for the ✕ and drifting past) without flicker.
    private static var hideGrace: Duration { .milliseconds(350) }

    /// The hover band (from the tile's top) that summons a hidden header. Generous by default —
    /// taller than the header so the trigger is forgiving. Chat's is a thin sliver instead: its
    /// tab strip sits at the very top when auto-hide is on, and a tall band would pop the header
    /// over the tabs on every tab hover — so there, summoning means pushing to the top edge.
    private var triggerBand: CGFloat { kind == .chat ? 8 : 36 }
    /// Hysteresis: once revealed, the header's own footprint keeps it alive — the cursor sitting
    /// ON the revealed header must never count as "out of the band", whatever the trigger size.
    private var revealThreshold: CGFloat { headerVisible ? max(triggerBand, Self.headerHeight) : triggerBand }

    @State private var headerVisible = false
    /// Live truth of "cursor is in the reveal band" — the delayed hide re-checks it at fire time
    /// (the SZHoverTip pattern: re-check state after the sleep instead of juggling cancellation).
    @State private var inRevealBand = false
    @State private var hidePending = false
    /// A header rearrange-drag pins the header visible even when the drag leaves the band —
    /// the drag handle must not vanish mid-drag.
    @State private var headerDragActive = false

    private var headerShown: Bool { !autoHideEnabled || headerVisible || headerDragActive }

    /// The tile's clip/border radius. Only the viewport squares off (radius 0) when the pref is off;
    /// every other tile keeps the standard rounding.
    private var cornerRadius: CGFloat {
        kind == .viewport && !viewportRoundedCorners ? 0 : SZPanelLayoutGeometry.tileCornerRadius
    }

    var body: some View {
        // The header is a translucent HUD-material overlay (the node-editor HUD's .ultraThinMaterial):
        // the viewport render / node canvas shows through behind it. Content deliberately extends
        // UNDER the header — except chat with permanent headers, whose top-anchored tab strip must
        // stay visible, so it lays out below instead. With auto-hide on, chat's tabs take the top
        // and the summoned header slides in over them (its thin trigger band keeps that rare).
        ZStack(alignment: .top) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, kind == .chat && !autoHideEnabled ? Self.headerHeight : 0)
            header
                // Slides in from above the tile's top edge (the tile's clip shape swallows it while
                // hidden) with a fade riding along.
                .opacity(headerShown ? 1 : 0)
                .offset(y: headerShown ? 0 : -Self.headerHeight)
                // A hidden header must not be an invisible drag handle — the top band belongs to
                // the panel's content until the header is actually shown.
                .allowsHitTesting(headerShown)
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard autoHideEnabled else { return }
            switch phase {
            case .active(let p):
                inRevealBand = p.y <= revealThreshold
                if inRevealBand { revealHeader() } else { scheduleHide() }
            case .ended:
                inRevealBand = false
                scheduleHide()
            }
        }
        .background(Color(white: 0.09))
        // A rounded tile floating on the window background (never painting outside itself, whatever
        // its content does), with a hairline edge so adjacent tiles read as separate sections.
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(kind.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if canMaximize {
                // Diagonal expand/contract arrows — bare strokes like the ✕. The arrows glyph fills a
                // wider box than xmark, so it's rendered a touch smaller/lighter to read at a matching
                // optical size (both centered in the shared square frame, same baseline & hit target).
                SZPanelHeaderButton(
                    systemName: isMaximized ? "arrow.down.right.and.arrow.up.left"
                                            : "arrow.up.left.and.arrow.down.right",
                    help: isMaximized ? "Restore \(kind.displayName)" : "Maximize \(kind.displayName)",
                    size: 7, weight: .semibold, action: onToggleMaximize)
            }
            if canClose {
                SZPanelHeaderButton(systemName: "xmark", help: "Close \(kind.displayName)",
                                    action: onClose)
            }
        }
        .padding(.leading, 10 + headerLeadingInset)
        .padding(.trailing, 10)
        .frame(height: Self.headerHeight)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)   // the HUD's glass — content glows through from beneath
        .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.03)) }
        .contentShape(Rectangle())   // the whole strip is grabbable, not just the label glyphs
        .gesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .named(szPanelGridSpaceName))
                .onChanged {
                    if !headerDragActive { headerDragActive = true }
                    onHeaderDragChanged($0.location)
                }
                .onEnded {
                    onHeaderDragEnded($0.location)
                    // Hover events don't arrive while the mouse button is down, so band state is
                    // stale here — assume "away" and let the very next mouse move correct it
                    // (worst case the header re-reveals on the first twitch after a drop).
                    inRevealBand = false
                    withAnimation(.easeInOut(duration: 0.18)) { headerDragActive = false }
                    scheduleHide()
                }
        )
    }

    private func revealHeader() {
        guard !headerVisible else { return }
        withAnimation(.easeOut(duration: 0.12)) { headerVisible = true }
    }

    private func scheduleHide() {
        guard headerVisible, !hidePending else { return }
        hidePending = true
        Task { @MainActor in
            try? await Task.sleep(for: Self.hideGrace)
            hidePending = false
            if !inRevealBand && !headerDragActive {
                withAnimation(.easeInOut(duration: 0.18)) { headerVisible = false }
            }
        }
    }
}

/// A header icon button (maximize/restore, close): the glyph centered in a shared square frame so
/// every header button shares one baseline and hit target, brightening from secondary to primary
/// with a faint chip under the cursor — the app's "brighten under the cursor" hover idiom.
private struct SZPanelHeaderButton: View {
    let systemName: String
    let help: String
    var size: CGFloat = 8
    var weight: Font.Weight = .bold
    let action: () -> Void

    /// Equal square frame for the header's icon buttons, whatever each SF Symbol's intrinsic box.
    private static var side: CGFloat { 15 }
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: Self.side, height: Self.side)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.12 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .trackingHover($hovering)
        .help(help)
    }
}
