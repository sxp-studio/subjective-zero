// SPDX-License-Identifier: AGPL-3.0-only
// The Library panel: every node the libraries offer this project, searchable, grouped by what a node
// does. The list is names only; the strip at the bottom describes whatever the pointer is on. Values
// in (rows, target, collapsed groups, a focus counter), closures out; the host copies the folder.
//
// Four ways to place, all where the pointer already is: Add on the row, double-click, drag onto the
// canvas, or Return. The strip below the list explains why (`detail`).
//
// Keyboard: the search field owns focus. Arrows and Return are caught on the field's container (the
// context menu's recipe) so typing keeps working; Esc clears the query.
import AppKit
import SwiftUI
import SZCore

public struct SZLibraryPanel: View {
    private let items: [SZLibraryItem]
    private let target: SZProjectTarget
    private let collapsed: Set<String>
    private let grouping: SZLibraryGrouping
    /// Bumped by the host to focus the search field (the canvas menu's Add from Library).
    private let focusRequest: Int
    /// Whether an agent could write a missing platform's source. Without one an unported row is
    /// still shown, still says what it is, and simply cannot be added yet.
    private let canPort: Bool
    private let onPlace: (SZLibraryRef) -> Void
    private let onToggleSection: (String) -> Void
    private let onGroupingChanged: (SZLibraryGrouping) -> Void
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
    /// Room at the list's trailing edge for the overlay scroller to sit in.
    private static let scrollerGutter: CGFloat = 11
    /// Two lines of summary under the title, which is what most nodes need.
    public static let defaultDetailHeight: CGFloat = 58
    private static let detailRange: ClosedRange<CGFloat> = 34...260

