// SPDX-License-Identifier: AGPL-3.0-only
// Adding a library beyond the two the app ships with: what counts as one, what a folder library
// contributes to the panel and the agents' index, and what forgetting one does. The link case is not
// exercised here (it would need the network); its parsing is covered in SZAddedLibraryTests.
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostLibrarySourcesTests {

    private static func scratchDirectory() throws -> URL { try SZLibraryTestSupport.scratchDirectory() }

    private static func host(in dir: URL, target: SZProjectTarget = .native) throws -> SZHost {
        let url = dir.appending(path: "Patch.subz")
        try SZProjectIO.save(SZProject(name: "Patch", target: target), to: url)
        let host = SZLibraryTestSupport.withoutAddedLibraries(SZHost())
        host.store.setProject(try SZProjectIO.load(from: url))
        host.loadedProjectURL = url
        host.refreshLibraryItems()
        return host
    }

    /// A folder holding one node, copied out of the built-in library so it is a real one.
    private static func libraryFolder(in dir: URL, named name: String, entry: String = "gaussian-blur",
                                      manifest: Bool = true) throws -> URL {
        let root = dir.appending(path: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: SZHost.builtInLibraryURL.appending(path: entry),
                                         to: root.appending(path: entry))
        if manifest {
            try JSONSerialization.data(withJSONObject: ["name": "Their Nodes"], options: [])
                .write(to: root.appending(path: "library.json"))
        }
        return root
    }

    // MARK: - adding a folder

    @Test func aFolderOfNodesBecomesALibraryTheWholeAppCanSee() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir)
        let before = host.libraryItems.count

        let folder = try Self.libraryFolder(in: dir, named: "their-nodes")
        let added = try host.addLibraryFolder(at: folder)

        // It names itself from its own library.json, and its key is not one of the built-in ones.
        #expect(added.name == "Their Nodes")
        #expect(added.kind == .folder)
        #expect(added.key != SZLibrarySourceID.builtIn.rawValue && added.key != SZLibrarySourceID.mine.rawValue)
        #expect(host.addedLibraryCount(added.key) == 1)

        // Its node reaches the panel as its own row, beside the built-in one of the same id.
        #expect(host.libraryItems.count == before + 1)
        let mine = try #require(host.libraryItems.first { $0.source == added.source })
        #expect(mine.entryID == "gaussian-blur")
        #expect(mine.sourceName == "Their Nodes")           // the row says the library's name, never its key

        // And the agents read the same list, with the library named on the line.
        let index = try #require(host.libraryCategoriesBlock(target: .native, query: "gaussian-blur"))
        #expect(index.contains("library: Their Nodes"))
    }

    @Test func aFolderWithNoNodesIsNotALibrary() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir)

        let empty = dir.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try host.addLibraryFolder(at: empty) }
        #expect(throws: (any Error).self) { try host.addLibraryFolder(at: dir.appending(path: "nope")) }
        #expect(host.addedLibraries.isEmpty)
    }

    @Test func theSameFolderIsNotAddedTwice() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir)
        let folder = try Self.libraryFolder(in: dir, named: "their-nodes")

        try host.addLibraryFolder(at: folder)
        #expect(throws: (any Error).self) { try host.addLibraryFolder(at: folder) }
        #expect(host.addedLibraries.count == 1)
    }

    @Test func aLibraryWithoutAManifestIsNamedAfterItsFolder() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir)
        let folder = try Self.libraryFolder(in: dir, named: "bare-nodes", manifest: false)
        #expect(try host.addLibraryFolder(at: folder).name == "bare-nodes")
    }

    // MARK: - a library that is not there

    @Test func aLibraryWhoseFolderIsGoneIsSkippedNotDropped() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir)
        let folder = try Self.libraryFolder(in: dir, named: "their-nodes")
        let added = try host.addLibraryFolder(at: folder)

        try FileManager.default.removeItem(at: folder)
        host.refreshLibraryItems()

        // Still remembered, so it comes back when the folder does; just not offering rows meanwhile.
        #expect(host.addedLibraries.contains { $0.key == added.key })
        #expect(host.missingLibraryKeys.contains(added.key))
        #expect(!host.libraryItems.contains { $0.source == added.source })
    }

    // MARK: - forgetting one

    @Test func removingALibraryLeavesTheFolderAndThePlacedNodesAlone() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir)
        let folder = try Self.libraryFolder(in: dir, named: "their-nodes")
        let added = try host.addLibraryFolder(at: folder)

        let placed = try host.placeLibraryItem(.library(source: added.source, id: "gaussian-blur"),
                                               position: SZPoint(x: 0, y: 0))
        host.removeLibrary(key: added.key)

        #expect(host.addedLibraries.isEmpty)
        #expect(!host.libraryItems.contains { $0.source == added.source })
        // A folder library is read where it lives, so forgetting it must not delete the user's folder.
        #expect(FileManager.default.fileExists(atPath: folder.path))
        // The placed node is a copy: it stays, with its own source on disk.
        #expect(host.store.project?.graph.node(id: placed) != nil)
        #expect(!host.status.isEmpty && !SZLibraryTestSupport.containsUUIDPrefix(host.status))
    }

    // MARK: - updating

    @Test func aFolderLibraryHasNothingToUpdateFrom() async throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir)
        let added = try host.addLibraryFolder(at: try Self.libraryFolder(in: dir, named: "their-nodes"))

        // A folder on this Mac is whatever it is right now; saying "up to date" would be a lie.
        await #expect(throws: (any Error).self) { try await host.libraryUpdate(key: added.key) }
        #expect(await host.checkForLibraryUpdate(key: added.key).contains("folder on this Mac"))
    }

    // MARK: - what a failure says

    @Test func aFetchFailureIsASentenceNotACommandLog() {
        #expect(SZHost.reachFailure("fatal: could not resolve host: github.com")
                == "Couldn't reach the internet. Your libraries still work as they are.")
        #expect(SZHost.reachFailure("remote: Repository not found.").contains("nothing at that link"))
        #expect(SZHost.reachFailure("fatal: Authentication failed").contains("private"))
        // Anything unrecognised keeps the tool's last line, which usually names the real problem.
        #expect(SZHost.reachFailure("fatal: something odd").contains("something odd"))
        #expect(SZHost.reachFailure("") == "Couldn't do that.")
    }
}
