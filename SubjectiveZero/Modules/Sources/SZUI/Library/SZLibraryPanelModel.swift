// SPDX-License-Identifier: AGPL-3.0-only
// The Library panel's list logic, SwiftUI-free so it is tested headlessly: which rows show for a
// query and a source chip, in which sections, where the keyboard highlight sits, and the small
// strings the panel prints. The view holds one of these and reads it.
import Foundation
import SZCore

struct SZLibraryPanelModel {
    struct Section: Identifiable {
        /// The section's own id, which is also what `collapsed` is keyed by: a group's raw value when
        /// sectioning by category, a library's key when sectioning by library, "search" for the one
        /// ranked list a query produces.
        let id: String
        /// nil while a query is live: one ranked list, no header at all.
        let title: String?
        /// The group whose colour the header wears. nil when the section is a library, which has no
        /// colour of its own.
        let group: SZLibraryGroup?
        let rows: [SZLibraryItem]
        /// A shut section keeps its header (and its count) and hides its rows.
        let collapsed: Bool
    }

    /// One library the chips can narrow to.
    struct Source: Identifiable, Equatable {
        let id: SZLibrarySourceID
        let name: String
    }

    var items: [SZLibraryItem] { didSet { dropFilterForAGoneLibrary(); rebuild(); clampHighlight() } }
    var query: String = "" { didSet { rebuild(); resetHighlight() } }
    var sourceFilter: SZLibrarySourceID? { didSet { rebuild(); resetHighlight() } }
    /// Sections the user shut, by section id. Their rows stay out of `flatRows`, so the keyboard walks
    /// only what shows.
    var collapsed: Set<String> { didSet { rebuild(); clampHighlight() } }
    /// Whether sections are what a node does, or which library it came from.
    var grouping: SZLibraryGrouping { didSet { rebuild(); clampHighlight() } }
    var target: SZProjectTarget
    /// Index into `flatRows`; nil = nothing highlighted.
    private(set) var highlight: Int?
    /// Rebuilt when items, query or the chip change, so rows never sort per render.
    private(set) var sections: [Section] = []
    private(set) var flatRows: [SZLibraryItem] = []
    private(set) var rowIndex: [String: Int] = [:]

    init(items: [SZLibraryItem], target: SZProjectTarget, query: String = "",
         sourceFilter: SZLibrarySourceID? = nil, collapsed: Set<String> = [],
         grouping: SZLibraryGrouping = .category) {
        self.items = items
        self.target = target
        self.query = query
        self.sourceFilter = sourceFilter
        self.collapsed = collapsed
        self.grouping = grouping
        rebuild()
        resetHighlight()
    }

