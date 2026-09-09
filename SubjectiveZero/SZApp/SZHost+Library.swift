// SPDX-License-Identifier: AGPL-3.0-only
// The node libraries the host reads: the built-in one in the bundle and the user's own folder. One scan
// per root (`refreshLibraryItems`) feeds the panel's rows, the agents' index and every placement, so what
// a person browses and what an agent reads is one list.
import Foundation
import SZCore

extension SZHost {
    /// The built-in node library (`NodeLibrary/`): the copy bundled in the app, else the source tree via
    /// `#filePath` for `swift test` and running from the checkout.
    nonisolated static var builtInLibraryURL: URL {
        if let bundled = Bundle.main.resourceURL?.appending(path: "NodeLibrary"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "NodeLibrary")
    }

    /// The user's own library: the moved folder when there is one, else the default under Application Support.
    var myLibraryURL: URL {
        myLibraryPath.map { URL(filePath: $0) } ?? SZAppSupport.directory.appending(path: "library")
    }

    /// Every library to read: built in first, the user's own once its folder exists, then the ones
    /// they added, in the order they added them. A library whose folder has gone (an unplugged disk,
    /// a folder someone moved) is skipped rather than dropped, so it comes back when the folder does.
    var libraryRoots: [(source: SZLibrarySourceID, url: URL)] {
        var roots = [(source: SZLibrarySourceID.builtIn, url: Self.builtInLibraryURL)]
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: myLibraryURL.path, isDirectory: &isDir), isDir.boolValue {
            roots.append((.mine, myLibraryURL))
        }
        for library in addedLibraries {
            let url = addedLibraryURL(library)
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                roots.append((library.source, url))
            }
        }
        return roots
    }

    /// Libraries whose folder is not there right now; the settings row says so.
    var missingLibraryKeys: Set<String> {
        let present = Set(libraryRoots.map(\.source.rawValue))
        return Set(addedLibraries.map(\.key).filter { !present.contains($0) })
    }

    /// A root's `index.json`, empty when missing or unreadable.
    nonisolated static func libraryCuration(root: URL) -> SZLibraryCurationFile {
        (try? Data(contentsOf: root.appending(path: "index.json")))
            .flatMap { try? JSONDecoder().decode(SZLibraryCurationFile.self, from: $0) }
            ?? SZLibraryCurationFile(nodes: [])
    }

    /// Scan one library root for node folders (a `node-contract.json` inside): identity, typed I/O and
    /// permissions from the contract, the discovery fields from the root's `index.json`. Sorted by id.
    nonisolated static func libraryCatalog(root: URL) -> [SZLibraryIndexEntry] {
        let fm = FileManager.default
        let curation = libraryCuration(root: root).byID
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var entries: [SZLibraryIndexEntry] = []
        for folder in folders {
            guard let data = try? Data(contentsOf: folder.appending(path: "node-contract.json")),
                  let contract = try? JSONDecoder().decode(SZNodeContract.self, from: data) else { continue }
            let id = folder.lastPathComponent
            let hasCard = fm.fileExists(atPath: folder.appending(path: "Card.swift").path)
            entries.append(SZLibraryIndexEntry(id: id, contract: contract, curation: curation[id], hasCard: hasCard))
        }
        entries.sort { $0.id < $1.id }
        return entries
    }

    /// One entry in one library, with its folder and the platforms it has a source file for.
    struct SZLibraryEntry {
        var source: SZLibrarySourceID
        var folder: URL
        var entry: SZLibraryIndexEntry
        var builtTargets: Set<SZProjectTarget>
        var ref: SZLibraryRef { .library(source: source, id: entry.id) }
    }

    /// Scan every root once: the cache behind the panel, the agents' index and the settings counts.
    /// Called after a project open, a target switch, a save and a move.
    func refreshLibraryItems() {
        let fm = FileManager.default
        libraryEntries = libraryRoots.flatMap { root in
            Self.libraryCatalog(root: root.url).map { entry in
                let folder = root.url.appending(path: entry.id)
                let built = Set(SZProjectTarget.allCases.filter {
                    fm.fileExists(atPath: folder.appending(path: $0.sourceFileName).path)
                })
                return SZLibraryEntry(source: root.source, folder: folder, entry: entry, builtTargets: built)
            }
        }
        libraryItems = libraryEntries(target: projectTarget).map {
            SZLibraryItem(entry: $0.entry, source: $0.source, sourceName: libraryName($0.source))
        }
        libraryOffPlatformCount = libraryEntries.filter { !$0.builtTargets.contains(projectTarget) && !$0.builtTargets.isEmpty }.count
    }

    /// The cached entries with a source file for `target`, root order then id.
    func libraryEntries(target: SZProjectTarget) -> [SZLibraryEntry] {
        libraryEntries.filter { $0.builtTargets.contains(target) }
    }

    /// Node folders per library, for the settings pane; nil for a library that does not exist yet.
    func libraryNodeCount(_ source: SZLibrarySourceID) -> Int? {
        libraryRoots.contains { $0.source == source } ? libraryEntries.filter { $0.source == source }.count : nil
    }

    /// A library id is one folder name: no separators, no `.` or `..`.
    nonisolated static func isLibraryID(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/") && id != "." && id != ".."
    }

    /// The folder a placement copies from: `<root>/<id>` for a library entry (the id validated as a single
    /// path component), the project's `nodes/<uuid>/` for a node already in it. nil when it is not there.
    func libraryFolder(_ ref: SZLibraryRef) -> URL? {
        switch ref {
        case .library(let source, let id):
            guard Self.isLibraryID(id), let root = libraryRoots.first(where: { $0.source == source }) else { return nil }
            let folder = root.url.appending(path: id)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            return folder
        case .projectNode(let id):
            guard let projectURL = loadedProjectURL, store.project?.graph.node(id: id) != nil else { return nil }
            return SZProjectIO.nodeFolderURL(projectURL: projectURL, nodeID: id)
        }
    }

    /// Resolve an id the agent tools name: `library` picks the root; omitted, the first root that has the
    /// folder wins, built in first.
    func libraryFolder(id: String, library: SZLibrarySourceID?) -> (source: SZLibrarySourceID, folder: URL)? {
        for root in libraryRoots where library == nil || root.source == library {
            if let folder = libraryFolder(.library(source: root.source, id: id)) { return (root.source, folder) }
        }
        return nil
    }

    /// Node folders per added library, for the settings rows.
    func addedLibraryCount(_ key: String) -> Int {
        libraryEntries.filter { $0.source.rawValue == key }.count
    }

    /// The title of a library entry, for status lines; the id when it is not in the cache.
    func libraryTitle(source: SZLibrarySourceID, id: String) -> String {
        libraryEntries.first { $0.source == source && $0.entry.id == id }?.entry.title ?? id
    }

    /// The agents' tier 1: the offered entries grouped like the panel, one line per node; `query` keeps
    /// entries matching every term; nil when nothing is offered. Not ranked, the reader judges; a line
    /// names a non-built-in library since ids can repeat.
    func libraryCategoriesBlock(target: SZProjectTarget, query: String? = nil) -> String? {
        func ports(_ list: [SZLibraryIndexEntry.Port]) -> String {
            list.isEmpty ? "none" : list.map { "\($0.name):\($0.type.rawValue)" }.joined(separator: ",")
        }
        let entries = libraryEntries(target: target).filter { query.map($0.entry.matches(query:)) ?? true }
        let byGroup = Dictionary(grouping: entries, by: { $0.entry.group.rawValue })
        guard !byGroup.isEmpty else { return nil }
        return byGroup.keys.sorted().map { group -> String in
            let lines = (byGroup[group] ?? []).map { item -> String in
                let entry = item.entry
                let permissions = (entry.permissions?.map(\.rawValue) ?? []).joined(separator: ",")
                let tags = (entry.tags ?? []).joined(separator: " ")
                var facts = ["in \(ports(entry.io.inputs))", "out \(ports(entry.io.outputs))"]
                if !permissions.isEmpty { facts.append("needs \(permissions)") }
                if entry.card == true { facts.append("ships a card") }
                if let reuse = entry.reuse { facts.append(reuse) }
                if !tags.isEmpty { facts.append(tags) }
                if item.source != .builtIn { facts.append("library: \(libraryName(item.source))") }
                return "  \(entry.id) — \(entry.purpose ?? entry.summary) [\(facts.joined(separator: " | "))]"
            }
            return "\(group):\n\(lines.joined(separator: "\n"))"
        }.joined(separator: "\n")
    }

    /// Past this many offered entries a cold-start brief carries counts and a pointer to the tool
    /// instead of the whole block.
    static let libraryInlineLimit = 60

    /// What a cold-start coding brief embeds: the whole block while the library is small, else per-group
    /// counts, the library names, and how to search.
    func libraryBriefBlock(target: SZProjectTarget) -> String? {
        let entries = libraryEntries(target: target)
        guard !entries.isEmpty else { return nil }
        guard entries.count > Self.libraryInlineLimit else { return libraryCategoriesBlock(target: target) }
        let counts = Dictionary(grouping: entries, by: { $0.entry.group.rawValue })
            .sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.count)" }.joined(separator: ", ")
        let libraries = libraryRoots.map { libraryName($0.source) }.joined(separator: ", ")
        return "\(entries.count) library nodes (\(counts)) across \(libraries). "
            + "Search them with agent_library_index { \"query\": \"...\" } before writing your own."
    }
}
