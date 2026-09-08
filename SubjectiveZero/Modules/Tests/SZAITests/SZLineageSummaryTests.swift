// SPDX-License-Identifier: AGPL-3.0-only
// The Director sees where a node was copied from and how many copies share that origin, in the graph
// summary, and the toolbelt tells it when to edit one copy and when to apply one to the others.
import Foundation
import Testing
import SZCore
@testable import SZAI

private let shippedPacksRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()   // the file
    .deletingLastPathComponent()   // SZAITests
    .deletingLastPathComponent()   // Tests
    .appending(path: "Sources/SZAI/Resources/Agents")

private func built(_ title: String, libraryID: String? = nil, copiedFrom: SZNodeID? = nil) -> SZNode {
    let contract = SZNodeContract(title: title, sfSymbol: "circle", summary: "",
                                  inputs: [SZPort(name: "input", type: .texture)],
                                  outputs: [SZPort(name: "output", type: .texture)])
    return SZNode(kind: .generated, title: title, contract: contract, position: SZPoint(x: 0, y: 0),
                  buildStamp: .trusting(contract: contract, prompt: nil),
                  libraryID: libraryID, copiedFrom: copiedFrom, copiedHash: "00")
}

@Test func aNodeWithNoOriginAndNoCopiesGetsNoLineageClause() {
    let plain = built("Glow")
    let summary = SZDirectorPrompt.graphSummary(SZGraph(nodes: [plain]))
    #expect(!summary.contains("copy of"))
}

@Test func libraryCopiesCountEachOther() {
    let a = built("Gaussian Blur", libraryID: "gaussian-blur")
    let b = built("Gaussian Blur", libraryID: "gaussian-blur")
    let c = built("Gaussian Blur", libraryID: "gaussian-blur")
    let summary = SZDirectorPrompt.graphSummary(SZGraph(nodes: [a, b, c]))
    #expect(summary.contains("`\(a.id.uuidString)` \"Gaussian Blur\" — generated, contract[in: input:texture; out: output:texture] — copy of \"gaussian-blur\" (2 other copies)"))
}

@Test func aDuplicateNamesTheNodeItCameFromAndTheyCountAsOneFamily() {
    let original = built("Blur Pulse")
    let copy = built("Blur Pulse", copiedFrom: original.id)
    let summary = SZDirectorPrompt.graphSummary(SZGraph(nodes: [original, copy]))
    #expect(summary.contains("`\(copy.id.uuidString)` \"Blur Pulse\" — generated, contract[in: input:texture; out: output:texture] — copy of \"Blur Pulse\" (1 other copy)"))
    // the original has no origin but does have a copy, so it is counted too
    #expect(summary.contains("`\(original.id.uuidString)` \"Blur Pulse\" — generated, contract[in: input:texture; out: output:texture] — copy of an earlier node (1 other copy)"))
}

@Test func aDuplicateOfALibraryCopyJoinsTheLibraryFamily() {
    let placed = built("Gaussian Blur", libraryID: "gaussian-blur")
    let duplicated = built("Gaussian Blur", copiedFrom: placed.id)
    let graph = SZGraph(nodes: [placed, duplicated])
    #expect(graph.lineageFamily(of: duplicated.id) == "builtin/gaussian-blur")
    #expect(graph.lineageFamily(of: placed.id) == "builtin/gaussian-blur")
}

@Test func theToolbeltTellsTheDirectorHowToTreatCopies() throws {
    let graph = SZGraph(nodes: [built("Gaussian Blur", libraryID: "gaussian-blur")])
    let out = try SZBriefRenderer(packRoot: shippedPacksRoot).render(
        agent: "director", template: "chat", message: "fix the blur", world: SZWorld(graph: graph))
    for needle in ["### Copies of a node", "edits that node", "ui_apply_to_copies", "kept their own version",
                   "ui_duplicate_node", "ui_save_to_library", "Never invent a library name"] {
        #expect(out.contains(needle), "toolbelt lost: \(needle)")
    }
}