    /// A chip filter naming a library that is no longer offering rows would leave the panel showing
    /// "Nothing matches" with an empty search field, and the chip row that could clear it is gone in
    /// the same moment. Removing a library, or one whose folder disappeared, both do this.
    private mutating func dropFilterForAGoneLibrary() {
        guard let filter = sourceFilter, !items.contains(where: { $0.source == filter }) else { return }
        sourceFilter = nil   // its own didSet rebuilds; the caller rebuilds again, which is cheap
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var scoped: [SZLibraryItem] {
        guard let sourceFilter else { return items }
        return items.filter { $0.source == sourceFilter }
    }

    /// Empty query: one titled section per group, in group order, empty groups left out. Any query:
    /// one untitled list, best match first.
    private mutating func rebuild() {
        let needle = trimmedQuery
        if needle.isEmpty, grouping == .category {
            sections = SZLibraryGroup.allCases.compactMap { group in
                let rows = scoped.filter { $0.group == group }.sorted(by: Self.byTitleThenSource)
                return rows.isEmpty ? nil : Section(id: group.rawValue, title: group.displayName,
                                                    group: group, rows: rows,
                                                    collapsed: collapsed.contains(group.rawValue))
            }
        } else if needle.isEmpty {
            // By library, in the order the host reads them: built in, then the user's, then added.
            var seen: [SZLibrarySourceID] = []
            for item in scoped where !seen.contains(item.source) { seen.append(item.source) }
            sections = seen.map { source in
                let rows = scoped.filter { $0.source == source }.sorted { a, b in
                    a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
                }
                return Section(id: source.rawValue, title: rows.first?.sourceName ?? source.displayName,
                               group: nil, rows: rows, collapsed: collapsed.contains(source.rawValue))
            }
        } else {
            let ranked = scoped.compactMap { item in Self.rank(item, needle: needle).map { (rank: $0, item: item) } }
                .sorted { a, b in
                    if a.rank != b.rank { return a.rank < b.rank }
                    return Self.bySourceThenTitle(a.item, b.item)
                }
                .map(\.item)
            // A live query drops sections for one ranked list, so a shut section never hides a hit.
            sections = ranked.isEmpty ? [] : [Section(id: "search", title: nil, group: nil,
                                                      rows: ranked, collapsed: false)]
        }
        flatRows = sections.filter { !$0.collapsed }.flatMap(\.rows)
        rowIndex = Dictionary(uniqueKeysWithValues: flatRows.enumerated().map { ($1.id, $0) })
    }

    /// id exact beats a title prefix beats a title substring beats any search term; nil = no match.
    private static func rank(_ item: SZLibraryItem, needle: String) -> Int? {
        let title = item.title.lowercased()
        if item.entryID.lowercased() == needle { return 0 }
        if title.hasPrefix(needle) { return 1 }
        if title.contains(needle) { return 2 }
        if item.matches(query: needle) { return 3 }   // every word lands somewhere, like the agents' index
        return nil
    }

    private static func bySourceThenTitle(_ a: SZLibraryItem, _ b: SZLibraryItem) -> Bool {
        if a.source.rawValue != b.source.rawValue { return a.source.rawValue < b.source.rawValue }
        return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    private static func byTitleThenSource(_ a: SZLibraryItem, _ b: SZLibraryItem) -> Bool {
        let order = a.title.localizedCaseInsensitiveCompare(b.title)
        if order != .orderedSame { return order == .orderedAscending }
        return a.source.rawValue < b.source.rawValue
    }

    // MARK: highlight

    /// Steps the highlight, wrapping at both ends; from nothing, down lands on the first row and up on the last.
    mutating func moveHighlight(_ delta: Int) {
        let count = flatRows.count
        guard count > 0 else { highlight = nil; return }
        highlight = ((highlight ?? (delta > 0 ? -1 : 0)) + delta + count) % count
    }

    /// First row while a query is live (Return places the best match), nothing otherwise.
    mutating func resetHighlight() {
        highlight = !trimmedQuery.isEmpty && !flatRows.isEmpty ? 0 : nil
    }

    mutating func setHighlight(_ index: Int?) {
        highlight = index.flatMap { flatRows.indices.contains($0) ? $0 : nil }
    }

    private mutating func clampHighlight() {
        if let highlight, !flatRows.indices.contains(highlight) { resetHighlight() }
    }

    func activate() -> SZLibraryRef? {
        guard let highlight, flatRows.indices.contains(highlight) else { return nil }
        return flatRows[highlight].ref
    }

    // MARK: chips and strings

    /// Every library the rows come from, in the order they first appear. Chips show once there are two.
    var sources: [Source] {
        var seen: [Source] = []
        for item in items where !seen.contains(where: { $0.id == item.source }) {
            seen.append(Source(id: item.source, name: item.sourceName))
        }
        return seen
    }

    var showsSourceChips: Bool { sources.count >= 2 }

    /// Whether a row should name its library after the title. Only when more than one library is
    /// offering rows AND the sections are not already libraries: otherwise two nodes with the same
    /// name from different libraries are two identical-looking rows.
    var rowsNameTheirLibrary: Bool { grouping == .category && sources.count >= 2 }

    var emptyText: String? {
        if items.isEmpty { return "The library is empty" }
        return flatRows.isEmpty ? "Nothing matches" : nil
    }

    /// The footer is a count, plus how many of those rows still need porting: "27 nodes, 7 to port".
    /// A person browsing a browser project should see at a glance that the short list is a porting
    /// backlog rather than the end of what the app can do.
    var footerText: String {
        let count = items.count
        let nodes = "\(count) \(count == 1 ? "node" : "nodes")"
        let unported = items.count { $0.portability == .portable }
        return unported == 0 ? nodes : "\(nodes), \(unported) to port"
    }
}

/// The drag pasteboard type a Library row carries: the ref as JSON, decoded by the canvas drop catcher.
enum SZLibraryDrag {
    static let typeIdentifier = "studio.sxp.subjectivezero.library-ref"

    static func data(for ref: SZLibraryRef) -> Data {
        (try? JSONEncoder().encode(ref)) ?? Data()
    }

    static func ref(from data: Data) -> SZLibraryRef? {
        try? JSONDecoder().decode(SZLibraryRef.self, from: data)
    }
}
