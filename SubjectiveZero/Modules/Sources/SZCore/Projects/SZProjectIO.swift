// SPDX-License-Identifier: AGPL-3.0-only
// Load/save the on-disk `.subz` project layout (docs/GRAPH_AND_NODES.md):
//
//   MyProject.subz/
//   ├─ project.json            // { "project": { name, author, viewport, graph } } — nodes by id,
//   │                          //   connections, render endpoint. Node CONTRACTS are NOT inline here.
//   └─ nodes/<node-id>/
//      ├─ node-contract.json   // the node's contract (when generated)
//      └─ Node.swift           // the node's source (owned by the runtime/host, untouched here)
//
// `project.json` stores only graph-level info; each node's contract lives in its folder. This splitter
// keeps node source/contracts isolated and inspectable. Pure SZCore — no Metal, no compilation.
import Foundation

public enum SZProjectIO {
    public enum IOError: Error, CustomStringConvertible, LocalizedError {
        case notADirectory(URL)
        case missingProjectFile(URL)

        public var description: String {
            switch self {
            case .notADirectory(let url): "not a .subz directory: \(url.path)"
            case .missingProjectFile(let url): "missing project.json in \(url.path)"
            }
        }

        /// Without this, NSAlert renders the useless "(SZCore.SZProjectIO.IOError error 0.)"
        /// instead of the description above — LocalizedError is what error dialogs actually read.
        public var errorDescription: String? { description }
    }

    /// Top-level `project.json` wrapper — matches the documented `{ "project": { … } }` shape.
    private struct Document: Codable {
        var project: SZProject
    }

    static let projectFileName = "project.json"
    static let nodesDirName = "nodes"
    static let contractFileName = "node-contract.json"

    private static func encoder() -> JSONEncoder { SZJSON.encoder() }

    /// The one serialization of a `node-contract.json` — used by `save` for the live file AND by the
    /// staging writer, so a staged contract is byte-comparable to the live one (no serializer noise).
    public static func contractData(_ contract: SZNodeContract) throws -> Data {
        try encoder().encode(contract)
    }

    /// Write `project` into the `.subz` directory at `url`: `project.json` (with node contracts stripped)
    /// + one `node-contract.json` per node that has a contract. Leaves any existing `Node.swift` files
    /// untouched (node source is owned by the runtime/host, not this splitter).
    public static func save(_ project: SZProject, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)

        // project.json carries the graph with contracts stripped (they live in node folders).
        var stripped = project
        for i in stripped.graph.nodes.indices { stripped.graph.nodes[i].contract = nil }
        let data = try encoder().encode(Document(project: stripped))
        try data.write(to: url.appending(path: projectFileName), options: .atomic)

        // Each node folder owns its contract.
        let nodesDir = url.appending(path: nodesDirName)
        for node in project.graph.nodes {
            guard let contract = node.contract else { continue }
            let folder = nodesDir.appending(path: node.id.description)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try contractData(contract).write(to: folder.appending(path: contractFileName), options: .atomic)
        }
    }

    /// Read the `.subz` directory at `url` back into an `SZProject`: decode `project.json`, then fold each
    /// node's `node-contract.json` (when present) back onto its node.
    public static func load(from url: URL) throws -> SZProject {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw IOError.notADirectory(url)
        }
        let projectFile = url.appending(path: projectFileName)
        guard fm.fileExists(atPath: projectFile.path) else { throw IOError.missingProjectFile(url) }

        var project = try JSONDecoder().decode(Document.self, from: Data(contentsOf: projectFile)).project

        let nodesDir = url.appending(path: nodesDirName)
        for i in project.graph.nodes.indices {
            let contractFile = nodesDir
                .appending(path: project.graph.nodes[i].id.description)
                .appending(path: contractFileName)
            guard fm.fileExists(atPath: contractFile.path) else { continue }
            project.graph.nodes[i].contract = try JSONDecoder()
                .decode(SZNodeContract.self, from: Data(contentsOf: contractFile))
        }
        reconcileRebuildFlags(in: &project.graph, projectURL: url)
        return project
    }

    /// The load-time pass over every built node: seed the build stamp where none is recorded, and audit the
    /// source against the contract for the one fault a static scan can prove.
    ///
    /// Seeding is "trust the build": a `.generated` node with no stamp (built before stamps existed, or a
    /// hand-assembled bundle) is taken to implement its current contract + prompt — the alternative, flagging
    /// every such node dirty, would regenerate finished work on open. Its `rebuildReason` derives from the
    /// stamp from here on (`SZNode.rebuildReason`).
    ///
    /// The audit sets the ephemeral `sourceMismatch` (never persisted; the host attaches the diagnostic
    /// text and re-audits after promote / hot reload). Only `errors` — a port the CODE NAMES that the
    /// contract does not declare — count. The audit's other half (a contract port the code never names)
    /// is unreliable: it is a string-literal scan, so a node that builds a port name at runtime
    /// (`NodeLibrary/audio-bands`: `ctx.setOutputFloat(kBandNames[b], …)`) would read dirty on every open.
    private static func reconcileRebuildFlags(in graph: inout SZGraph, projectURL: URL) {
        for i in graph.nodes.indices {
            let node = graph.nodes[i]
            guard node.kind == .generated else { continue }
            if node.buildStamp == nil {
                graph.nodes[i].buildStamp = .trusting(contract: node.contract, prompt: node.prompt)
            }
            guard let contract = node.contract,
                  let source = try? String(contentsOf: nodeSourceURL(projectURL: projectURL, nodeID: node.id),
                                           encoding: .utf8) else { continue }
            graph.nodes[i].sourceMismatch = !SZPortBindingAudit.audit(contract: contract, source: source).errors.isEmpty
        }
    }

    /// The on-disk path of a node's `Node.swift` source inside a `.subz` directory.
    public static func nodeSourceURL(projectURL: URL, nodeID: SZNodeID) -> URL {
        projectURL.appending(path: nodesDirName).appending(path: nodeID.description).appending(path: "Node.swift")
    }

    /// The on-disk path of a node's optional `Card.swift` (its custom card), beside `Node.swift`.
    public static func cardSourceURL(projectURL: URL, nodeID: SZNodeID) -> URL {
        projectURL.appending(path: nodesDirName).appending(path: nodeID.description).appending(path: "Card.swift")
    }
}
