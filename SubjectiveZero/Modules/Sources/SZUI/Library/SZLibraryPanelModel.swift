// SPDX-License-Identifier: AGPL-3.0-only
// The Library panel's list logic, SwiftUI-free so it is tested headlessly: which rows show for a
// query and a source chip, in which sections, where the keyboard highlight sits, and the small
// strings the panel prints. The view holds one of these and reads it.
import Foundation
import SZCore

struct SZLibraryPanelModel {
    struct Section: Identifiable {
        /// nil while a query is live: one ranked list, no group header.
        let group: SZLibraryGroup?
        let rows: [SZLibraryItem]
        /// Shut groups keep their header (and its count) and hide their rows.
        let collapsed: Bool
        var id: String { group?.rawValue ?? "search" }
        var title: String? { group?.displayName }
    }

    /// One library the chips can narrow to.
    struct Source: Identifiable, Equatable {
        let id: SZLibrarySourceID
        let name: String
    }

    var items: [SZLibraryItem] { didSet { rebuild(); clampHighlight() } }
    var query: String = "" { didSet { rebuild(); resetHighlight() } }
    var sourceFilter: SZLibrarySourceID? { didSet { rebuild(); resetHighlight() } }
    /// Groups the user shut. Their rows stay out of `flatRows`, so the keyboard walks only what shows.
    var collapsed: Set<SZLibraryGroup> { didSet { rebuild(); clampHighlight() } }
    var target: SZProjectTarget
    /// Library nodes the host left out because they have no source for this project's platform.
    var offPlatformCount: Int
    /// Index into `flatRows`; nil = nothing highlighted.
    private(set) var highlight: Int?
    /// Rebuilt when items, query or the chip change, so rows never sort per render.
    private(set) var sections: [Section] = []
    private(set) var flatRows: [SZLibraryItem] = []
    private(set) var rowIndex: [String: Int] = [:]

    init(items: [SZLibraryItem], target: SZProjectTarget, offPlatformCount: Int = 0, query: String = "",
         sourceFilter: SZLibrarySourceID? = nil, collapsed: Set<SZLibraryGroup> = []) {
        self.items = items
        self.target = target
        self.offPlatformCount = offPlatformCount
        self.query = query
        self.sourceFilter = sourceFilter
        self.collapsed = collapsed
        rebuild()
        resetHighlight()
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
        if needle.isEmpty {
            sections = SZLibraryGroup.allCases.compactMap { group in
                let rows = scoped.filter { $0.group == group }.sorted(by: Self.byTitleThenSource)
                return rows.isEmpty ? nil : Section(group: group, rows: rows,
                                                    collapsed: collapsed.contains(group))
            }
        } else {
            let ranked = scoped.compactMap { item in Self.rank(item, needle: needle).map { (rank: $0, item: item) } }
                .sorted { a, b in
                    if a.rank != b.rank { return a.rank < b.rank }
                    return Self.bySourceThenTitle(a.item, b.item)
                }
                .map(\.item)
            // A live query drops groups for one ranked list, so a shut group never hides a search hit.
            sections = ranked.isEmpty ? [] : [Section(group: nil, rows: ranked, collapsed: false)]
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

    /// Open a shut group, or shut an open one.
    mutating func toggle(_ group: SZLibraryGroup) {
        if collapsed.contains(group) { collapsed.remove(group) } else { collapsed.insert(group) }
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

    var emptyText: String? {
        if items.isEmpty {
            return target == .web ? "No library nodes for browser projects yet" : "The library is empty"
        }
        return flatRows.isEmpty ? "Nothing matches" : nil
    }

    /// The footer is a count and nothing else: "27 nodes".
    var footerText: String {
        let count = items.count
        return "\(count) \(count == 1 ? "node" : "nodes")"
    }

    /// Nodes this project can't use because they have no source for its platform. Shown under the
    /// search field only when there are some, where it says what to do about it.
    var offPlatformNote: String? {
        guard offPlatformCount > 0 else { return nil }
        let other: SZProjectTarget = target == .native ? .web : .native
        let noun = offPlatformCount == 1 ? "node needs" : "nodes need"
        return "\(offPlatformCount) \(noun) a project \(other.placeName)"
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
