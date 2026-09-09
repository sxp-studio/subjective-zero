// SPDX-License-Identifier: AGPL-3.0-only
// Libraries beyond the two the app ships with: making one, adding one from a folder or a link,
// moving it to a newer version, and forgetting it.
//
// A library is a folder of node folders. A link is somewhere to download a copy of one from, and
// that copy is read-only: the app never runs anybody's version control. Whoever maintains a library
// does that in their own repository with their own tools. Nothing here runs on its own either:
// every fetch is something a person asked for. The download itself is SZHost+LibraryArchive.
import Foundation
import SZCore

extension SZHost {
    /// Where a library fetched from a link is unpacked. One folder per library key.
    nonisolated static var fetchedLibrariesURL: URL {
        SZAppSupport.directory.appending(path: "libraries")
    }

    func fetchedLibraryURL(key: String) -> URL {
        Self.fetchedLibrariesURL.appending(path: key)
    }

    /// The folder a library is read from: where it was fetched, or the folder it lives in.
    func addedLibraryURL(_ library: SZAddedLibrary) -> URL {
        switch library.kind {
        case .folder: URL(filePath: library.origin)
        case .link: fetchedLibraryURL(key: library.key)
        }
    }

    /// Keys nothing new may take: the two built-in ones and everything already added.
    var takenLibraryKeys: Set<String> {
        Set([SZLibrarySourceID.builtIn.rawValue, SZLibrarySourceID.mine.rawValue]
            + addedLibraries.map(\.key))
    }

    /// The name to show for a library, from the registry when it is one of the added ones.
    func libraryName(_ source: SZLibrarySourceID) -> String {
        addedLibraries.first { $0.key == source.rawValue }?.name ?? source.displayName
    }

    /// This build's version ("0.4.0"), or "dev" when it has none. What a new library records as the
    /// SubjectiveZero it was made with, and what an added library's `minAppVersion` is checked against.
    nonisolated static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // MARK: reading a library's own manifest

    /// A library's `library.json`. Missing or unreadable is not fatal: a plain folder of node folders
    /// is still a library, it just has no name of its own.
    nonisolated static func libraryManifest(at root: URL) -> SZLibraryManifest? {
        guard let data = try? Data(contentsOf: root.appending(path: "library.json")) else { return nil }
        return try? JSONDecoder().decode(SZLibraryManifest.self, from: data)
    }

