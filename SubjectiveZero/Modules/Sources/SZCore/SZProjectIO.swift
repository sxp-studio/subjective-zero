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
    public enum IOError: Error, CustomStringConvertible {
        case notADirectory(URL)
        case missingProjectFile(URL)

        public var description: String {
            switch self {
            case .notADirectory(let url): "not a .subz directory: \(url.path)"
            case .missingProjectFile(let url): "missing project.json in \(url.path)"
            }
        }
    }

    /// Top-level `project.json` wrapper — matches the documented `{ "project": { … } }` shape.
    private struct Document: Codable {
        var project: SZProject
    }

    static let projectFileName = "project.json"
    static let nodesDirName = "nodes"
    static let contractFileName = "node-contract.json"

    private static func encoder() -> JSONEncoder { SZJSON.encoder() }

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
            let contractData = try encoder().encode(contract)
            try contractData.write(to: folder.appending(path: contractFileName), options: .atomic)
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

    /// ESTABLISH the contract↔code invariant for files nothing vouches for.
    ///
    /// `SZStore.editPorts` MAINTAINS the invariant across edits by diffing the port surface it is about to write
    /// against the one the build matched. That diff is unavailable here: a project on disk carries only the
    /// result, not the edit. So load re-derives what it can by auditing each built node's source against its
    /// contract. This also covers a hand-edited `project.json` / `Node.swift`.
    ///
    /// Only `errors` — a port the CODE NAMES that the contract does not declare — raise the flag. The audit's
    /// other half (a contract port the code never names) is unreliable as a staleness signal: it is a
    /// string-literal scan, so a node that builds a port name at runtime trips it. `NodeLibrary/audio-bands`
    /// does exactly that (`ctx.setOutputFloat(kBandNames[b], …)`), and a warning-triggered flag would mark it
    /// dirty on every single open and regenerate it forever. Errors are unambiguous and cannot loop: code that
    /// names only declared ports audits clean and stays clean.
    ///
    /// The cost of errors-only: a port declared but never implemented — with no undeclared reads to give it away
    /// — is invisible here. `editPorts` catches that at the moment it is introduced, which is the only moment it
    /// is distinguishable.
    private static func reconcileRebuildFlags(in graph: inout SZGraph, projectURL: URL) {
        for i in graph.nodes.indices {
            let node = graph.nodes[i]
            guard node.kind == .generated, node.rebuildReason == nil, let contract = node.contract else { continue }
            guard let source = try? String(contentsOf: nodeSourceURL(projectURL: projectURL, nodeID: node.id),
                                           encoding: .utf8) else { continue }
            graph.nodes[i].rebuildReason = SZPortBindingAudit.rebuildReason(contract: contract, source: source)
        }
    }

    /// The on-disk path of a node's `Node.swift` source inside a `.subz` directory.
    public static func nodeSourceURL(projectURL: URL, nodeID: SZNodeID) -> URL {
        projectURL.appending(path: nodesDirName).appending(path: nodeID.description).appending(path: "Node.swift")
    }
}
