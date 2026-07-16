// SPDX-License-Identifier: AGPL-3.0-only
// A generated node card — a vertical stack: header (SF Symbol + title, flow sockets on the
// sides) → stacked input rows (data socket left + render-only control) → stacked output rows (data
// socket right; a texture output shows a monitor icon marking the render endpoint). A status pill
// floats above. Sockets are placed by SZNodeLayout so the edge layer lands on them. Always-expanded —
// TODO: a collapsed card state.
import SwiftUI
import SZCore

struct SZNodeView: View, Equatable {
    let node: SZNode
    let status: SZNodeStatus
    var isSelected: Bool = false
    var locked: Bool = false
    var showPill: Bool = true
    var errorDetail: String? = nil   // full build diagnostic → clickable error pill
    let renderEndpoint: SZPortRef?
    /// Mirrors `SZNodeLayout.previewsEnabled` (the host writes both together). The body derives its
    /// preview region from SZNodeLayout — this prop exists so `==` sees a gate flip and reflows the card.
    var previewsEnabled: Bool = true
    /// Semantic-zoom tier (canvas zoom < `SZNodeLayout.lodZoomThreshold`): render as a preview-only
    /// tile. Render-only — the card frame and socket geometry are identical in both tiers.
    var zoomedOut: Bool = false
    /// Input port names currently fed by a data edge — their inline control is hidden (the wire's value
    /// wins at runtime, so an editable default would lie). The contract keeps the default untouched, so
    /// disconnecting brings the control back with its pre-connection value.
    var connectedInputs: Set<String> = []
    /// This node's live preview box (stable per node, written by the host's preview frame sink). Excluded
    /// from `==` like the closures — only SZNodePreviewThumb reads its contents.
    var previewFrame: SZNodePreviewFrame? = nil
    var onOpenSource: (() -> Void)? = nil   // file button → open this node's Node.swift
    var onOpenChat: (() -> Void)? = nil     // speech button → this node's Coding Agent chat
    var onOpenMenu: (() -> Void)? = nil     // "⋯" → the node's context menu (split/merge/implement/…)
    var onSetInput: ((String, SZPortValue, Bool) -> Void)? = nil   // (port, value, persist) → ui_set_input_default
    var onToggleDisplay: ((String) -> Void)? = nil   // texture output monitor icon → ui_toggle_display (port)
    var onTogglePreview: ((String) -> Void)? = nil   // texture output photo icon → toggle the card's live preview (port)
    var optionsFor: ((String) -> [SZEnumOption])? = nil   // effective enum options (dynamic ?? static) for a port
    var onFix: (() -> Void)? = nil          // Outdated/Error pill → compose a rebuild request to its Coding Agent

    @State private var cardHover = false   // card hover lift; view-local (per-card), excluded from ==

    /// Value-props-only equality (closures excluded — they're freshly allocated every panel render but
    /// capture only stable refs, so a kept older closure still lands on the live host/store). Wrapped in
    /// `.equatable()` at the panel's construction site, this is what lets a drag tick skip every card
    /// whose content didn't change. `position` is deliberately ignored: the panel places the card via
    /// `.position()` OUTSIDE this view, so even the dragged card's body never depends on it.
    nonisolated static func == (lhs: SZNodeView, rhs: SZNodeView) -> Bool {
        var rnode = rhs.node
        rnode.position = lhs.node.position
        return lhs.node == rnode
            && lhs.status == rhs.status
            && lhs.isSelected == rhs.isSelected
            && lhs.locked == rhs.locked
            && lhs.showPill == rhs.showPill
            && lhs.errorDetail == rhs.errorDetail
            && lhs.renderEndpoint == rhs.renderEndpoint
            && lhs.previewsEnabled == rhs.previewsEnabled
            && lhs.zoomedOut == rhs.zoomedOut
            && lhs.connectedInputs == rhs.connectedInputs
    }