    /// Write a library's `library.json`, pretty-printed and key-sorted so a person can read the file
    /// and a commit diff shows only what actually changed.
    nonisolated static func writeManifest(_ manifest: SZLibraryManifest, to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: root.appending(path: "library.json"), options: .atomic)
    }

    /// What makes a folder a library: at least one node folder in it. Checked before anything is
    /// remembered, so a mistyped path fails at the point the person can still fix it.
    nonisolated static func isLibraryFolder(_ root: URL) -> Bool {
        !libraryCatalog(root: root).isEmpty
    }

    // MARK: create

    /// Make a new, empty library and add it: a folder with a `library.json` naming its author and
    /// license and an empty index. `folder` puts it where the user wants; without one it goes beside
    /// the fetched ones under Application Support. Version control, if they want it, is theirs.
    @discardableResult
    func createLibrary(name: String, author: String? = nil, license: String? = nil,
                       description: String? = nil, at folder: URL? = nil) throws -> SZAddedLibrary {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SZMCPError.message("A library needs a name") }
        let key = SZLibraryKey.make(from: name, taken: takenLibraryKeys)
        let root = folder ?? fetchedLibraryURL(key: key)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: root.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw SZMCPError.message("There is a file at \(root.path)") }
            guard (try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty != false else {
                throw SZMCPError.message("That folder already has something in it")
            }
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // A version from the start, because "keep it updated" needs a number to compare. Saving a
        // node never bumps it: that is a deliberate edit, not a side effect of a playtest tweak.
        let manifest = SZLibraryManifest(name: name, description: description, author: author,
                                         license: license, madeWith: Self.appVersion, version: "0.1.0")
        try Self.writeManifest(manifest, to: root)
        try SZJSON.encoder().encode(SZLibraryCurationFile(nodes: []))
            .write(to: root.appending(path: "index.json"), options: .atomic)
        let library = SZAddedLibrary(key: key, name: name, kind: .folder, origin: root.path,
                                     manifest: manifest)
        register(library)
        return library
    }

    // MARK: add

    /// Add a folder on this Mac, read where it is. A library someone keeps under their own version
    /// control stays theirs to manage.
    @discardableResult
    func addLibraryFolder(at url: URL) throws -> SZAddedLibrary {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw SZMCPError.message("There is no folder at \(url.path)")
        }
        if let existing = addedLibraries.first(where: { $0.kind == .folder && $0.origin == url.path }) {
            throw SZMCPError.message("\(existing.name) is already in your libraries")
        }
        guard Self.isLibraryFolder(url) else {
            throw SZMCPError.message("That folder has no nodes in it")
        }
        let manifest = Self.libraryManifest(at: url)
        if let refusal = manifest?.refusal(appVersion: Self.appVersion) { throw SZMCPError.message(refusal) }
        let name = manifest?.name ?? url.lastPathComponent
        let library = SZAddedLibrary(key: SZLibraryKey.make(from: name, taken: takenLibraryKeys),
                                     name: name, kind: .folder, origin: url.path, manifest: manifest)
        register(library)
        return library
    }

    /// Add a library from a link: download a copy, check it is a library this app can run, and keep
    /// the files. The copy is read-only; updating replaces it with a newer one. A failed add leaves
    /// nothing behind, including after a kill mid-download.
    @discardableResult
    func addLibraryLink(_ text: String) async throws -> SZAddedLibrary {
        guard let link = SZLibraryLink.parse(text) else {
            throw SZMCPError.message("That does not look like a library link. Use a link like https://github.com/someone/their-nodes")
        }
        if let existing = addedLibraries.first(where: { $0.kind == .link && $0.origin == link.url }) {
            throw SZMCPError.message("\(existing.name) is already in your libraries")
        }
        guard let copy = try await Self.fetchLibrary(from: link) else {
            throw SZMCPError.message("That link didn't give back a library archive.")
        }
        let fm = FileManager.default
        defer { try? fm.removeItem(at: copy.staging) }

        guard Self.isLibraryFolder(copy.folder) else {
            throw SZMCPError.message("There are no nodes in that library")
        }
        let manifest = Self.libraryManifest(at: copy.folder)
        // Checked before anything is kept: an app too old for the library would fail every node one
        // at a time instead of saying so once, here.
        if let refusal = manifest?.refusal(appVersion: Self.appVersion) { throw SZMCPError.message(refusal) }

        let name = manifest?.name ?? link.shortName
        let key = SZLibraryKey.make(from: link.shortName.replacingOccurrences(of: "/", with: "-"),
                                    taken: takenLibraryKeys)
        let folder = fetchedLibraryURL(key: key)
        try fm.createDirectory(at: Self.fetchedLibrariesURL, withIntermediateDirectories: true)
        try? fm.removeItem(at: folder)
        try fm.moveItem(at: copy.folder, to: folder)

        let library = SZAddedLibrary(key: key, name: name, kind: .link, origin: link.url,
                                     etag: copy.etag, manifest: manifest)
        register(library)
        return library
    }

    /// Forget a library. Nodes already on a canvas are copies, so nothing in any project changes; a
    /// library that was fetched has its folder deleted, one that lives in a folder is left alone, and
    /// any ports written for its nodes go with it.
    func removeLibrary(key: String) {
        guard let library = addedLibraries.first(where: { $0.key == key }) else { return }
        discardStagedUpdate(key: key)
        pendingLibraryUpdates[key] = nil
        addedLibraries.removeAll { $0.key == key }
        if library.kind == .link { try? FileManager.default.removeItem(at: fetchedLibraryURL(key: key)) }
        Self.removeLibraryPorts(source: library.source)   // a port belongs to its library, and goes with it
        persistAppState()
        refreshLibraryItems()
        status = "Removed \(library.name)"
    }

    private func register(_ library: SZAddedLibrary) {
        addedLibraries.append(library)
        persistAppState()
        refreshLibraryItems()
        status = "Added \(library.name)"
    }

    // MARK: update

    /// What a newer copy would change, without changing anything here. Never called on a timer:
    /// checking is something a person asks for, so a library never shifts under an open project.
    ///
    /// The fetched copy is kept staged so applying it does not download again, which would be a
    /// second chance for the two to disagree.
    func libraryUpdate(key: String) async throws -> SZLibraryUpdate {
        guard let library = addedLibraries.first(where: { $0.key == key }) else {
            throw SZMCPError.message("no library \(key)")
        }
        guard library.kind == .link else {
            throw SZMCPError.message("\(library.name) is a folder on this Mac, so it is always up to date")
        }
        guard let link = SZLibraryLink.parse(library.origin) else {
            throw SZMCPError.message("Couldn't read where \(library.name) came from")
        }
        let installed = library.manifest?.version
        guard let copy = try await Self.fetchLibrary(from: link, knownETag: library.etag) else {
            return SZLibraryUpdate(version: installed, note: upToDate(installed), offered: false)
        }
        discardStagedUpdate(key: key)

        let fetched = Self.libraryManifest(at: copy.folder)?.version
        let (added, changed, removed) = Self.libraryDifference(staged: copy.folder,
                                                               live: addedLibraryURL(library))
        let files = SZLibraryUpdate(version: fetched, note: "", staged: copy.staging.path, offered: false,
                                    added: added, changed: changed, removed: removed)

        // The author's number is the signal when there is one: equal versions mean up to date even
        // when bytes differ, and a version that went backwards is not an update. Without a readable
        // version on both sides, the file comparison is the honest answer.
        var note: String
        var offered: Bool
        if let fetched, let installed, SZLibraryVersion.parse(fetched) != nil, SZLibraryVersion.parse(installed) != nil {
            if SZLibraryVersion.isNewer(fetched, than: installed) {
                note = "Version \(fetched) is available. You have \(installed). \(files.summary)"
                offered = true
            } else if fetched == installed {
                note = "Up to date at \(installed)."
                offered = false
            } else {
                note = "That library now offers \(fetched), which is older than the \(installed) you have."
                offered = false
            }
        } else {
            offered = !files.isEmpty
            note = offered ? files.summary : "Up to date"
        }
        if !offered { try? FileManager.default.removeItem(at: copy.staging) }
        return SZLibraryUpdate(version: fetched, note: note,
                               staged: offered ? copy.staging.path : "", offered: offered,
                               added: added, changed: changed, removed: removed)
    }

    private func upToDate(_ installed: String?) -> String {
        installed.map { "Up to date at \($0)." } ?? "Up to date"
    }

    /// Replace a library with the copy the check downloaded. Nodes already placed are copies of their
    /// own, so a project only changes when someone places from the library again.
    func applyLibraryUpdate(key: String, to update: SZLibraryUpdate) async throws {
        guard let index = addedLibraries.firstIndex(where: { $0.key == key }) else {
            throw SZMCPError.message("no library \(key)")
        }
        let fm = FileManager.default
        let staging = URL(filePath: update.staged)
        let fresh = staging.appending(path: "unpacked")
        guard !update.staged.isEmpty, fm.fileExists(atPath: fresh.path) else {
            throw SZMCPError.message("Check for updates first")
        }
        let folder = addedLibraryURL(addedLibraries[index])
        defer { try? fm.removeItem(at: staging) }
        do {
            // One rename on one volume: either the new copy is there or the old one still is.
            if fm.fileExists(atPath: folder.path) {
                _ = try fm.replaceItemAt(folder, withItemAt: fresh)
            } else {
                try fm.moveItem(at: fresh, to: folder)
            }
        } catch {
            throw SZMCPError.message("Couldn't update \(addedLibraries[index].name).")
        }
        addedLibraries[index].etag = nil
        if let manifest = Self.libraryManifest(at: folder) {
            addedLibraries[index].name = manifest.name
            addedLibraries[index].manifest = manifest
        }
        persistAppState()
        refreshLibraryItems()
        status = "Updated \(addedLibraries[index].name): \(update.summary)"
    }

    /// Throw away a staged copy a check left behind, on every path that abandons one.
    func discardStagedUpdate(key: String) {
        guard let staged = pendingLibraryUpdates[key]?.staged, !staged.isEmpty else { return }
        try? FileManager.default.removeItem(at: URL(filePath: staged))
    }
}
