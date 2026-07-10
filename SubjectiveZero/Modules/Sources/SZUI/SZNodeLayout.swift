// SPDX-License-Identifier: AGPL-3.0-only
// Pure geometry for the node canvas — the vertical-stack node anatomy plus the
// screen↔world transform. It is the SINGLE source of truth shared by the node views (which place
// their sockets) and the connection layer (which draws edges between them), so edges always meet
// sockets at any zoom. No SwiftUI here, so it is unit-tested headlessly (SZUITests).
//
// node.position is the card CENTER; all socket offsets are relative to that center. The card is a
// vertical stack: header (title + flow sockets on the sides) → stacked input rows (data socket left) →
// stacked output rows (data socket right). Width auto-sizes to the content (see `width(of:)`) —
// everything downstream (sockets, edges, marquee, snap, MCP placement) reads `size(of:)`/
// `socketOffset(of:)`, so interaction code is width-agnostic by construction.
import CoreGraphics
import Foundation
import Synchronization
import SZCore

/// Which side of a node a socket sits on. A data/flow output feeds an input.
public enum SZSocketSide: Sendable { case input, output }

public enum SZNodeLayout {
    /// World-space pitch of the canvas dot grid — shared by the grid drawing (SZDotGridView) and
    /// every snapping site (drag, create, MCP ui_* placement) so "on grid" means one thing.
    public static let gridPitch: CGFloat = 24
    // Card metrics are designed AROUND the grid: width(of:) and every height(of:) are exact multiples
    // of gridPitch (width ≥ 9 cells; heights = 48 + 24·rows via 40 + 4 + 24·rows + 4), so a snapped
    // card — anchor is the TOP-LEFT corner, see snappedCenter — lands all four edges on grid lines.
    /// The BASE card width (9 cells): the minimum for generated cards and the fixed width of prompt
    /// cards. Sizing a generated card must go through `width(of:)`/`size(of:)`.
    public static let width: CGFloat = 216
    public static let cornerRadius: CGFloat = 12
    public static let headerHeight: CGFloat = 40
    public static let rowHeight: CGFloat = 24
    public static let rowSpacing: CGFloat = 0
    public static let bodyTopPadding: CGFloat = 4
    public static let bodyBottomPadding: CGFloat = 4
    public static let socketSize: CGFloat = 12
    public static let promptHeight: CGFloat = 48
    public static let statusPillHeight: CGFloat = 18

    public static func inputs(of node: SZNode) -> [SZPort] { node.contract?.inputs ?? [] }
    public static func outputs(of node: SZNode) -> [SZPort] { node.contract?.outputs ?? [] }

    /// Total card height (excludes the status pill, which floats above the card). Always a multiple
    /// of gridPitch — the metrics above are chosen so this needs no rounding slack.
    public static func height(of node: SZNode) -> CGFloat {
        switch node.kind {
        case .prompt:
            return promptHeight
        case .generated:
            let rows = inputs(of: node).count + outputs(of: node).count
            guard rows > 0 else { return headerHeight + bodyTopPadding + bodyBottomPadding }
            return headerHeight + bodyTopPadding
                + CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing
                + bodyBottomPadding
        }
    }

    public static func size(of node: SZNode) -> CGSize {
        CGSize(width: width(of: node), height: height(of: node))
    }

    // MARK: - Content-driven card width

    // Text metrics mirroring the SZUI card styling (SZNodeCardStyle fonts + SZPortControl widget
    // widths). SZNodeLayout stays SwiftUI-free, so text is estimated from advances: labels/values are
    // MONOSPACED (width is exact character arithmetic, padded a hair); the proportional title uses a
    // conservative average. Estimates only ever round UP — a mismatch shows as slack, not truncation.
    static let labelCharWidth: CGFloat = 6.7     // SF Mono 10 (row labels) — measured live; 6.1 truncated
    static let valueCharWidth: CGFloat = 5.5     // SF Mono 9 (chip/value text)
    static let titleCharWidth: CGFloat = 7.0     // SF Pro semibold 12, conservative per-char average
    static let rowHorizontalPadding: CGFloat = 24
    static let labelControlSpacing: CGFloat = 8

