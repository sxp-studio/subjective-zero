// SPDX-License-Identifier: AGPL-3.0-only
// The library's web nodes: every `Node.js` has the ABI shape, imports nothing, and names exactly the
// ports its contract declares (the same port audit the promote gate runs).
import Foundation
import Testing
@testable import SZAI
@testable import SZCore

private let libraryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()   // the file
    .deletingLastPathComponent()   // SZAITests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // Modules
    .appending(path: "NodeLibrary")

/// Every `<id>/Node.js` under the library, with its contract.
private func webNodes() throws -> [(id: String, source: String, contract: SZNodeContract)] {
    try FileManager.default.contentsOfDirectory(atPath: libraryRoot.path).sorted().compactMap { id in
        let dir = libraryRoot.appending(path: id)
        guard let source = try? String(contentsOf: dir.appending(path: "Node.js"), encoding: .utf8) else {
            return nil
        }
        let contract = try JSONDecoder().decode(
            SZNodeContract.self, from: Data(contentsOf: dir.appending(path: "node-contract.json")))
        return (id, source, contract)
    }
}

struct SZWebNodeLibraryTests {

    @Test func theLibraryShipsWebNodes() throws {
        let ids = try webNodes().map(\.id)
        #expect(ids.contains("checkerboard") && ids.contains("brightness"))
    }

    @Test func everyWebNodeHasTheShapeAndImportsNothing() throws {
        for node in try webNodes() {
            #expect(node.source.contains("export default class Node"), "\(node.id): no default Node class")
            let topLevelImport = node.source.split(separator: "\n").contains { $0.hasPrefix("import ") }
            #expect(!topLevelImport, "\(node.id): a top-level import is refused by the gate")
        }
    }

    @Test func everyWebNodeBindsItsContractPorts() throws {
        for node in try webNodes() {
            let audit = SZPortBindingAudit.audit(contract: node.contract, source: node.source)
            #expect(audit.errors.isEmpty, "\(node.id): \(audit.errors)")
        }
    }

    @Test func theABIDocFollowsTheTarget() {
        #expect(SZAgentDocs.abiReference(for: .web).contains("shaderPass"))
        #expect(SZAgentDocs.abiReference(for: .native).contains("MTLDevice"))
    }
}
