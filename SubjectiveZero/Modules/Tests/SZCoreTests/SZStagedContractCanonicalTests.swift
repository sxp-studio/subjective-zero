// SPDX-License-Identifier: AGPL-3.0-only
// A staged node-contract.json must be byte-identical to how the live one is saved for the same value:
// an MCP-shaped dict (JSONSerialization input) → SZNodeContract → `SZProjectIO.contractData`, compared with
// the per-node file `SZProjectIO.save` writes. Float formatting must never show up as a diff.
import Foundation
import Testing
@testable import SZCore

@Test func stagedContractBytesMatchTheLiveSave() throws {
    let dict: [String: Any] = [
        "title": "Plasma", "sfSymbol": "circle", "summary": "s",
        "inputs": [
            ["name": "amount", "type": "float",
             "ui": ["kind": "slider", "min": 0, "max": 1],
             "default": ["type": "float", "value": 0.85]],
            ["name": "speed", "type": "float", "default": ["type": "float", "value": 0.1]],
            ["name": "seed", "type": "float", "default": ["type": "float", "value": 0.5616923570632935]],
        ],
        "outputs": [["name": "out", "type": "texture"]],
    ]
    let raw = try JSONSerialization.data(withJSONObject: dict)
    let contract = try JSONDecoder().decode(SZNodeContract.self, from: raw)
    let staged = try SZProjectIO.contractData(contract)

    let node = SZNode(kind: .generated, title: contract.title, contract: contract, position: SZPoint(x: 0, y: 0))
    let project = SZProject(name: "t", graph: SZGraph(nodes: [node]))
    let dir = FileManager.default.temporaryDirectory.appending(path: "sz-canon-\(UUID().uuidString).subz")
    defer { try? FileManager.default.removeItem(at: dir) }
    try SZProjectIO.save(project, to: dir)
    let live = try Data(contentsOf: dir.appending(path: "nodes/\(node.id.description)/node-contract.json"))

    #expect(staged == live)
    let text = String(decoding: staged, as: UTF8.self)
    #expect(text.contains("0.85") && !text.contains("0.84999"))
    #expect(text.contains("0.1,") || text.contains("0.1\n"))
}