    // Widget frames RENDERED by SZPortControl and BUDGETED by controlWidth — named once here (the
    // layout stays SwiftUI-free) so the paint and the estimate consume the same numbers and cannot
    // drift apart on a tweak.
    static let sliderTrackWidth: CGFloat = 80
    static let sliderValueSpacing: CGFloat = 6
    static let stringFieldWidth: CGFloat = 96
    static let fieldHorizontalPadding: CGFloat = 6     // string well
    static let chipHorizontalPadding: CGFloat = 6      // capsule chips
    static let filePickerGlyphWidth: CGFloat = 11      // the folder SF Symbol in a filePicker chip
    static let cellHorizontalPadding: CGFloat = 3      // numeric cells
    static let cellSpacing: CGFloat = 3

    /// Content-driven card width: wide enough that no row label or control truncates, never below the
    /// classic 216, grid-aligned (multiple of `gridPitch`, keeping snappedCenter's all-edges-on-grid
    /// invariant), and capped at 18 cells so a degenerate contract can't produce a banner. Prompt
    /// cards keep the fixed base width (no port rows). Deliberately independent of connection state —
    /// a row's control is assumed present even while a wire hides it, so sockets/edges never shift
    /// when connecting.
    public static func width(of node: SZNode) -> CGFloat {
        guard node.kind == .generated else { return width }
        // Loops, not maps — this runs per socket per canvas evaluation (socketOffset), so it must not
        // allocate intermediate arrays on the drag hot path.
        let fieldWidth = numericFieldWidth(of: node)
        var content = headerWidth(of: node)
        for port in inputs(of: node) { content = max(content, inputRowWidth(port, fieldWidth: fieldWidth)) }
        for port in outputs(of: node) { content = max(content, outputRowWidth(port)) }
        let cells = (content / gridPitch).rounded(.up)
        return min(max(width, cells * gridPitch), gridPitch * 18)
    }

    /// Header: leading SF Symbol + title, centered with 12pt side padding.
    static func headerWidth(of node: SZNode) -> CGFloat {
        rowHorizontalPadding + 14 + 6 + CGFloat(node.title.count) * titleCharWidth
    }

    static func inputRowWidth(_ port: SZPort, fieldWidth: CGFloat) -> CGFloat {
        // The row is HStack(spacing: 8) { label; Spacer; control } — SwiftUI puts the stack spacing
        // on BOTH sides of the (even collapsed) Spacer, so the minimum gap is TWO spacings.
        rowHorizontalPadding + CGFloat(port.name.count) * labelCharWidth
            + 2 * labelControlSpacing + controlWidth(port, fieldWidth: fieldWidth)
    }

    /// Output rows: [monitor icon +] port name, trailing-aligned. Bare text sits on the same 12pt
    /// line as the boxes and the slider value column; capsule ends optically read a hair inside their
    /// geometric edge (rounding), which is expected — don't chase it with insets.
    static func outputRowWidth(_ port: SZPort) -> CGFloat {
        rowHorizontalPadding + (port.type == .texture ? 14 + 6 : 0)
            + CGFloat(port.name.count) * labelCharWidth
    }

    /// The natural width of the inline control SZPortControl renders for `port` (0 = no control).
    /// Field/slider widths are that view's fixed frames + paddings; chips are text-metric estimates.
    static func controlWidth(_ port: SZPort, fieldWidth: CGFloat) -> CGFloat {
        switch port.type {
        case .bool:
            return 40                                            // mini switch
        case .float, .float2, .float3, .float4:
            if let range = port.sliderRange {
                return sliderTrackWidth + sliderValueSpacing + sliderValueColumnWidth(range)
            }
            return numericFieldsRowWidth(count: componentCount(port.type), fieldWidth: fieldWidth)
        case .string where port.ui?.kind == .filePicker:
            // A filePicker is a CONTENT-sized chip (folder glyph + filename at the label font), not the
            // fixed editable string well — so it isn't padded out to `stringFieldWidth`. Matches
            // SZPortControl.filePickerLabel (font + folder icon + 3pt HStack spacing).
            let shown = (port.def?.string).map { ($0 as NSString).lastPathComponent } ?? ""
            let text = shown.isEmpty ? "Choose…" : shown
            return filePickerGlyphWidth + 3 + CGFloat(text.count) * labelCharWidth + 2 * chipHorizontalPadding
        case .string:
            // Editable: fixed field well + padding. Read-only renders a content-sized chip instead,
            // which can be wider — budget for whichever the default string needs.
            return max(stringFieldWidth + 2 * fieldHorizontalPadding,
                       CGFloat((port.def?.string ?? "").count) * valueCharWidth + 2 * chipHorizontalPadding)
        case .enumeration:
            // Chip sized by its longest STATIC option label (dynamic runtime lists — e.g. cameras —
            // aren't in the contract; they may still truncate, which the chip's lineLimit handles).
            let longest = (port.options ?? []).map(\.label.count).max()
                ?? port.def?.string?.count ?? 1
            return CGFloat(longest) * valueCharWidth + 2 * chipHorizontalPadding + 10   // + chevron
        case .colorRGB, .colorRGBA:
            return 34                                            // color-picker swatch / read-only swatch
        case .float3x3, .float4x4:
            // Read-only cells for the first 4 components.
            return numericFieldsRowWidth(count: 4, fieldWidth: fieldWidth)
        case .texture, .event, .floatArray:
            return 0
        }
    }

