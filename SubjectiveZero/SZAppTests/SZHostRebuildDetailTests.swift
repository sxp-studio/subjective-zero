// SPDX-License-Identifier: AGPL-3.0-only
// The agent surface tells WHY a node needs a rebuild: `agent_read_node` / `agent_read_graph` carry the derived
// `rebuildReason` and its evidence (`rebuildDetail` — the port audit's lines, or the ports off the build stamp),
// so an agent reconciles the named ports instead of theorizing about the files. A clean node carries neither.
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostRebuildDetailTests {
    private static let surface: Set<SZNodeContract.PortSignature> =
        [.init(direction: .input, name: "input", type: .texture), .init(direction: .output, name: "output", type: .texture)]
    private static func contract(extraInput: SZPort? = nil) -> SZNodeContract {
        SZNodeContract(title: "N", sfSymbol: "circle", summary: "",
                       inputs: [SZPort(name: "input", type: .texture)] + (extraInput.map { [$0] } ?? []),
                       outputs: [SZPort(name: "output", type: .texture)])
    }
    private static func built(contract: SZNodeContract, sourceMismatch: Bool = false) -> SZNode {
        SZNode(kind: .generated, title: "Built", prompt: "p", contract: contract, position: SZPoint(x: 0, y: 0),
               buildStamp: SZBuildStamp(portSurface: surface, prompt: "p"), sourceMismatch: sourceMismatch)
    }

    private func host(_ nodes: [SZNode]) -> SZHost {
        let host = SZHost()
        host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: nodes)))
        return host
    }
    private func readNode(_ host: SZHost, _ id: SZNodeID) throws -> [String: Any] {
        guard case .text(let text) = try SZHostBridge(host: host)
            .callTool(name: "agent_read_node", arguments: ["node": id.uuidString]) else { return [:] }
        return (try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    @Test func aCleanBuiltNodeCarriesNoRebuildKeys() throws {
        let node = Self.built(contract: Self.contract())
        let json = try readNode(host([node]), node.id)
        #expect(json["rebuildReason"] == nil && json["rebuildDetail"] == nil)
        #expect(json["hasCard"] as? Bool == false)
    }

    @Test func aSurfaceOffTheStampReportsContractChangedWithThePortsAdded() throws {
        let node = Self.built(contract: Self.contract(extraInput: SZPort(name: "amount", type: .float)))
        let json = try readNode(host([node]), node.id)
        #expect(json["rebuildReason"] as? String == "contractChanged")
        #expect(json["rebuildDetail"] as? String == "ports added since the build: input \"amount\":float")
    }

    @Test func aSourceMismatchReportsTheAuditLines() throws {
        // No project on disk, so the live audit cannot run: the cached pill detail (what `classifyRebuild`
        // attached) is what the agent reads.
        let node = Self.built(contract: Self.contract(), sourceMismatch: true)
        let host = host([node])
        let line = "Node.swift reads input port \"scale\" but node-contract.json declares no such input."
        host.nodeAgentState[node.id, default: SZNodeAgentState()].errorDetail = line
        let json = try readNode(host, node.id)
        #expect(json["rebuildReason"] as? String == "sourceMismatch")
        #expect(json["rebuildDetail"] as? String == line)
    }

    @Test func theGraphReadAnnotatesEachFlaggedNodeAndLeavesTheRestAlone() throws {
        let clean = Self.built(contract: Self.contract())
        let drifted = Self.built(contract: Self.contract(extraInput: SZPort(name: "amount", type: .float)))
        let host = host([clean, drifted])
        guard case .text(let text) = try SZHostBridge(host: host).callTool(name: "agent_read_graph", arguments: [:]),
              let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let nodes = json["nodes"] as? [[String: Any]] else { Issue.record("no graph"); return }
        let byID = Dictionary(uniqueKeysWithValues: nodes.compactMap { n in (n["id"] as? String).map { ($0, n) } })
        #expect(byID[clean.id.uuidString]?["rebuildReason"] == nil)
        #expect(byID[drifted.id.uuidString]?["rebuildReason"] as? String == "contractChanged")
        #expect((byID[drifted.id.uuidString]?["rebuildDetail"] as? String)?.contains("\"amount\":float") == true)
        #expect(json["connections"] != nil)   // the rest of the graph payload survives the annotation
    }
}
