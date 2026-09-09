// SPDX-License-Identifier: AGPL-3.0-only
// Saving a node into a library the user can write to: the folder is created on the first save
// (library.json, index.json), a save writes one node folder and its index entry, and the project node
// is stamped as a copy of that entry. Writing files is all this does; version control is the user's.
import Foundation
import SZCore

extension SZHost {
    /// The library folder, created with its `library.json` and an empty `index.json` the first time.
    /// Returns the folder.
    func ensureMyLibrary() throws -> URL {
        let url = myLibraryURL
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        // A real manifest from the start, so publishing it later is a matter of filling in the author
        // and the license rather than learning the file exists.
        try Self.writeManifest(SZLibraryManifest(name: SZLibrarySourceID.mine.displayName,
                                                 madeWith: Self.appVersion, version: "0.1.0"), to: url)
        try SZJSON.encoder().encode(SZLibraryCurationFile(nodes: [])).write(to: url.appending(path: "index.json"))
        return url
    }

    /// Save a built node as a My Library entry named from `name` (a node from My Library updates its own;
    /// a taken name gets -2, -3): contract with file inputs cleared, every built source, card, CARD.md with
    /// the prompt. The node then records the entry as its origin.
    @discardableResult
    /// `into` names a library the user can write to (one they created or added as a folder); without
    /// one the node goes to My Library, which is the answer for almost every save.
    func saveNodeToLibrary(node id: SZNodeID, name: String, line: String,
                           into target: SZLibrarySourceID? = nil,
                           origin: SZMutationOrigin = .user) throws -> SZLibraryRef {
        if let denial = fenceDenial(nodes: [id], origin: origin) { throw SZMCPError.message(denial) }
        guard let projectURL = loadedProjectURL else { throw SZMCPError.message("no project loaded") }
        guard let node = store.project?.graph.node(id: id) else { throw SZMCPError.message("no node \(id)") }
        let fm = FileManager.default
        let sources = SZProjectTarget.allCases.map { target in
            (target, SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: id, target: target))
        }.filter { fm.fileExists(atPath: $0.1.path) }
        guard node.kind == .generated, var contract = node.contract, !sources.isEmpty else {
            throw SZMCPError.message("This node has not been built yet")
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SZMCPError.message("The node needs a name") }

        let destination = target ?? .mine
        let library = try writableLibraryURL(destination)
        let entryID: String
        if node.librarySource == destination, let own = node.libraryID {
            entryID = own
        } else {
            let base = SZLibrarySlug.make(name)
            var candidate = base
            var n = 2
            while fm.fileExists(atPath: library.appending(path: candidate).path) {
                candidate = "\(base)-\(n)"
                n += 1
            }
            entryID = candidate
        }
        let folder = library.appending(path: entryID)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        contract.title = name
        contract.summary = line
        for i in contract.inputs.indices where contract.inputs[i].ui?.kind == .filePicker {
            contract.inputs[i].def = nil
        }
        try SZProjectIO.contractData(contract).write(to: folder.appending(path: "node-contract.json"), options: .atomic)
        for (target, url) in sources {
            try Self.replaceFile(at: folder.appending(path: target.sourceFileName), with: url)
        }
        let cardURL = SZProjectIO.cardSourceURL(projectURL: projectURL, nodeID: id)
        let libraryCard = folder.appending(path: "Card.swift")
        if fm.fileExists(atPath: cardURL.path) {
            try Self.replaceFile(at: libraryCard, with: cardURL)
        } else {
            try? fm.removeItem(at: libraryCard)   // the node dropped its card since the last save
        }
        let prompt = node.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try Data("# \(name)\n\n\(line)\n\n## Prompt\n\n\(prompt.isEmpty ? "(none)" : prompt)\n".utf8)
            .write(to: folder.appending(path: "CARD.md"), options: .atomic)

