// SPDX-License-Identifier: AGPL-3.0-only
// The Library panel: every node the libraries offer this project, searchable, grouped by what a node
// does. The list is names only; the strip at the bottom describes whatever the pointer is on. Values
// in (rows, target, collapsed groups, a focus counter), closures out; the host copies the folder.
//
// The strip holds NO control. Add sits on the row itself, so choosing a node never means dragging the
// pointer down across other rows (which would repaint the strip on the way). Four ways in, all of them
// where the pointer already is: Add on the row, double-click, drag onto the canvas, or Return.
//
// Keyboard: the search field owns focus. Arrows and Return are caught on the field's container (the
// context menu's recipe) so typing keeps working; Esc clears the query.
import AppKit
import SwiftUI
import SZCore

public struct SZLibraryPanel: View {
    private let items: [SZLibraryItem]
    private let target: SZProjectTarget
    /// Library nodes with no source for this platform; a note under the search field says how many.
    private let offPlatformCount: Int
    private let collapsed: Set<SZLibraryGroup>
    /// Bumped by the host to focus the search field (⌘L, Add from Library).
    private let focusRequest: Int
    private let onPlace: (SZLibraryRef) -> Void
    private let onToggleGroup: (SZLibraryGroup) -> Void
    private let onDetailHeightChanged: (CGFloat) -> Void
    private let onOpenLibrarySettings: () -> Void

    @State private var model: SZLibraryPanelModel
    @State private var hoveredRow: String?
    /// What the strip describes. Sticky: pointing elsewhere replaces it, leaving the list does not
    /// clear it, so nothing flickers to empty on the way to the canvas.
    @State private var described: SZLibraryItem?
    @FocusState private var searchFocused: Bool
    /// How tall the description strip is. It is the list that grows with the window; the strip
    /// stays where the person put it.
    @State private var detailHeight: CGFloat
    /// The height the current drag measures from.
    @State private var detailHeightAtDragStart: CGFloat = 0

    private static let rowHeight: CGFloat = 26
    /// Two lines of summary under the title, which is what most nodes need.
    public static let defaultDetailHeight: CGFloat = 58
    private static let detailRange: ClosedRange<CGFloat> = 34...260

