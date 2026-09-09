// SPDX-License-Identifier: AGPL-3.0-only
// Saving a node into My Library: what the first save creates, what one entry holds, how names collide,
// how a node that came from the library updates its own entry, and how the project node reads afterwards.
// No runtime under the test runner; the file system, the index and the store carry the evidence.
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostLibrarySaveTests {

    private static func scratchDirectory() throws -> URL { try SZLibraryTestSupport.scratchDirectory() }
    private static func node(_ host: SZHost, _ id: SZNodeID) throws -> SZNode { try SZLibraryTestSupport.node(host, id) }
    private static func isHex64(_ s: String?) -> Bool { SZLibraryTestSupport.isHex64(s) }

    /// A built node: a contract with a slider and a file input, a prompt, and a Node.swift on disk.
    private static func builtNode(title: String, prompt: String? = "make it blurry") -> SZNode {
        SZNode(kind: .generated, title: title, sfSymbol: "drop", prompt: prompt,
               contract: SZNodeContract(title: title, sfSymbol: "drop", summary: "Softens the picture",
                                        inputs: [SZPort(name: "in", type: .texture),
                                                 SZPort(name: "radius", type: .float,
                                                        ui: SZPortUI(kind: .slider, min: 0, max: 20), def: .float(4)),
                                                 SZPort(name: "path", type: .string,
                                                        ui: SZPortUI(kind: .filePicker), def: .string("media/x/clip.mov"))],
                                        outputs: [SZPort(name: "out", type: .texture)]),
               position: SZPoint(x: 0, y: 0))
    }

    /// A host over a project holding `nodes`, each with a Node.swift, its library pointed into `dir`.
    private static func host(in dir: URL, nodes: [SZNode]) throws -> SZHost {
        let url = dir.appending(path: "Patch.subz")
        var project = SZProject(name: "Patch")
        project.graph.nodes = nodes
        try SZProjectIO.save(project, to: url)
        for node in nodes where node.kind == .generated {
            try Data("// \(node.title) source\n".utf8)
                .write(to: SZProjectIO.nodeSourceURL(projectURL: url, nodeID: node.id, target: .native))
        }
        let host = SZLibraryTestSupport.withDefaultLibraries(SZHost())
        host.store.setProject(try SZProjectIO.load(from: url))
        host.loadedProjectURL = url
        host.myLibraryPath = dir.appending(path: "library").path
        host.refreshLibraryItems()
        return host
    }

    private static func read(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }

    @Test func theRunnerKeepsTheDefaultLibraryOnATempHome() {
        #expect(SZAppSupport.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let host = SZHost()
        host.myLibraryPath = nil
        host.refreshLibraryItems()
        #expect(host.myLibraryURL.path.hasPrefix(SZAppSupport.directory.path))
        #expect(host.libraryNodeCount(.mine) == nil || host.libraryRoots.contains { $0.source == .mine })
        #expect((host.libraryNodeCount(.builtIn) ?? 0) > 20)
    }

    @Test func theFirstSaveCreatesTheLibraryAndOneEntry() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blur = Self.builtNode(title: "Soft Blur")
        let host = try Self.host(in: dir, nodes: [blur])
        #expect(host.libraryNodeCount(.mine) == nil)
        let before = host.saveToLibraryPreview(node: blur.id)
        #expect(before.name == "Soft Blur")
        #expect(before.line == "Softens the picture")
        #expect(before.updates == false)

        let ref = try host.saveNodeToLibrary(node: blur.id, name: "Soft Blur", line: "A gentle blur")
        #expect(ref == .library(source: .mine, id: "soft-blur"))
        let library = host.myLibraryURL
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: library.appending(path: "library.json").path))
        #expect(try Self.read(library.appending(path: "library.json")).contains("My Library"))
        // Nothing version-controlled is made: a save writes files, and what the user does with
        // them afterwards is theirs.
        #expect(!fm.fileExists(atPath: library.appending(path: ".git").path))

        let folder = library.appending(path: "soft-blur")
        let contract = try JSONDecoder().decode(SZNodeContract.self,
                                                from: Data(contentsOf: folder.appending(path: "node-contract.json")))
        #expect(contract.title == "Soft Blur")
        #expect(contract.summary == "A gentle blur")
        #expect(contract.inputs.first { $0.name == "path" }?.def == nil)      // a path into this project is cleared
        #expect(contract.inputs.first { $0.name == "radius" }?.def == .float(4))
        #expect(try Self.read(folder.appending(path: "Node.swift")) == "// Soft Blur source\n")
        #expect(!fm.fileExists(atPath: folder.appending(path: "Node.js").path))
        #expect(!fm.fileExists(atPath: folder.appending(path: "Card.swift").path))
        let card = try Self.read(folder.appending(path: "CARD.md"))
        #expect(card.hasPrefix("# Soft Blur\n\nA gentle blur\n"))
        #expect(card.contains("## Prompt\n\nmake it blurry"))

        let index = try JSONDecoder().decode(SZLibraryCurationFile.self,
                                             from: Data(contentsOf: library.appending(path: "index.json")))
        #expect(index.nodes.count == 1)
        #expect(index.nodes.first?.id == "soft-blur")
        #expect(index.nodes.first?.purpose == "A gentle blur")
        #expect(index.nodes.first?.tags == [])

        // the project node is now a copy of the entry
        let stamped = try Self.node(host, blur.id)
        #expect(stamped.libraryID == "soft-blur")
        #expect(stamped.librarySource == .mine)
        #expect(Self.isHex64(stamped.copiedHash))
        #expect(stamped.contract?.inputs.first { $0.name == "path" }?.def == .string("media/x/clip.mov"))   // untouched here
        #expect(host.status == "Saved Soft Blur to My Library")
        #expect(host.libraryNodeCount(.mine) == 1)
        #expect(host.mutationJournal.entries.last?.kind == "saved node to library")

        // the panel lists it under the library's name, and the lineage names the entry
        let item = try #require(host.libraryItems.first { $0.id == "mine/soft-blur" })
        #expect(item.source == .mine)
        #expect(item.title == "Soft Blur")
        #expect(item.summary == "A gentle blur")
        #expect(host.lineage(of: blur.id)?.origin == .library(.library(source: .mine, id: "soft-blur")))
        #expect(host.lineage(of: blur.id)?.changed == false)
    }

    @Test func aSecondNodeWithTheSameNameGetsASuffixAndTheSameNodeUpdatesInPlace() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Self.builtNode(title: "Blur")
        let b = Self.builtNode(title: "Blur", prompt: nil)
        let host = try Self.host(in: dir, nodes: [a, b])
        #expect(try host.saveNodeToLibrary(node: a.id, name: "Blur", line: "one") == .library(source: .mine, id: "blur"))
        #expect(try host.saveNodeToLibrary(node: b.id, name: "Blur", line: "two") == .library(source: .mine, id: "blur-2"))
        #expect(try Self.read(host.myLibraryURL.appending(path: "blur-2/CARD.md")).contains("## Prompt\n\n(none)"))

        // an edit on a, then a second save: the same entry, its source replaced, no blur-3
        let source = SZProjectIO.nodeSourceURL(projectURL: try #require(host.loadedProjectURL), nodeID: a.id, target: .native)
        try Data("// Blur source, sharper\n".utf8).write(to: source)
        let preview = host.saveToLibraryPreview(node: a.id)
        #expect(preview.updates == true)
        #expect(preview.changes == ["code changed"])
        #expect(host.lineage(of: a.id)?.changed == true)
        #expect(try host.saveNodeToLibrary(node: a.id, name: "Blur Again", line: "three") == .library(source: .mine, id: "blur"))
        #expect(try Self.read(host.myLibraryURL.appending(path: "blur/Node.swift")) == "// Blur source, sharper\n")
        #expect(!FileManager.default.fileExists(atPath: host.myLibraryURL.appending(path: "blur-3").path))
        #expect(host.saveToLibraryPreview(node: a.id).changes.isEmpty)
        #expect(host.lineage(of: a.id)?.changed == false)

        let index = try JSONDecoder().decode(SZLibraryCurationFile.self,
                                             from: Data(contentsOf: host.myLibraryURL.appending(path: "index.json")))
        #expect(index.nodes.map(\.id) == ["blur", "blur-2"])
        #expect(index.nodes.first?.purpose == "three")
        #expect(host.libraryItems.filter { $0.source == .mine }.map(\.title) == ["Blur Again", "Blur"])
    }

    @Test func aHeldOrUnbuiltNodeIsRefused() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let built = Self.builtNode(title: "Blur")
        var unbuilt = Self.builtNode(title: "Draft")
        unbuilt.kind = .prompt
        unbuilt.contract = nil
        let host = try Self.host(in: dir, nodes: [built, unbuilt])
        #expect(throws: (any Error).self) { try host.saveNodeToLibrary(node: unbuilt.id, name: "Draft", line: "") }
        host.graphOpStatus[built.id] = "Split"
        #expect(throws: (any Error).self) { try host.saveNodeToLibrary(node: built.id, name: "Blur", line: "") }
        #expect(!FileManager.default.fileExists(atPath: host.myLibraryURL.path))   // nothing was created
        host.graphOpStatus[built.id] = nil
        #expect(throws: (any Error).self) { try host.saveNodeToLibrary(node: built.id, name: "   ", line: "") }
    }

    @Test func movingTheLibraryRelocatesTheFolderAndRemembersThePath() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blur = Self.builtNode(title: "Blur")
        let host = try Self.host(in: dir, nodes: [blur])
        try host.saveNodeToLibrary(node: blur.id, name: "Blur", line: "")
        let destination = dir.appending(path: "elsewhere/My Library")
        try host.moveMyLibrary(to: destination)
        #expect(host.myLibraryURL.path == destination.path)
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "blur/Node.swift").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "library").path))
        #expect(host.libraryItems.contains { $0.id == "mine/blur" })
        #expect(SZAppStateIO.load()?.myLibraryPath == destination.path)
        // a folder with something in it is not taken over
        let busy = dir.appending(path: "busy")
        try FileManager.default.createDirectory(at: busy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: busy.appending(path: "keep.txt"))
        #expect(throws: (any Error).self) { try host.moveMyLibrary(to: busy) }
        #expect(host.myLibraryURL.path == destination.path)
    }
}