        var index = Self.libraryCuration(root: library)
        if let i = index.nodes.firstIndex(where: { $0.id == entryID }) {
            index.nodes[i].purpose = line
        } else {
            index.nodes.append(SZLibraryCurationEntry(id: entryID, tags: [], purpose: line))
        }
        try SZJSON.encoder().encode(index).write(to: library.appending(path: "index.json"), options: .atomic)
        // the project node is a copy of the entry from here on
        let liveBytes = sources.first { $0.0 == projectTarget }.flatMap { try? Data(contentsOf: $0.1) }
        store.mutate { project in
            guard let i = project.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
            project.graph.nodes[i].libraryID = entryID
            project.graph.nodes[i].librarySource = destination
            if let liveBytes {
                project.graph.nodes[i].copiedHash = Self.contentHash(liveBytes)
                project.graph.nodes[i].copiedTarget = projectTarget
            }
        }
        if let project = store.project { try SZProjectIO.save(project, to: projectURL) }
        noteMutation("saved node to library", [name], origin: origin)
        refreshLibraryItems()
        status = "Saved \(name) to \(libraryName(destination))"
        return .library(source: destination, id: entryID)
    }

    /// The folder a save may write into. My Library is created on demand; an added folder library is
    /// the user's own and may be written to; a library fetched from a link is not, because the next
    /// update would overwrite whatever we put there.
    func writableLibraryURL(_ source: SZLibrarySourceID) throws -> URL {
        if source == .mine { return try ensureMyLibrary() }
        guard let library = addedLibraries.first(where: { $0.key == source.rawValue }) else {
            throw SZMCPError.message("There is no library called \(source.rawValue)")
        }
        guard library.kind == .folder else {
            throw SZMCPError.message("\(library.name) came from a link, so it updates from there and can't be saved into. Save to My Library instead.")
        }
        return addedLibraryURL(library)
    }

    /// What the Save to Library sheet opens with: the node's title and summary, whether the save would
    /// update an entry the node came from, and which parts differ from that entry (source, ports, card).
    func saveToLibraryPreview(node id: SZNodeID, into destination: SZLibrarySourceID = .mine) -> (name: String, line: String, updates: Bool, changes: [String]) {
        guard let node = store.project?.graph.node(id: id) else { return ("", "", false, []) }
        let name = node.title
        let line = node.contract?.summary ?? ""
        guard node.librarySource == destination, let own = node.libraryID,
              let folder = libraryFolder(.library(source: .mine, id: own)), let projectURL = loadedProjectURL
        else { return (name, line, false, []) }
        let fm = FileManager.default
        var changes: [String] = []
        let live = SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: id, target: projectTarget)
        let saved = folder.appending(path: projectTarget.sourceFileName)
        if fm.fileExists(atPath: live.path), !fm.contentsEqual(atPath: live.path, andPath: saved.path) {
            changes.append("code changed")
        }
        let savedContract = (try? Data(contentsOf: folder.appending(path: "node-contract.json")))
            .flatMap { try? JSONDecoder().decode(SZNodeContract.self, from: $0) }
        if let contract = node.contract, contract.portSurface != savedContract?.portSurface {
            changes.append("ports changed")
        }
        let liveCard = SZProjectIO.cardSourceURL(projectURL: projectURL, nodeID: id)
        let savedCard = folder.appending(path: "Card.swift")
        let hasLiveCard = fm.fileExists(atPath: liveCard.path)
        if hasLiveCard != fm.fileExists(atPath: savedCard.path)
            || (hasLiveCard && !fm.contentsEqual(atPath: liveCard.path, andPath: savedCard.path)) {
            changes.append("card changed")
        }
        return (name, line, true, changes)
    }

    /// Move My Library so that `folder` is the library folder itself; an empty folder there is replaced.
    /// The path is remembered across launches. A library not created yet is simply created there later.
    func moveMyLibrary(to folder: URL) throws {
        let fm = FileManager.default
        let current = myLibraryURL
        guard folder.standardizedFileURL != current.standardizedFileURL else { return }
        if fm.fileExists(atPath: folder.path) {
            let contents = try fm.contentsOfDirectory(atPath: folder.path).filter { $0 != ".DS_Store" }
            guard contents.isEmpty else { throw SZMCPError.message("That folder is not empty") }
            try fm.removeItem(at: folder)
        }
        if fm.fileExists(atPath: current.path) {
            try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: current, to: folder)
        }
        myLibraryPath = folder.path
        persistAppState()
        refreshLibraryItems()
        status = "Moved \(SZLibrarySourceID.mine.displayName)"
    }

}