    public init(items: [SZLibraryItem], target: SZProjectTarget, offPlatformCount: Int = 0,
                collapsed: Set<SZLibraryGroup> = [], focusRequest: Int,
                detailHeight: CGFloat = SZLibraryPanel.defaultDetailHeight,
                onPlace: @escaping (SZLibraryRef) -> Void,
                onToggleGroup: @escaping (SZLibraryGroup) -> Void = { _ in },
                onDetailHeightChanged: @escaping (CGFloat) -> Void = { _ in },
                onOpenLibrarySettings: @escaping () -> Void) {
        self.items = items
        self.target = target
        self.offPlatformCount = offPlatformCount
        self.collapsed = collapsed
        self.focusRequest = focusRequest
        self.onPlace = onPlace
        self.onToggleGroup = onToggleGroup
        self.onDetailHeightChanged = onDetailHeightChanged
        self.onOpenLibrarySettings = onOpenLibrarySettings
        _detailHeight = State(initialValue: detailHeight.clamped(to: SZLibraryPanel.detailRange))
        _model = State(initialValue: SZLibraryPanelModel(items: items, target: target,
                                                         offPlatformCount: offPlatformCount,
                                                         collapsed: collapsed))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchField
            if let note = model.offPlatformNote { offPlatformNote(note) }
            if model.showsSourceChips { sourceChips }
            list
            detailDivider
            detail
            footer
        }
        .padding(8)
        .onChange(of: items) { _, new in model.items = new }
        .onChange(of: target) { _, new in model.target = new }
        .onChange(of: offPlatformCount) { _, new in model.offPlatformCount = new }
        .onChange(of: collapsed) { _, new in model.collapsed = new }
        .onChange(of: focusRequest) { _, _ in focusSearch() }
        // Arrow keys describe what they land on, so the strip follows the keyboard as well as the mouse.
        .onChange(of: model.highlight) { _, _ in describeHighlight() }
        .onKeyPress(.upArrow) { model.moveHighlight(-1); return .handled }
        .onKeyPress(.downArrow) { model.moveHighlight(1); return .handled }
        .onKeyPress(.return) { placeHighlight() ? .handled : .ignored }
        .onExitCommand { model.query = "" }
    }

    // MARK: search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            // Native placeholders can't be styled; an italic tertiary overlay reads as an instruction.
            TextField("", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit { _ = placeHighlight() }
                .overlay(alignment: .leading) {
                    if model.query.isEmpty {
                        Text("Search the library")
                            .font(.system(size: 12).italic())
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                }
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .szGlassCard(cornerRadius: 6)
    }

    private func offPlatformNote(_ note: String) -> some View {
        Text(note)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .padding(.horizontal, 2)
    }

    private func focusSearch() {
        searchFocused = true
        // Select the old query so typing replaces it; the field must be first responder first.
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    // MARK: chips

    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                chip("All", selected: model.sourceFilter == nil) { model.sourceFilter = nil }
                ForEach(model.sources) { source in
                    chip(source.name, selected: model.sourceFilter == source.id) {
                        model.sourceFilter = source.id
                    }
                }
            }
        }
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(selected ? Color.white.opacity(0.18) : SZNodeCardStyle.chipFill))
        }
        .buttonStyle(.plain)
    }

    // MARK: list

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let emptyText = model.emptyText {
                    Text(emptyText)
                        .font(.system(size: 12).italic())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else {
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: []) {
                        ForEach(model.sections) { section in
                            if let group = section.group {
                                header(group, count: section.rows.count, collapsed: section.collapsed)
                            }
                            if !section.collapsed {
                                ForEach(section.rows) { item in
                                    row(item)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: model.highlight) { _, index in
                guard let index, model.flatRows.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(model.flatRows[index].id) }
            }
        }
    }

    /// The whole header line toggles the group. The chevron carries the group's colour, so collapsing
    /// costs no extra glyph and there is no small triangle to aim at.
    private func header(_ group: SZLibraryGroup, count: Int, collapsed: Bool) -> some View {
        Button { onToggleGroup(group) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(group.tint)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 9)
                Text(group.displayName)
                    .font(SZNodeCardStyle.labelFont)
                    .textCase(.uppercase)
                    .foregroundStyle(group.tint)
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 1)
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(collapsed ? .secondary : .tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.top, 9)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: collapsed)
    }

    private func row(_ item: SZLibraryItem) -> some View {
        let index = model.rowIndex[item.id]
        let highlighted = index != nil && index == model.highlight
        let hovered = hoveredRow == item.id
        return HStack(spacing: 7) {
            Image(systemName: item.sfSymbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
                .foregroundStyle(item.group.tint)
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            // No permission glyph here: the strip says it in words, which leaves this edge free for
            // Add. That is what stops the two from trading places on hover.
            if hovered || highlighted {
                Button("Add") { onPlace(item.ref) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7)
                    .frame(height: 16)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(highlighted || hovered ? Color.white.opacity(0.10) : .clear))
        .contentShape(Rectangle())
        .id(item.id)
        .onHover { inside in
            guard inside else {
                if hoveredRow == item.id { hoveredRow = nil }
                return
            }
            hoveredRow = item.id
            described = item
        }
        .onTapGesture(count: 2) { onPlace(item.ref) }
        // Simultaneous, not a second `onTapGesture`: a plain single tap would wait out the double-tap
        // window before it fired, which is the click lag.
        .simultaneousGesture(TapGesture().onEnded { model.setHighlight(index) })
        .onDrag {
            NSItemProvider(item: SZLibraryDrag.data(for: item.ref) as NSData,
                           typeIdentifier: SZLibraryDrag.typeIdentifier)
        }
    }

    // MARK: detail strip

    /// The grab strip over the description: drag it up for more room, double click to put it back.
    private var detailDivider: some View {
        SZSidebarDivider(axis: .horizontal,
                         onDragBegan: { detailHeightAtDragStart = detailHeight },
                         onDrag: { travel in
                             // Up is positive, and up is the direction that grows the strip.
                             detailHeight = (detailHeightAtDragStart + travel).clamped(to: Self.detailRange)
                         },
                         onDoubleClick: { detailHeight = Self.defaultDetailHeight })
            .frame(height: 7)
            .overlay(Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1))
            .onChange(of: detailHeight) { _, new in onDetailHeightChanged(new) }
    }

    /// What the pointer is on, in full. A read-out, never a control: the moment it holds a button,
    /// reaching that button means crossing rows that would repaint this. Fixed height, so the list
    /// takes every point the window gives and this stays as small as it was left.
    private var detail: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let item = described {
                HStack(spacing: 6) {
                    Image(systemName: item.sfSymbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(item.group.tint)
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                Text(item.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let needs = Self.needs(item)
                if !needs.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(needs, id: \.self) { need in
                            Text(need)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .frame(height: 15)
                                .background(Capsule().fill(SZNodeCardStyle.chipFill))
                        }
                    }
                }
            } else {
                Text("Point at a node to see what it does.")
                    .font(.system(size: 11).italic())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // A long summary in a short strip is reachable rather than clipped away.
        .modifier(SZScrollIfTaller())
        .frame(height: detailHeight, alignment: .topLeading)
        .clipped()
    }

    /// What the node asks for, in words rather than a glyph nobody can decode.
    private static func needs(_ item: SZLibraryItem) -> [String] {
        var out = item.permissions.map(permissionWords)
        if item.hasCard { out.append("Ships a custom card") }
        if item.source != .builtIn { out.append("From \(item.sourceName)") }
        return out
    }

    private static func permissionWords(_ permission: SZEntitlement) -> String {
        switch permission {
        case .camera: "Uses the camera"
        case .microphone: "Uses the microphone"
        case .screenRecording: "Records this screen"
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.footerText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 4)
            SZLibraryAddButton(action: onOpenLibrarySettings)
        }
    }

    private func describeHighlight() {
        guard let index = model.highlight, model.flatRows.indices.contains(index) else { return }
        described = model.flatRows[index]
    }

    private func placeHighlight() -> Bool {
        guard let ref = model.activate() else { return false }
        onPlace(ref)
        return true
    }
}

/// Lets the description scroll when it is taller than the strip the person left it, without
/// making the strip itself scrollable-looking when it is not.
private struct SZScrollIfTaller: ViewModifier {
    func body(content: Content) -> some View {
        ScrollView(.vertical, showsIndicators: false) { content }
            .scrollBounceBehavior(.basedOnSize)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// The footer's Add library: a real button with a border, a hover and a pressed state, one step
/// quieter than a row's Add because it is the secondary action.
private struct SZLibraryAddButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Text("Add library")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(hovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.13 : 0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(hovered ? 0.20 : 0.11))
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Add a library from a folder or a link")
    }
}

/// One hue per group, on the chevron, the header and the row glyph. Derived from the contract like
/// the grouping itself, so a node's colour is never a curated choice.
extension SZLibraryGroup {
    var tint: Color {
        switch self {
        case .sources: Color(red: 0.878, green: 0.643, blue: 0.290)
        case .effects: Color(red: 0.349, green: 0.663, blue: 0.867)
        case .audio:   Color(red: 0.635, green: 0.518, blue: 0.851)
        case .control: Color(red: 0.408, green: 0.741, blue: 0.510)
        }
    }
}