    /// Component count of a numeric field row (float → 1 … float4 → 4).
    static func componentCount(_ type: SZPortType) -> Int {
        switch type {
        case .float2: 2
        case .float3: 3
        case .float4: 4
        default: 1
        }
    }

    // MARK: Numeric-field sizing — shared VERBATIM with SZPortControl, so the rendered wells and the
    // card-width estimate cannot drift.

    /// The ONE numeric-cell width used by every field/cell on a card, computed across ALL of its
    /// numeric ports — so a float4 row's cells sit on the same column grid as the float2/float3 rows
    /// above it (per-row widths made mixed-arity cards read off-grid). Committing a longer number
    /// re-derives it, resizing every row (and the card) together.
    public static func numericFieldWidth(of node: SZNode) -> CGFloat {
        // Loops over the real defaults only — numericComponents' zero-padding contributes "0"
        // (length 1), which never exceeds the running max, so skipping it (and its array) is exact.
        var longest = 1
        for port in inputs(of: node) {
            switch port.type {
            case .float where port.sliderRange != nil: continue
            case .float, .float2, .float3, .float4, .float3x3, .float4x4:
                for v in (port.def?.floats ?? []).prefix(4) {
                    longest = max(longest, formattedNumericLength(Double(v)))
                }
            default: continue
            }
        }
        return max(28, CGFloat(longest) * valueCharWidth + 10)
    }

    /// One width for a set of components: a compact base that grows to fit the longest formatted one.
    public static func numericFieldWidth(values: [Double]) -> CGFloat {
        let longest = values.map { formattedNumericLength($0) }.max() ?? 1
        return max(28, CGFloat(longest) * valueCharWidth + 10)
    }

    /// The components a port renders as numeric cells (empty for non-numeric ports and sliders —
    /// the slider's value column is sized separately). Matrices show only their first 4.
    static func numericComponents(_ port: SZPort) -> [Double] {
        let defaults = (port.def?.floats ?? []).map(Double.init)
        func padded(_ n: Int) -> [Double] { (0..<n).map { $0 < defaults.count ? defaults[$0] : 0 } }
        switch port.type {
        case .float where port.sliderRange != nil: return []
        // Zero-padded to the rendered cell count — a port without a default still shows cells (of 0),
        // exactly like the view's component(i) fallback.
        case .float, .float2, .float3, .float4: return padded(componentCount(port.type))
        case .float3x3, .float4x4: return padded(4)
        default: return []
        }
    }

    /// Width of the slider's trailing value column, sized to the widest "%.2f" the range can produce
    /// (the two extremes bound every intermediate value's length) — so "10.00" / "-0.50" never clip.
    public static func sliderValueColumnWidth(_ range: ClosedRange<Double>) -> CGFloat {
        let chars = max(String(format: "%.2f", range.lowerBound).count,
                        String(format: "%.2f", range.upperBound).count)
        return max(26, CGFloat(chars) * valueCharWidth + 2)
    }

    /// Width of a whole numeric-fields row: `count` uniform fields + per-field padding + spacing.
    static func numericFieldsRowWidth(count: Int, fieldWidth: CGFloat) -> CGFloat {
        CGFloat(count) * (fieldWidth + 2 * cellHorizontalPadding) + CGFloat(count - 1) * cellSpacing
    }