    public init(items: [SZLibraryItem], target: SZProjectTarget,
                collapsed: Set<String> = [], grouping: SZLibraryGrouping = .category,
                focusRequest: Int, canPort: Bool = true,
                detailHeight: CGFloat = SZLibraryPanel.defaultDetailHeight,
                onPlace: @escaping (SZLibraryRef) -> Void,
                onToggleSection: @escaping (String) -> Void = { _ in },
                onGroupingChanged: @escaping (SZLibraryGrouping) -> Void = { _ in },
                onDetailHeightChanged: @escaping (CGFloat) -> Void = { _ in },
                onOpenLibrarySettings: @escaping () -> Void) {
        self.items = items
        self.target = target
        self.collapsed = collapsed
        self.grouping = grouping
        self.focusRequest = focusRequest
        self.canPort = canPort
        self.onPlace = onPlace
        self.onToggleSection = onToggleSection
        self.onGroupingChanged = onGroupingChanged
        self.onDetailHeightChanged = onDetailHeightChanged
        self.onOpenLibrarySettings = onOpenLibrarySettings
        _detailHeight = State(initialValue: detailHeight.clamped(to: SZLibraryPanel.detailRange))
        _model = State(initialValue: SZLibraryPanelModel(items: items, target: target,
                                                         collapsed: collapsed, grouping: grouping))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                searchField
                groupingMenu
            }
            if model.showsSourceChips { sourceChips }
            list
            detailSection
        }
        .padding(8)
        .onChange(of: items) { _, new in model.items = new }
        .onChange(of: target) { _, new in model.target = new }
        .onChange(of: collapsed) { _, new in model.collapsed = new }
        .onChange(of: grouping) { _, new in model.grouping = new }
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

    /// How the list is split. Two ways to read the same rows, so it is a menu rather than a control
    /// competing with the search field for width.
    private var groupingMenu: some View {
        Menu {
            Picker("Group by", selection: Binding(get: { grouping },
                                                  set: { onGroupingChanged($0) })) {
                ForEach(SZLibraryGrouping.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26)
        .help("Group by category or by library")
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
                    // The overlay scroller floats over the content; without this gutter it sits on
                    // top of a row's Add button and clips the section counts.
                    LazyVStack(alignment: .leading, spacing: 1, pinnedViews: []) {
                        ForEach(model.sections) { section in
                            if let title = section.title {
                                header(section.id, title: title, tint: section.group?.tint,
                                       count: section.rows.count, collapsed: section.collapsed)
                            }
                            if !section.collapsed {
                                ForEach(section.rows) { item in
                                    row(item)
                                }
                            }
                        }
                    }
                    .padding(.trailing, Self.scrollerGutter)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: model.highlight) { _, index in
                guard let index, model.flatRows.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(model.flatRows[index].id) }
            }
        }
    }

    /// The whole header line toggles the section. The chevron carries the section's colour when it has
    /// one, so collapsing costs no extra glyph and there is no small triangle to aim at. A library
    /// section has no colour of its own: the hue means what a node does, not where it came from.
    private func header(_ id: String, title: String, tint: Color?, count: Int, collapsed: Bool) -> some View {
        let accent = tint ?? Color.secondary
        return Button { onToggleSection(id) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(accent)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 9)
                Text(title)
                    .font(SZNodeCardStyle.labelFont)
                    .textCase(.uppercase)
                    .foregroundStyle(accent)
                    .lineLimit(1)
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
        // A node with no source for this platform yet is still a row: dimmed, and its button says
        // Port rather than Add. Hiding it would be the worse failure — a browser project would show
        // a short list and never say the rest is a porting job away rather than impossible.
        let unported = item.portability == .portable
        let addable = !unported || canPort
        return HStack(spacing: 7) {
            Image(systemName: item.sfSymbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 14)
                .foregroundStyle(item.group.tint)
            // The title and its library share a baseline: at 12pt against 10pt, centring the two
            // reads as one sitting low. They get their own stack so the glyph and Add stay centred
            // on the row, which is what those want.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if model.rowsNameTheirLibrary {
                    // Two libraries can both ship a "Gaussian Blur"; without this they are two
                    // identical rows. Right-aligned so the names read as one column rather than
                    // trailing each title at its own width.
                    Text(item.sourceName)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
            // Add keeps its slot whether or not it is showing: the library names hold their column,
            // and nothing shifts under the pointer on hover. No permission glyph here either, since
            // the strip says that in words.
            Button(unported ? "Port" : "Add") { onPlace(item.ref) }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 7)
                .frame(height: 16)
                .background(Capsule().fill(Color.white.opacity(addable ? 0.16 : 0.06)))
                .opacity(hovered || highlighted ? (addable ? 1 : 0.5) : 0)
                .allowsHitTesting((hovered || highlighted) && addable)
                .help(unported
                      ? (addable
                         ? "No \(target.sourceFileName) yet. Placing it asks an agent to write one."
                         : "No \(target.sourceFileName) yet, and no agent set up to write one.")
                      : "")
        }
        .opacity(unported ? 0.55 : 1)
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

    /// The description, its grab strip and the footer on one darker ground, bled past the panel's
    /// padding to all three edges: everything below the list is one surface, not more list.
    private var detailSection: some View {
        VStack(spacing: 0) {
            detailDivider
            detail
                .padding(.horizontal, 8)
                .padding(.top, 6)
            footer
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 8)
        }
        .background(Color.black.opacity(0.22))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
        }
        .padding(.horizontal, -8)
        .padding(.bottom, -8)
    }

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
                let needs = Self.needs(item, target: target, canPort: canPort)
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
    private static func needs(_ item: SZLibraryItem, target: SZProjectTarget, canPort: Bool) -> [String] {
        var out: [String] = []
        // First, because it is the one that decides whether the row can be used at all.
        if item.portability == .portable {
            out.append(canPort
                       ? "No \(target.placeName) version yet. Adding it asks an agent to write one."
                       : "No \(target.placeName) version yet, and no agent set up to write one.")
        }
        out += item.permissions.map(permissionWords)
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
                Text("Libraries…")
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
        .help("Open Library settings to add or update a library")
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
