// SPDX-License-Identifier: AGPL-3.0-only
// The Library panel's row model, the ids it hands back, and node lineage: which library a node
// folder lives in, what a placement copies from, the group read off a node's ports, the search
// matcher, and the family two copies share. Pure values, no UI.
import Foundation

/// Which library a node folder lives in. Built in ships with the app; `mine` is the user's own.
public struct SZLibrarySourceID: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let builtIn = SZLibrarySourceID(rawValue: "builtin")
    public static let mine = SZLibrarySourceID(rawValue: "mine")

    /// The name people see: the chip, the settings row, the status line.
    public var displayName: String {
        switch self {
        case .builtIn: "Built in"
        case .mine: "My Library"
        default: rawValue
        }
    }
}

/// How the Library panel splits its rows into sections: by what a node does, or by where it came
/// from. A browsing preference, remembered with the prefs.
public enum SZLibraryGrouping: String, CaseIterable, Codable, Sendable {
    case category, library

    public var displayName: String {
        switch self {
        case .category: "Category"
        case .library: "Library"
        }
    }
}

/// What a placement copies from: a node folder in a library, or a node already in the project (Duplicate).
public enum SZLibraryRef: Hashable, Codable, Sendable {
    case library(source: SZLibrarySourceID, id: String)
    case projectNode(SZNodeID)
}

/// The panel's section for a node, read off its ports: textures out with none in is a source, textures
/// in and out is an effect, sample arrays either way is audio, anything else that outputs is control.
public enum SZLibraryGroup: String, CaseIterable, Sendable {
    case sources, effects, audio, control

    public var displayName: String {
        switch self {
        case .sources: "Sources"
        case .effects: "Effects"
        case .audio: "Audio"
        case .control: "Control"
        }
    }

    public static func derived(inputs: [SZPortType], outputs: [SZPortType]) -> SZLibraryGroup {
        if outputs.contains(.texture) { return inputs.contains(.texture) ? .effects : .sources }
        if inputs.contains(.floatArray) || outputs.contains(.floatArray) { return .audio }
        return .control
    }
}

/// One matcher for the panel and the agents' index: every word of the query appears in some term.
public enum SZLibrarySearch {
    public static func matches(terms: [String], query: String) -> Bool {
        query.lowercased().split(whereSeparator: \.isWhitespace)
            .allSatisfy { needle in terms.contains { $0.contains(needle) } }
    }
}

extension SZLibraryIndexEntry {
    public var group: SZLibraryGroup {
        SZLibraryGroup.derived(inputs: io.inputs.map(\.type), outputs: io.outputs.map(\.type))
    }

    /// Lower-cased id, title, tags, purpose and summary.
    public var searchTerms: [String] {
        ([id, title] + (tags ?? []) + [purpose ?? "", summary]).filter { !$0.isEmpty }.map { $0.lowercased() }
    }

    public func matches(query: String) -> Bool { SZLibrarySearch.matches(terms: searchTerms, query: query) }
}

/// One row of the Library panel: a node folder in one library, with what the panel shows and searches.
public struct SZLibraryItem: Identifiable, Hashable, Sendable {
    public var source: SZLibrarySourceID
    public var entryID: String
    public var title: String
    public var sfSymbol: String
    public var summary: String
    public var group: SZLibraryGroup
    public var searchTerms: [String]
    public var permissions: [SZEntitlement]
    public var hasCard: Bool
    /// Whether this node runs on the open project's platform, could be ported to it, or never will.
    /// A node is one row whatever it runs on: hiding one that could work is the worse failure, so
    /// the row says which of the three it is instead of disappearing (`SZLibraryPortability`).
    public var portability: SZLibraryPortability
    /// What this library calls itself. An added library's key is not a name, so the host passes the
    /// one from its manifest; the two built-in ones name themselves.
    public var sourceName: String

    public var id: String { "\(source.rawValue)/\(entryID)" }
    public var ref: SZLibraryRef { .library(source: source, id: entryID) }

    public init(entry: SZLibraryIndexEntry, source: SZLibrarySourceID, sourceName: String? = nil,
                portability: SZLibraryPortability = .runs) {
        self.source = source
        self.portability = portability
        self.sourceName = sourceName ?? source.displayName
        self.entryID = entry.id
        self.title = entry.title
        self.sfSymbol = entry.sfSymbol
        self.summary = entry.purpose ?? entry.summary
        self.group = entry.group
        self.searchTerms = entry.searchTerms
        self.permissions = entry.permissions ?? []
        self.hasCard = entry.card == true
    }

    public func matches(query: String) -> Bool { SZLibrarySearch.matches(terms: searchTerms, query: query) }
}

/// The folder name a saved node gets from its name: lower-case ASCII letters and digits, anything
/// else one hyphen, none at the ends; "node" when nothing is left.
public enum SZLibrarySlug {
    public static func make(_ name: String) -> String {
        var out = ""
        for c in name.lowercased() {
            if c.isASCII, c.isLetter || c.isNumber { out.append(c) }
            else if !out.isEmpty, !out.hasSuffix("-") { out.append("-") }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "node" : out
    }
}

// MARK: - Lineage

extension SZNode {
    /// The library entry this node was placed from, or nil for a node an agent wrote.
    public var libraryRef: SZLibraryRef? {
        libraryID.map { .library(source: librarySource ?? .builtIn, id: $0) }
    }
}

extension SZGraph {
    /// The key copies of one thing share: the library entry when placed from one, else the root of the
    /// `copiedFrom` chain, else the node itself.
    public func lineageFamily(of id: SZNodeID) -> String {
        var current = id
        var seen: Set<SZNodeID> = [id]
        while let node = node(id: current) {
            if case .library(let source, let entry)? = node.libraryRef { return "\(source.rawValue)/\(entry)" }
            guard let parent = node.copiedFrom, !seen.contains(parent), self.node(id: parent) != nil else { break }
            seen.insert(parent)
            current = parent
        }
        return current.uuidString
    }
}