    /// Character count of a component as the fields RENDER it — the very same FormatStyle
    /// (`.number.precision(.fractionLength(0...3))`, grouping included: 1234.5 → "1,234.5") so the
    /// estimate can never lag the render. A hand-rolled %.3f mirror omitted grouping separators and
    /// undercounted every |v| ≥ 1000. Memoized behind a Mutex: this is the inner loop of width(of:),
    /// which runs per socket per canvas evaluation on the drag hot path, and FormatStyle is one of
    /// the most expensive ways to measure a number; values repeat massively frame-to-frame.
    static func formattedNumericLength(_ v: Double) -> Int {
        if let hit = formattedLengthCache.withLock({ $0[v] }) { return hit }
        let length = v.formatted(.number.precision(.fractionLength(0...3))).count
        formattedLengthCache.withLock {
            if $0.count >= 4096 { $0.removeAll(keepingCapacity: true) }   // crude cap; refills instantly
            $0[v] = length
        }
        return length
    }

    private static let formattedLengthCache = Mutex<[Double: Int]>([:])

    /// Socket position relative to the node's CENTER. Flow sockets ride the header sides; data sockets
    /// ride their port row's left (input) / right (output) edge. An unknown data port falls back to
    /// the flow position so a half-wired edge still renders somewhere sane.
    public static func socketOffset(of node: SZNode, side: SZSocketSide, kind: SZConnectionKind, port: String) -> CGPoint {
        let x = side == .input ? -width(of: node) / 2 : width(of: node) / 2
        // A prompt node renders as a single field with flow sockets on its sides and shows NO per-port
        // rows — even when a contract is already attached (e.g. a camera prompt that declares its
        // permission). So every endpoint on a prompt card lands at the flow (side-center) position.
        guard node.kind == .generated else { return CGPoint(x: x, y: flowY(of: node)) }
        switch kind {
        case .flow:
            return CGPoint(x: x, y: flowY(of: node))
        case .data:
            let ports = side == .input ? inputs(of: node) : outputs(of: node)
            guard let index = ports.firstIndex(where: { $0.name == port }) else {
                return CGPoint(x: x, y: flowY(of: node))
            }
            let row = side == .input ? index : inputs(of: node).count + index
            return CGPoint(x: x, y: rowCenterY(of: node, row: row))
        }
    }

    /// Y of the flow sockets: header level for a generated node, card center for a prompt node.
    public static func flowY(of node: SZNode) -> CGFloat {
        switch node.kind {
        case .prompt: return 0
        case .generated: return -height(of: node) / 2 + headerHeight / 2
        }
    }

    /// Y center of the stacked port row `row` (0-based across inputs then outputs).
    public static func rowCenterY(of node: SZNode, row: Int) -> CGFloat {
        let bodyTop = -height(of: node) / 2 + headerHeight + bodyTopPadding
        return bodyTop + rowHeight / 2 + CGFloat(row) * (rowHeight + rowSpacing)
    }

    /// Screen → world: inverse of the canvas layer's `.scaleEffect(zoom).offset(canvasOffset)`.
    /// Used by gestures (drag / wire) to hit-test in graph coordinates at any zoom.
    public static func worldPoint(screen: CGPoint, zoom: CGFloat, offset: CGSize) -> CGPoint {
        let s = max(zoom, 0.1)
        return CGPoint(x: (screen.x - offset.width) / s, y: (screen.y - offset.height) / s)
    }

    /// Nearest grid intersection — each axis rounds to the nearest multiple of `pitch` (world space).
    public static func snapped(_ point: CGPoint, pitch: CGFloat = gridPitch) -> CGPoint {
        CGPoint(x: (point.x / pitch).rounded() * pitch,
                y: (point.y / pitch).rounded() * pitch)
    }

    /// The center that puts a card's TOP-LEFT corner on the nearest grid intersection. Edges are the
    /// snap anchor (not the center): with card dims all multiples of gridPitch, that lands all four
    /// edges on grid lines — center anchoring would need multiple-of-2·pitch dims to do the same.
    /// node.position stays the card center everywhere; only the snap target accounts for the size.
    public static func snappedCenter(_ center: CGPoint, size: CGSize, pitch: CGFloat = gridPitch) -> CGPoint {
        let topLeft = snapped(CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), pitch: pitch)
        return CGPoint(x: topLeft.x + size.width / 2, y: topLeft.y + size.height / 2)
    }
}
