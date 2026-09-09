// SPDX-License-Identifier: AGPL-3.0-only
// The host side of the Library panel: which nodes a project is offered, what a placement copies and
// records, how copies read each other (lineage), and apply-to-copies. No runtime under the test runner,
// so the compile step is a no-op and the file system plus the store carry the evidence.
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostLibraryTests {

    private static func scratchDirectory() throws -> URL { try SZLibraryTestSupport.scratchDirectory() }
    private static func node(_ host: SZHost, _ id: SZNodeID) throws -> SZNode { try SZLibraryTestSupport.node(host, id) }
    private static func isHex64(_ s: String?) -> Bool { SZLibraryTestSupport.isHex64(s) }
    private static func containsUUIDPrefix(_ s: String) -> Bool { SZLibraryTestSupport.containsUUIDPrefix(s) }

    /// A host over an empty project of the given platform, its library rows refreshed.
    private static func host(in dir: URL, target: SZProjectTarget = .native) throws -> SZHost {
        let url = dir.appending(path: "Patch.subz")
        try SZProjectIO.save(SZProject(name: "Patch", target: target), to: url)
        let host = SZLibraryTestSupport.withoutAddedLibraries(SZHost())
        host.store.setProject(try SZProjectIO.load(from: url))
        host.loadedProjectURL = url
        host.refreshLibraryItems()
        return host
    }

    private static func sourceURL(_ host: SZHost, _ id: SZNodeID) throws -> URL {
        SZProjectIO.nodeSourceURL(projectURL: try #require(host.loadedProjectURL), nodeID: id, target: .native)
    }

    /// Built-in folders with a source for `target` but none for the other platform.
    private static func builtInCount(onlyFor target: SZProjectTarget) -> Int {
        let fm = FileManager.default
        let other: SZProjectTarget = target == .native ? .web : .native
        let folders = (try? fm.contentsOfDirectory(at: SZHost.builtInLibraryURL, includingPropertiesForKeys: nil)) ?? []
        return folders.filter {
            fm.fileExists(atPath: $0.appending(path: target.sourceFileName).path)
                && !fm.fileExists(atPath: $0.appending(path: other.sourceFileName).path)
        }.count
    }

    // MARK: - what a project is offered

    @Test func rowsFollowTheProjectPlatform() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let native = try Self.host(in: dir)
        let ids = native.libraryItems.map(\.id)
        #expect(ids.contains("builtin/gaussian-blur"))
        #expect(!ids.contains("builtin/camera.web"))
        #expect(native.libraryItems.allSatisfy { $0.source == .builtIn })
        // Exactly the Mac-only nodes are left out of a browser project, and vice versa: the rows are
        // the set of folders holding a source file for this project's platform, nothing else.
        let web = try Self.host(in: dir.appending(path: "web"), target: .web)
        #expect(!web.libraryItems.map(\.id).contains("builtin/corner-pin"))
        #expect(web.libraryItems.map(\.id).contains("builtin/camera.web"))
        #expect(native.libraryItems.count - web.libraryItems.count
                == Self.builtInCount(onlyFor: .native) - Self.builtInCount(onlyFor: .web))
    }

    @Test func aFolderUnderMyLibraryPathIsASecondSource() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mine = dir.appending(path: "mine")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: SZHost.builtInLibraryURL.appending(path: "gaussian-blur"),
                                         to: mine.appending(path: "gaussian-blur"))
        let host = try Self.host(in: dir)
        #expect(host.libraryRoots.count == 1)   // no folder at the path yet counts as no library
        host.myLibraryPath = mine.path
        host.refreshLibraryItems()

        let item = try #require(host.libraryItems.first { $0.id == "mine/gaussian-blur" })
        #expect(item.source == .mine)
        #expect(item.source.displayName == "My Library")
        #expect(host.libraryItems.filter { $0.entryID == "gaussian-blur" }.count == 2)
        // an id alone resolves built in first; the library picks the other
        #expect(host.libraryFolder(id: "gaussian-blur", library: nil)?.source == .builtIn)
        #expect(host.libraryFolder(id: "gaussian-blur", library: .mine)?.folder.path == mine.appending(path: "gaussian-blur").path)
        #expect(host.libraryFolder(.library(source: .mine, id: "../gaussian-blur")) == nil)

        // the agents' block names the second library on its line and filters by query
        let block = try #require(host.libraryCategoriesBlock(target: .native, query: "gaussian"))
        #expect(block.contains("library: My Library"))
        #expect(block.hasPrefix("effects:"))
        #expect(!block.contains("checkerboard"))
        #expect(host.libraryCategoriesBlock(target: .native, query: "gaussian nothing-matches-this") == nil)
    }

    @Test func theBriefInlinesTheBlockUntilTheLibraryIsLarge() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir)
        #expect(try #require(host.libraryBriefBlock(target: .native)).contains("gaussian-blur —"))

        // enough tiny nodes to pass the limit: the brief carries counts and the search pointer instead
        let mine = dir.appending(path: "mine")
        let template = SZHost.builtInLibraryURL.appending(path: "gamma")
        for i in 0..<SZHost.libraryInlineLimit {
            try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: template, to: mine.appending(path: "gamma-\(i)"))
        }
        host.myLibraryPath = mine.path
        host.refreshLibraryItems()
        let brief = try #require(host.libraryBriefBlock(target: .native))
        #expect(!brief.contains("gaussian-blur —"))
        #expect(brief.contains("agent_library_index"))
        #expect(brief.contains("My Library"))
    }

    // MARK: - placement

    @Test func placingALibraryNodeCopiesItsSourceAndRecordsWhereItCameFrom() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir)
        #expect(host.defaultProviderID == nil)   // no provider anywhere near this path

        let id = try host.placeLibraryItem(.library(source: .builtIn, id: "gaussian-blur"), position: SZPoint(x: 100, y: 50))
        let node = try Self.node(host, id)
        #expect(node.kind == .generated)
        #expect(node.position == SZPoint(x: 100, y: 50))
        #expect(node.title == "Gaussian Blur")
        #expect(node.libraryID == "gaussian-blur")
        #expect(node.librarySource == nil)
        #expect(node.copiedFrom == nil)
        #expect(Self.isHex64(node.copiedHash))
        let shipped = SZHost.builtInLibraryURL.appending(path: "gaussian-blur/Node.swift")
        #expect(FileManager.default.contentsEqual(atPath: shipped.path, andPath: try Self.sourceURL(host, id).path))
        #expect(host.status == "Added Gaussian Blur")
        #expect(!Self.containsUUIDPrefix(host.status))
        #expect(host.nodeAgentState[id] == nil)   // the Reloading pill is gone once the compile returns
        // origin on the agent surface
        let lineage = try #require(host.lineage(of: id))
        #expect(lineage.origin == .library(.library(source: .builtIn, id: "gaussian-blur")))
        #expect(lineage.changed == false)
        #expect(lineage.copies.isEmpty)
    }

    @Test func anUnknownOrTraversingIdIsRefused() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir)
        #expect(throws: (any Error).self) {
            try host.placeLibraryItem(.library(source: .builtIn, id: "../gaussian-blur"), position: SZPoint(x: 0, y: 0))
        }
        #expect(throws: (any Error).self) {
            try host.placeLibraryItem(.library(source: .builtIn, id: "no-such-node"), position: SZPoint(x: 0, y: 0))
        }
        #expect(host.store.project?.graph.nodes.isEmpty == true)
    }

    @Test func aDuplicateIsACopyOfItsOriginalAndBothReadEachOther() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir)
        let a = try host.placeLibraryItem(.library(source: .builtIn, id: "gaussian-blur"), position: SZPoint(x: 0, y: 0))
        let b = try host.placeLibraryItem(.projectNode(a), position: SZPoint(x: 240, y: 0))

        let copy = try Self.node(host, b)
        #expect(copy.copiedFrom == a)
        #expect(copy.libraryID == "gaussian-blur")   // inherited: a duplicate of a library node is one too
        #expect(copy.copiedHash == (try Self.node(host, a)).copiedHash)
        #expect(FileManager.default.contentsEqual(atPath: try Self.sourceURL(host, a).path,
                                                  andPath: try Self.sourceURL(host, b).path))
        #expect(host.status == "Added Gaussian Blur")
        #expect(!Self.containsUUIDPrefix(host.status))

        let ofA = try #require(host.lineage(of: a))
        #expect(ofA.copies == [SZNodeLineage.Copy(id: b, title: "Gaussian Blur", inSync: true)])
        let ofB = try #require(host.lineage(of: b))
        #expect(ofB.copies == [SZNodeLineage.Copy(id: a, title: "Gaussian Blur", inSync: true)])
        #expect(ofB.changed == false)

        // an edit on disk flips the copy to changed, and out of sync from its sibling's side
        try Data("// edited\n".utf8).write(to: try Self.sourceURL(host, b))
        #expect(try #require(host.lineage(of: b)).changed)
        #expect(try #require(host.lineage(of: a)).copies.first?.inSync == false)
        #expect(try #require(host.lineage(of: a)).changed == false)
    }

    @Test func aDuplicateOfAPlainNodeRootsTheFamilyAtTheOriginal() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir)
        let projectURL = try #require(host.loadedProjectURL)
        // a hand-built node: no library, no hash
        let root = SZNodeID()
        let contract = SZNodeContract(title: "Tint", sfSymbol: "paintpalette", summary: "",
                                      inputs: [SZPort(name: "input", type: .texture)],
                                      outputs: [SZPort(name: "output", type: .texture)])
        var node = SZNode(id: root, kind: .generated, title: "Tint", contract: contract, position: SZPoint(x: 0, y: 0),
                          buildStamp: .trusting(contract: contract, prompt: nil))
        node.builtTargets = [.native]
        host.store.mutate { $0.graph.nodes.append(node) }
        let src = SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: root, target: .native)
        try FileManager.default.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// tint\n".utf8).write(to: src)
        #expect(host.lineage(of: root) == nil)   // from nowhere, nothing copied: nothing to say

        let copy = try host.placeLibraryItem(.projectNode(root), position: SZPoint(x: 240, y: 0))
        #expect(host.store.project?.graph.lineageFamily(of: copy) == root.uuidString)
        #expect(try Self.node(host, root).copiedHash != nil)   // the original now compares against its copy
        let ofCopy = try #require(host.lineage(of: copy))
        #expect(ofCopy.origin == .node(root, title: "Tint"))
        #expect(ofCopy.copies == [SZNodeLineage.Copy(id: root, title: "Tint", inSync: true)])
    }

    // MARK: - apply to copies

    @Test func applyingUpdatesInSyncCopiesKeepsTheirValuesAndSkipsChangedOnes() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir)
        let a = try host.placeLibraryItem(.library(source: .builtIn, id: "gaussian-blur"), position: SZPoint(x: 0, y: 0))
        let b = try host.placeLibraryItem(.projectNode(a), position: SZPoint(x: 240, y: 0))
        let c = try host.placeLibraryItem(.projectNode(a), position: SZPoint(x: 480, y: 0))

        // c keeps its own radius; b went its own way; a is edited and applied
        host.store.mutate { project in
            guard let i = project.graph.nodes.firstIndex(where: { $0.id == c }),
                  let r = project.graph.nodes[i].contract?.inputs.firstIndex(where: { $0.name == "radius" }) else { return }
            project.graph.nodes[i].contract?.inputs[r].def = .float(7)
        }
        try Data("// b on its own\n".utf8).write(to: try Self.sourceURL(host, b))
        let edited = Data("// a, version two\n".utf8)
        try edited.write(to: try Self.sourceURL(host, a))

        let result = try host.applyNodeToCopies(source: a, to: nil, origin: .user)
        #expect(result.applied == [c])
        #expect(result.skipped.map(\.0) == [b])
        #expect(result.skipped.first?.1 == "changed on its own")
        #expect(try Data(contentsOf: try Self.sourceURL(host, c)) == edited)
        #expect(try Data(contentsOf: try Self.sourceURL(host, b)) == Data("// b on its own\n".utf8))
        let cNode = try Self.node(host, c)
        #expect(cNode.contract?.inputs.first { $0.name == "radius" }?.def == .float(7))
        #expect(cNode.copiedHash == SZHost.contentHash(edited))
        #expect(try Self.node(host, a).copiedHash == SZHost.contentHash(edited))
        #expect(try #require(host.lineage(of: a)).changed == false)
        #expect(host.status == "Applied Gaussian Blur to 1 copy, 1 changed on its own")
        #expect(!Self.containsUUIDPrefix(host.status))
        #expect(host.mutationJournal.entries.last?.kind == "applied node to copies")

        // named on purpose, the changed copy is updated too
        let forced = try host.applyNodeToCopies(source: a, to: [b], origin: .user)
        #expect(forced.applied == [b])
        #expect(try Data(contentsOf: try Self.sourceURL(host, b)) == edited)
    }

    @Test func applyingToAHeldCopyIsRefusedWhole() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir)
        let a = try host.placeLibraryItem(.library(source: .builtIn, id: "gaussian-blur"), position: SZPoint(x: 0, y: 0))
        let b = try host.placeLibraryItem(.projectNode(a), position: SZPoint(x: 240, y: 0))
        let c = try host.placeLibraryItem(.projectNode(a), position: SZPoint(x: 480, y: 0))
        // another request's build holds c: an agent's call is refused whole, b untouched too
        // (a user is not fenced off a node that renders, by the fence's own rule)
        #expect(host.ledger.tryAcquire([.node(c), .transcript(.node(c))], as: SZClaimToken(label: "chat turn")))
        let edited = Data("// a, version two\n".utf8)
        try edited.write(to: try Self.sourceURL(host, a))
        #expect(throws: (any Error).self) { try host.applyNodeToCopies(source: a, to: nil, origin: .agent) }
        #expect(try Data(contentsOf: try Self.sourceURL(host, b)) != edited)
        #expect(try Data(contentsOf: try Self.sourceURL(host, c)) != edited)
    }

    /// `library` is the node id; `source` picks the library and may be omitted. A wrong `source` is refused.
    @Test func theAddLibraryNodeToolTakesAnIdAndAnOptionalLibrary() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir)
        let bridge = SZHostBridge(host: host)
        guard case .text(let plain) = try bridge.callTool(name: "ui_add_library_node",
                                                          arguments: ["library": "gaussian-blur", "x": 10, "y": 20]),
              case .text(let picked) = try bridge.callTool(name: "ui_add_library_node",
                                                           arguments: ["library": "gaussian-blur", "source": "builtin"])
        else { Issue.record("no text reply"); return }
        #expect(plain.contains("\"library\":\"gaussian-blur\"") && plain.contains("\"origin\""))
        #expect(picked.contains("\"source\":\"builtin\""))
        #expect(host.store.project?.graph.nodes.count == 2)
        #expect(throws: (any Error).self) {
            try bridge.callTool(name: "ui_add_library_node", arguments: ["library": "gaussian-blur", "source": "nowhere"])
        }
    }
}
