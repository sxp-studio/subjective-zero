// SPDX-License-Identifier: AGPL-3.0-only
// The Library panel's groups are read off the ports, never curated. Pinned on synthetic contracts and
// on every shipped node folder, and the shipped index must name exactly the shipped folders.
import Foundation
import Testing
@testable import SZCore

private let libraryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()   // SZCoreTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // Modules
    .deletingLastPathComponent()   // SubjectiveZero
    .appending(path: "NodeLibrary")

@Test func texturesOutWithNoneInIsASource() {
    #expect(SZLibraryGroup.derived(inputs: [.bool, .enumeration], outputs: [.texture]) == .sources)
    #expect(SZLibraryGroup.derived(inputs: [], outputs: [.texture]) == .sources)
}

@Test func texturesInAndOutIsAnEffect_blendIncluded() {
    #expect(SZLibraryGroup.derived(inputs: [.texture, .float], outputs: [.texture]) == .effects)
    #expect(SZLibraryGroup.derived(inputs: [.texture, .texture, .enumeration], outputs: [.texture]) == .effects)
}

@Test func sampleArraysEitherWayAreAudio() {
    #expect(SZLibraryGroup.derived(inputs: [.floatArray, .float], outputs: [.float, .float]) == .audio)
    #expect(SZLibraryGroup.derived(inputs: [.float, .enumeration], outputs: [.floatArray]) == .audio)
}

@Test func numbersOutWithNoTextureIsControl() {
    #expect(SZLibraryGroup.derived(inputs: [.float, .float], outputs: [.float]) == .control)
    #expect(SZLibraryGroup.derived(inputs: [.enumeration, .string], outputs: [.float2, .string]) == .control)
}

@Test func everyShippedNodeLandsInAGroup() throws {
    let folders = try FileManager.default.contentsOfDirectory(at: libraryRoot, includingPropertiesForKeys: nil)
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    try #require(folders.count > 20, "the shipped library moved?")
    var counts: [SZLibraryGroup: Int] = [:]
    for folder in folders {
        let contract = try JSONDecoder().decode(
            SZNodeContract.self, from: Data(contentsOf: folder.appending(path: "node-contract.json")))
        counts[SZLibraryGroup.derived(inputs: contract.inputs.map(\.type), outputs: contract.outputs.map(\.type)), default: 0] += 1
    }
    // Four groups, none a singleton named after its only node.
    for group in SZLibraryGroup.allCases {
        #expect((counts[group] ?? 0) >= 3, "\(group) has \(counts[group] ?? 0) nodes")
    }
}

@Test func theShippedIndexNamesExactlyTheShippedFolders() throws {
    let folders = try FileManager.default.contentsOfDirectory(at: libraryRoot, includingPropertiesForKeys: nil)
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .map(\.lastPathComponent)
    let index = try JSONDecoder().decode(
        SZLibraryCurationFile.self, from: Data(contentsOf: libraryRoot.appending(path: "index.json")))
    #expect(Set(index.nodes.map(\.id)) == Set(folders))
}

@Test func itemCarriesWhatThePanelShowsAndSearches() {
    let contract = SZNodeContract(
        title: "Gaussian Blur", sfSymbol: "drop", summary: "Soft blur.",
        inputs: [SZPort(name: "input", type: .texture), SZPort(name: "radius", type: .float)],
        outputs: [SZPort(name: "output", type: .texture)])
    let curation = SZLibraryCurationEntry(id: "gaussian-blur", tags: ["blur", "soften"], purpose: "Blurs the image.")
    let entry = SZLibraryIndexEntry(id: "gaussian-blur", contract: contract, curation: curation, hasCard: false)
    let item = SZLibraryItem(entry: entry, source: .builtIn)

    #expect(item.id == "builtin/gaussian-blur")
    #expect(item.ref == .library(source: .builtIn, id: "gaussian-blur"))
    #expect(item.group == .effects)
    #expect(item.summary == "Blurs the image.")     // purpose over the contract summary when curated
    #expect(item.searchTerms.contains("gaussian-blur") && item.searchTerms.contains("soften"))
    #expect(!item.hasCard)
    // every word must land somewhere; order and case do not matter
    #expect(item.matches(query: "Blur gaussian") && !item.matches(query: "blur sharpen"))
}

@Test func nodeLineageRoundTrips() throws {
    let from = SZNodeID()
    var node = SZNode(kind: .generated, title: "Blur", position: SZPoint(x: 0, y: 0),
                      libraryID: "gaussian-blur", librarySource: .mine, copiedFrom: from, copiedHash: "abc")
    node.buildStamps[.native] = .trusting(contract: nil, prompt: nil)
    let decoded = try JSONDecoder().decode(SZNode.self, from: JSONEncoder().encode(node))
    #expect(decoded.libraryID == "gaussian-blur")
    #expect(decoded.librarySource == .mine)
    #expect(decoded.libraryRef == .library(source: .mine, id: "gaussian-blur"))
    #expect(decoded.copiedFrom == from)
    #expect(decoded.copiedHash == "abc")
}

@Test func lineageFamilyFollowsTheCopyChainToALibraryEntryOrARoot() {
    let placed = SZNode(kind: .generated, title: "Blur", position: SZPoint(x: 0, y: 0), libraryID: "gaussian-blur")
    let duplicated = SZNode(kind: .generated, title: "Blur", position: SZPoint(x: 0, y: 0), copiedFrom: placed.id)
    let original = SZNode(kind: .generated, title: "Glow", position: SZPoint(x: 0, y: 0))
    let copy = SZNode(kind: .generated, title: "Glow", position: SZPoint(x: 0, y: 0), copiedFrom: original.id)
    let graph = SZGraph(nodes: [placed, duplicated, original, copy])
    #expect(graph.lineageFamily(of: duplicated.id) == "builtin/gaussian-blur")
    #expect(graph.lineageFamily(of: copy.id) == original.id.uuidString)
    #expect(graph.lineageFamily(of: original.id) == original.id.uuidString)
}
