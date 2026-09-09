// SPDX-License-Identifier: AGPL-3.0-only
// Libraries beyond the two the app ships with: adding one from a folder or a link, moving it to a
// newer revision, forgetting it, and publishing your own. A library is a repository of node folders,
// so add is a clone, update is a fetch and a checkout, and publish is a push. None of that vocabulary
// reaches the UI, and nothing here ever runs on its own: every fetch is something a person asked for.
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

    // MARK: reading a library's own manifest

    /// A library's `library.json`. Missing or unreadable is not fatal: a plain folder of node folders
    /// is still a library, it just has no name of its own.
    nonisolated static func libraryManifest(at root: URL) -> SZLibraryManifest? {
        guard let data = try? Data(contentsOf: root.appending(path: "library.json")) else { return nil }
        return try? JSONDecoder().decode(SZLibraryManifest.self, from: data)
    }

    /// What makes a folder a library: at least one node folder in it. Checked before anything is
    /// remembered, so a mistyped path fails at the point the person can still fix it.
    nonisolated static func isLibraryFolder(_ root: URL) -> Bool {
        !libraryCatalog(root: root).isEmpty
    }

    // MARK: add

    /// Add a folder on this Mac. Read where it is and never written to, so a library kept in someone's
    /// own repository stays theirs to manage.
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
        let name = Self.libraryManifest(at: url)?.name ?? url.lastPathComponent
        let library = SZAddedLibrary(key: SZLibraryKey.make(from: name, taken: takenLibraryKeys),
                                     name: name, kind: .folder, origin: url.path)
        register(library)
        return library
    }

    /// Add a library from a link: clone it, pin it to the commit it arrived on, and check it actually
    /// holds nodes before remembering it. A failed add leaves nothing behind.
    @discardableResult
    func addLibraryLink(_ text: String) async throws -> SZAddedLibrary {
        guard let link = SZLibraryLink.parse(text) else {
            throw SZMCPError.message("That does not look like a library link. Use a link like https://github.com/someone/their-nodes")
        }
        if let existing = addedLibraries.first(where: { $0.kind == .link && $0.origin == link.url }) {
            throw SZMCPError.message("\(existing.name) is already in your libraries")
        }
        let key = SZLibraryKey.make(from: link.shortName.replacingOccurrences(of: "/", with: "-"),
                                    taken: takenLibraryKeys)
        let folder = fetchedLibraryURL(key: key)
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: Self.fetchedLibrariesURL, withIntermediateDirectories: true)

        let clone = await Self.run(["clone", "--depth", "1", link.url, folder.path],
                                   in: Self.fetchedLibrariesURL)
        guard clone.ok else {
            try? fm.removeItem(at: folder)
            throw SZMCPError.message(Self.reachFailure(clone.output))
        }
        guard Self.isLibraryFolder(folder) else {
            try? fm.removeItem(at: folder)
            throw SZMCPError.message("There are no nodes in that library")
        }
        let name = Self.libraryManifest(at: folder)?.name ?? link.shortName
        let head = await Self.revision(in: folder)
        let library = SZAddedLibrary(key: key, name: name, kind: .link, origin: link.url,
                                     revision: head?.sha, revisionNote: head?.note)
        register(library)
        return library
    }

    /// Forget a library. Nodes already on a canvas are copies, so nothing in any project changes; a
    /// library that was fetched has its folder deleted, one that lives in a folder is left alone.
    func removeLibrary(key: String) {
        guard let library = addedLibraries.first(where: { $0.key == key }) else { return }
        addedLibraries.removeAll { $0.key == key }
        if library.kind == .link { try? FileManager.default.removeItem(at: fetchedLibraryURL(key: key)) }
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

    /// What a library would move to, without moving it. Never called on a timer: checking is something
    /// a person asks for, so a library never changes under a project that is open.
    func libraryUpdate(key: String) async throws -> SZLibraryUpdate {
        guard let library = addedLibraries.first(where: { $0.key == key }) else {
            throw SZMCPError.message("no library \(key)")
        }
        guard library.kind == .link else {
            throw SZMCPError.message("\(library.name) is a folder on this Mac, so it is always up to date")
        }
        let folder = addedLibraryURL(library)
        let fetch = await Self.run(["fetch", "--depth", "1", "origin", "HEAD"], in: folder)
        guard fetch.ok else { throw SZMCPError.message(Self.reachFailure(fetch.output)) }

        let head = await Self.run(["rev-parse", "FETCH_HEAD"], in: folder)
        let target = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.ok, !target.isEmpty else { throw SZMCPError.message("Couldn't read what \(library.name) has now") }
        let note = await Self.run(["log", "-1", "--format=%h %s", "FETCH_HEAD"], in: folder)

        // Node folders that appeared, changed or went away between the two commits.
        let names = await Self.run(["diff", "--name-status", "HEAD", "FETCH_HEAD"], in: folder)
        var added: Set<String> = [], changed: Set<String> = [], removed: Set<String> = []
        for line in names.output.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count >= 2, let node = parts[1].split(separator: "/").first.map(String.init),
                  node != "library.json", node != "index.json" else { continue }
            switch parts[0].first {
            case "A": added.insert(node)
            case "D": removed.insert(node)
            default: changed.insert(node)
            }
        }
        // A folder with both an added and a deleted file has changed, not appeared and vanished.
        let both = added.intersection(removed)
        changed.formUnion(both)
        added.subtract(both)
        removed.subtract(both)
        changed.subtract(added)
        return SZLibraryUpdate(revision: target,
                               note: note.output.trimmingCharacters(in: .whitespacesAndNewlines),
                               added: added.sorted(), changed: changed.sorted(), removed: removed.sorted())
    }

    /// Move a library onto the revision `libraryUpdate` found. Nodes already placed are copies and
    /// are not touched: a project only changes when someone places from the library again.
    func applyLibraryUpdate(key: String, to update: SZLibraryUpdate) async throws {
        guard let index = addedLibraries.firstIndex(where: { $0.key == key }) else {
            throw SZMCPError.message("no library \(key)")
        }
        let folder = addedLibraryURL(addedLibraries[index])
        let checkout = await Self.run(["checkout", "--detach", update.revision], in: folder)
        guard checkout.ok else { throw SZMCPError.message("Couldn't update \(addedLibraries[index].name)") }
        addedLibraries[index].revision = update.revision
        addedLibraries[index].revisionNote = update.note
        if let manifest = Self.libraryManifest(at: folder) { addedLibraries[index].name = manifest.name }
        persistAppState()
        refreshLibraryItems()
        status = "Updated \(addedLibraries[index].name): \(update.summary)"
    }

    // MARK: publish

    /// Send your library where its remote points. Nothing is published unless the person set a remote
    /// up themselves, because that is the only place we could know to send it.
    @discardableResult
    func publishMyLibrary() async throws -> String {
        let folder = try ensureMyLibrary()
        let remote = await Self.run(["remote", "get-url", "origin"], in: folder)
        guard remote.ok, !remote.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SZMCPError.message("My Library has nowhere to publish to yet. Put it on a host like GitHub and set that as its remote, then this sends your changes there.")
        }
        let branch = await Self.run(["rev-parse", "--abbrev-ref", "HEAD"], in: folder)
        let name = branch.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let push = await Self.run(["push", "origin", name.isEmpty ? "HEAD" : name], in: folder)
        guard push.ok else { throw SZMCPError.message(Self.reachFailure(push.output)) }
        let where_ = remote.output.trimmingCharacters(in: .whitespacesAndNewlines)
        status = "Published My Library"
        return where_
    }

    /// Whether My Library has somewhere to publish to; the settings row shows Publish only then.
    func myLibraryHasRemote() async -> Bool {
        let folder = myLibraryURL
        guard FileManager.default.fileExists(atPath: folder.appending(path: ".git").path) else { return false }
        let remote = await Self.run(["remote", "get-url", "origin"], in: folder)
        return remote.ok && !remote.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: running the command

    struct SZGitResult: Sendable {
        var ok: Bool
        var output: String
    }

    /// Run one command off the main thread and hand back what it said. The fire-and-forget `git` in
    /// SZHost+LibrarySave stays for saving, where the answer never mattered.
    nonisolated static func run(_ arguments: [String], in directory: URL) async -> SZGitResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xcrun")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = directory
            // Never let a fetch stop on a credential or host-key question: there is no terminal here,
            // and a prompt nobody can answer would hang the call forever.
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_ASKPASS"] = "/usr/bin/true"
            environment["SSH_ASKPASS"] = "/usr/bin/true"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                if process.terminationStatus != 0 {
                    print("[SZHost] library command failed (\(process.terminationStatus)): \(text)")
                }
                return SZGitResult(ok: process.terminationStatus == 0, output: text)
            } catch {
                print("[SZHost] library command could not run: \(error)")
                return SZGitResult(ok: false, output: "\(error)")
            }
        }.value
    }

    /// The commit a fetched library sits on, for the settings row.
    nonisolated static func revision(in folder: URL) async -> (sha: String, note: String)? {
        let sha = await run(["rev-parse", "HEAD"], in: folder)
        guard sha.ok else { return nil }
        let note = await run(["log", "-1", "--format=%h %s"], in: folder)
        return (sha.output.trimmingCharacters(in: .whitespacesAndNewlines),
                note.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Turn a failed fetch into a sentence a person can act on. Offline is the common case and says
    /// so plainly; anything else keeps the tool's own last line, which usually names the real problem.
    nonisolated static func reachFailure(_ output: String) -> String {
        let text = output.lowercased()
        if text.contains("could not resolve host") || text.contains("network is unreachable")
            || text.contains("timed out") || text.contains("no route to host") {
            return "Couldn't reach the internet. Your libraries still work as they are."
        }
        if text.contains("not found") || text.contains("repository does not exist") {
            return "There is nothing at that link, or it is private."
        }
        if text.contains("authentication") || text.contains("permission denied") || text.contains("terminal prompts disabled") {
            return "That library is private, so it can't be read from here."
        }
        let lines = output.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.last.map { "Couldn't do that: \($0)" } ?? "Couldn't do that."
    }
}
