// SPDX-License-Identifier: AGPL-3.0-only
// Portable by default, and a node declares a limitation rather than a capability. The file on disk
// is the evidence; the contract only explains a file that will never be written. Also the gate that
// stops a shipped library saying both at once.
import Foundation
import Testing
@testable import SZCore

private let libraryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()   // SZCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // Modules
    .deletingLastPathComponent()   // SubjectiveZero
    .appending(path: "NodeLibrary")

private func shippedNodeFolders() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: libraryRoot, includingPropertiesForKeys: nil)
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
}

@Test func aFileForThePlatformMeansItRuns() {
    #expect(SZLibraryPortability.of(target: .web, builtTargets: [.native, .web], unsupported: nil) == .runs)
    #expect(SZLibraryPortability.of(target: .native, builtTargets: [.native], unsupported: nil) == .runs)
}

@Test func noFileAndNoWordMeansSomebodyHasToWriteIt() {
    #expect(SZLibraryPortability.of(target: .web, builtTargets: [.native], unsupported: nil) == .portable)
    // An empty reason is not a reason: it degrades to portable rather than a wall nobody can read.
    #expect(SZLibraryPortability.of(target: .web, builtTargets: [.native], unsupported: ["web": ""]) == .portable)
    // A wall on the OTHER platform says nothing about this one.
    #expect(SZLibraryPortability.of(target: .web, builtTargets: [.native],
                                    unsupported: ["native": "nope"]) == .portable)
}

@Test func aDeclaredWallCarriesItsReason() {
    let portability = SZLibraryPortability.of(
        target: .web, builtTargets: [.native], unsupported: ["web": "A browser has no raw UDP."])
    #expect(portability == .unsupported(reason: "A browser has no raw UDP."))
    #expect(portability.wall == "A browser has no raw UDP.")
    #expect(SZLibraryPortability.runs.wall == nil)
    #expect(SZLibraryPortability.portable.wall == nil)
}

@Test func theFileWinsOverAContractThatContradictsIt() {
    // Both say something about `web`, and the file is the one that is evidence.
    let both = SZLibraryPortability.of(target: .web, builtTargets: [.native, .web],
                                       unsupported: ["web": "it can't"])
    #expect(both == .runs)
    #expect(SZLibraryPortability.contradictions(builtTargets: [.native, .web],
                                                unsupported: ["web": "it can't"]) == [.web])
    #expect(SZLibraryPortability.contradictions(builtTargets: [.native],
                                                unsupported: ["web": "it can't"]).isEmpty)
    #expect(SZLibraryPortability.contradictions(builtTargets: [.native, .web], unsupported: nil).isEmpty)
}

@Test func noShippedNodeDeclaresAWallItAlsoShipsAFileFor() throws {
    let folders = try shippedNodeFolders()
    #expect(folders.count > 20, "the shipped library moved? found \(folders.count)")
    for folder in folders {
        let contract = try JSONDecoder().decode(
            SZNodeContract.self, from: Data(contentsOf: folder.appending(path: "node-contract.json")))
        let built = Set(SZProjectTarget.allCases.filter {
            FileManager.default.fileExists(atPath: folder.appending(path: $0.sourceFileName).path)
        })
        #expect(SZLibraryPortability.contradictions(builtTargets: built,
                                                    unsupported: contract.unsupported).isEmpty,
                "\(folder.lastPathComponent) says a platform is impossible and ships its source anyway")
    }
}

@Test func onlyTheTwoRealWallsAreDeclared() throws {
    var walls: [String: [String]] = [:]
    for folder in try shippedNodeFolders() {
        let contract = try JSONDecoder().decode(
            SZNodeContract.self, from: Data(contentsOf: folder.appending(path: "node-contract.json")))
        if let unsupported = contract.unsupported, !unsupported.isEmpty {
            walls[folder.lastPathComponent] = unsupported.keys.sorted()
        }
    }
    // Everything else with a missing source is a porting backlog, not a wall. Adding a third needs a
    // reason good enough to change this line.
    #expect(walls == ["system-audio.macos": ["web"], "osc-input": ["web"]], "declared walls: \(walls)")
}
