// SPDX-License-Identifier: AGPL-3.0-only
// The ports overlay: a platform's source written after the fact lives beside its library rather than
// inside it, so it survives the library's next update and the app's, and it goes when the library
// goes. A node's platforms are its own files plus whatever is in the overlay, read in one place.
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostLibraryPortsTests {

    private static func scratchDirectory() throws -> URL { try SZLibraryTestSupport.scratchDirectory() }

    /// A library holding one node copied out of the built-in one, so it is a real node folder.
    private static func library(in dir: URL, named name: String, entry: String) throws -> URL {
        let root = dir.appending(path: name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: SZHost.builtInLibraryURL.appending(path: entry),
                                         to: root.appending(path: entry))
        return root
    }

    private static func host(in dir: URL, target: SZProjectTarget) throws -> SZHost {
        let url = dir.appending(path: "Patch.subz")
        try SZProjectIO.save(SZProject(name: "Patch", target: target), to: url)
        let host = SZLibraryTestSupport.withDefaultLibraries(SZHost())
        host.store.setProject(try SZProjectIO.load(from: url))
        host.loadedProjectURL = url
        host.refreshLibraryItems()
        return host
    }

    @Test func aPortMakesANodeRunSomewhereItsLibraryNeverDid() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // corner-pin ships Node.swift and no Node.js: portable, unported.
        let root = try Self.library(in: dir, named: "theirs", entry: "corner-pin")
        let host = try Self.host(in: dir, target: .web)
        let added = try host.addLibraryFolder(at: root)
        defer { SZHost.removeLibraryPorts(source: added.source) }

        let before = try #require(host.libraryItems.first { $0.entryID == "corner-pin" && $0.source == added.source })
        #expect(before.portability == .portable)

        try SZHost.writeLibraryPort(source: added.source, id: "corner-pin", target: .web,
                                    contents: "export default class Node { setup(){} update(){} }\n")
        host.refreshLibraryItems()
        let after = try #require(host.libraryItems.first { $0.entryID == "corner-pin" && $0.source == added.source })
        #expect(after.portability == .runs, "a port is a source file like any other")
        // And placement copies it, so the node really is placeable now.
        #expect(SZHost.librarySourceURL(folder: root.appending(path: "corner-pin"), source: added.source,
                                        id: "corner-pin", target: .web) != nil)
    }

    @Test func theLibrarysOwnFileWinsOverAPort() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // gaussian-blur ships both, so its own Node.js is what a placement must copy.
        let root = try Self.library(in: dir, named: "theirs", entry: "gaussian-blur")
        let host = try Self.host(in: dir, target: .web)
        let added = try host.addLibraryFolder(at: root)
        defer { SZHost.removeLibraryPorts(source: added.source) }

        try SZHost.writeLibraryPort(source: added.source, id: "gaussian-blur", target: .web,
                                    contents: "// a stale port nobody should get\n")
        let folder = root.appending(path: "gaussian-blur")
        let resolved = try #require(SZHost.librarySourceURL(folder: folder, source: added.source,
                                                           id: "gaussian-blur", target: .web))
        #expect(resolved == folder.appending(path: "Node.js"))
    }

    @Test func forgettingALibraryForgetsItsPorts() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = try Self.library(in: dir, named: "theirs", entry: "corner-pin")
        let host = try Self.host(in: dir, target: .web)
        let added = try host.addLibraryFolder(at: root)
        try SZHost.writeLibraryPort(source: added.source, id: "corner-pin", target: .web, contents: "x\n")
        #expect(FileManager.default.fileExists(atPath: SZHost.libraryPortsURL(source: added.source).path))

        host.removeLibrary(key: added.key)
        #expect(!FileManager.default.fileExists(atPath: SZHost.libraryPortsURL(source: added.source).path),
                "a port belongs to its library, and goes with it")
    }

    @Test func placingAnUnportedNodeBringsInTheSourceThereIsAndAsksForTheOther() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir, target: .web)
        let projectURL = try #require(host.loadedProjectURL)

        // corner-pin has no Node.js. Placing it in a browser project must not fail: it lands with the
        // Node.swift a conversion run can translate, and the run is what writes the browser version.
        let id = try host.placeLibraryItem(.library(source: .builtIn, id: "corner-pin"),
                                           position: SZPoint(x: 0, y: 0), deferBuild: true)
        let node = try SZLibraryTestSupport.node(host, id)
        #expect(node.libraryID == "corner-pin")
        #expect(node.builtTargets == [.native], "the platform whose source actually arrived")
        #expect(FileManager.default.fileExists(
            atPath: SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: id, target: .native).path))
        #expect(!FileManager.default.fileExists(
            atPath: SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: id, target: .web).path))
    }

    @Test func aNodeThatCanNeverRunHereIsRefusedInItsOwnWords() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(in: dir, target: .web)
        #expect(throws: (any Error).self) {
            try host.placeLibraryItem(.library(source: .builtIn, id: "osc-input"),
                                      position: SZPoint(x: 0, y: 0), deferBuild: true)
        }
        do {
            _ = try host.placeLibraryItem(.library(source: .builtIn, id: "osc-input"),
                                          position: SZPoint(x: 0, y: 0), deferBuild: true)
        } catch {
            #expect(error.localizedDescription.contains("raw UDP"), "\(error.localizedDescription)")
            #expect(!SZLibraryTestSupport.containsUUIDPrefix(error.localizedDescription))
        }
    }
}