    private var inputs: [SZPort] { node.contract?.inputs ?? [] }
    private var outputs: [SZPort] { node.contract?.outputs ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            if zoomedOut {
                lodTile
            } else {
                header
                // The preview body sits between header and rows, exactly `previewHeight` tall —
                // SZNodeLayout.previewInset is the ONE term the frame below and rowCenterY share.
                if SZNodeLayout.previewInset(of: node) > 0 {
                    previewRegion
                }
                // The body rows must match SZNodeLayout's geometry exactly (bodyTopPadding above the first
                // row, rowSpacing between rows) so the overlaid sockets line up with their labels.
                // The card-wide numeric-cell width, computed ONCE per body pass (each row reuses it).
                let fieldWidth = SZNodeLayout.numericFieldWidth(of: node)
                VStack(spacing: SZNodeLayout.rowSpacing) {
                    ForEach(inputs, id: \.name) { inputRow($0, fieldWidth: fieldWidth) }
                    ForEach(outputs, id: \.name) { outputRow($0) }
                }
                .padding(.top, SZNodeLayout.bodyTopPadding)
                .padding(.bottom, SZNodeLayout.bodyBottomPadding)
            }
        }
        .frame(width: SZNodeLayout.width(of: node), height: SZNodeLayout.height(of: node), alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: SZNodeLayout.cornerRadius)
                // Hover changes fill/stroke only — NOT the shadow: animating shadow(radius:) forces an
                // offscreen re-rasterization every frame, and .onHover fires per-card as the cursor
                // sweeps during a drag. Keep the shadow constant so nothing rasterizes on the hot path.
                .fill(cardHover ? SZNodeCardStyle.cardHoverFill : SZNodeCardStyle.cardFill)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4))
        .overlay(
            RoundedRectangle(cornerRadius: SZNodeLayout.cornerRadius)
                .stroke(isSelected ? SZNodeCardStyle.selectionStroke
                            : (cardHover ? Color.white.opacity(0.22) : SZNodeCardStyle.cardStroke),
                        lineWidth: isSelected ? 1.6 : (cardHover ? 1 : 0.75)))
        .contentShape(Rectangle())
        // hover on the CARD FRAME only (attached before the badges/buttons overlays) — hovering the
        // buttons below or the status pill above must not light the card; those have their own.
        .trackingHover($cardHover, duration: 0.12)
        .overlay(alignment: .top) {
            SZNodeBadges(status: status, showPill: showPill, locked: locked, errorDetail: errorDetail,
                         // This node compiled; what's wrong is that its source and its contract disagree.
                         errorTitle: node.rebuildReason == .sourceMismatch ? "Contract mismatch" : "Build error",
                         onFix: onFix)
                .offset(y: -(SZNodeLayout.statusPillHeight + 4))
        }
        .graphOpGlow(status, cornerRadius: SZNodeLayout.cornerRadius)
        // No action pills from orbit — the zoomed-out tile is preview + pill only.
        .overlay(alignment: .bottomLeading) { if !zoomedOut { bottomButtons } }
    }

    /// The in-card live-thumbnail region (between header and rows). Height is the layout's
    /// `previewHeight` — the horizontal padding is purely visual, inside the region.
    private var previewRegion: some View {
        SZNodePreviewThumb(frame: previewFrame)
            .padding(.horizontal, 8)
            .frame(height: SZNodeLayout.previewHeight)
    }

    /// The zoomed-out card: the preview fills the whole frame; a node with no effective preview shows
    /// an icon + title tile instead (a blank rect gives no orientation). Chrome (rows, toggles,
    /// buttons) is gone — the status pill floating above survives.
    @ViewBuilder
    private var lodTile: some View {
        if SZNodeLayout.previewInset(of: node) > 0 {
            SZNodePreviewThumb(frame: previewFrame, cornerRadius: SZNodeLayout.cornerRadius)
        } else {
            VStack(spacing: 8) {
                Image(systemName: node.sfSymbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text(node.title)
                    .font(SZNodeCardStyle.titleFont)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The card's action buttons, tucked just BELOW the card (offset outside the frame, so they
    /// don't fight the card's drag/select gestures and don't crowd the header): open the source,
    /// chat with the node's Coding Agent, and the "⋯" for structural actions (split/merge/…).
    private var bottomButtons: some View {
        HStack(spacing: 4) {
            if let onOpenSource { SZCardPillButton(symbol: "doc.text", help: "Open this node's source (Node.swift)", action: onOpenSource) }
            if let onOpenChat { SZCardPillButton(symbol: "bubble.left.fill", help: "Chat with this node's Coding Agent", action: onOpenChat) }
            if let onOpenMenu { SZCardPillButton(symbol: "ellipsis", help: "Node actions", action: onOpenMenu) }
        }
        .offset(x: 2, y: 27)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: node.sfSymbol)
                .font(SZNodeCardStyle.titleFont)
                .foregroundStyle(.white.opacity(0.7))
            Text(node.title)
                .font(SZNodeCardStyle.titleFont)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)                       // center the symbol + title (flow sockets sit outside)
        .padding(.horizontal, 12)
        .frame(height: SZNodeLayout.headerHeight)
    }

    private func inputRow(_ port: SZPort, fieldWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text(port.name)
                .font(SZNodeCardStyle.labelFont)
                .foregroundStyle(SZNodeCardStyle.labelColor)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !connectedInputs.contains(port.name) {
                SZPortControl(port: port, locked: locked,
                              fieldWidth: fieldWidth,
                              options: effectiveOptions(port),
                              // Same dynamic-??-static resolution as the snapshot above, re-run at
                              // menu-open time — the fallback rule lives ONLY in effectiveOptions.
                              freshOptions: optionsFor.map { _ in { effectiveOptions(port) } },
                              onSet: onSetInput.map { set in { value, persist in set(port.name, value, persist) } })
            }
        }
        .padding(.horizontal, 12)
        .frame(height: SZNodeLayout.rowHeight)
    }

    private func outputRow(_ port: SZPort) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if port.type == .texture {
                let previewing = isPreviewPort(port)
                toggleGlyph("photo", active: previewing, port: port.name,
                            help: previewing ? "Hide this output's live preview"
                                             : "Preview this output on the card",
                            action: onTogglePreview)
                toggleGlyph("display", active: isRenderEndpoint(port), port: port.name,
                            help: isRenderEndpoint(port) ? "Stop displaying this output"
                                                         : "Display this output in the viewport",
                            action: onToggleDisplay)
            }
            Text(port.name)
                .font(SZNodeCardStyle.labelFont)
                .foregroundStyle(SZNodeCardStyle.labelColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: SZNodeLayout.rowHeight)
    }

    /// A texture-row toggle glyph — photo (preview) and display (endpoint) share one look: cyan when
    /// active, dimmed otherwise; a Button only when a handler is wired and the card isn't locked.
    @ViewBuilder
    private func toggleGlyph(_ systemName: String, active: Bool, port: String, help: String,
                             action: ((String) -> Void)?) -> some View {
        let icon = Image(systemName: systemName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(active ? Color.cyan : .white.opacity(0.3))
        if let action, !locked {
            Button { action(port) } label: { icon }
                .buttonStyle(.plain)
                .help(help)
        } else {
            icon
        }
    }

    private func isRenderEndpoint(_ port: SZPort) -> Bool {
        renderEndpoint?.node == node.id && renderEndpoint?.port == port.name
    }

    /// Whether `port` is the one this card's preview effectively shows — graph state only, NOT gated
    /// on the global previews switch: the icon keeps reflecting (and toggling) the persisted choice
    /// while the gate is off, so a click never silently mutates state behind a dead-looking control.
    private func isPreviewPort(_ port: SZPort) -> Bool {
        node.effectiveBodyMode == .preview && node.effectivePreviewPort == port.name
    }

    /// Effective enum options: the host-provided list (dynamic ?? static) when injected, else the port's
    /// own static `options` (keeps static enums working in previews / when no provider is wired).
    private func effectiveOptions(_ port: SZPort) -> [SZEnumOption] {
        let provided = optionsFor?(port.name) ?? []
        return provided.isEmpty ? (port.options ?? []) : provided
    }
}

/// A card action pill (file / speech / ⋯) tucked below a node card. Its own hover state so it
/// brightens under the cursor — view-local, no content-layer re-render.
private struct SZCardPillButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.75))
                .frame(width: 26, height: 22)
                .background(Capsule().fill(hover ? SZNodeCardStyle.cardHoverFill : SZNodeCardStyle.cardFill))
                .overlay(Capsule().stroke(.white.opacity(hover ? 0.3 : 0.14), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .trackingHover($hover)
        .help(help)
    }
}
