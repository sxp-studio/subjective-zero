// SPDX-License-Identifier: AGPL-3.0-only
// Where a node was copied from and whether it has changed since. A placed node is a copy of a library
// entry or of another node; `copiedHash` is the source as copied, so the live file tells an untouched
// copy from an edited one. Copies of one thing share a family (SZGraph.lineageFamily); that is what the
// Director reads before editing "the blur" versus "all the blurs", and what apply-to-copies acts on.
import Foundation
import SZCore

/// What a node was copied from, whether it has changed since, and its copies elsewhere in the project.
struct SZNodeLineage: Equatable {
    enum Origin: Equatable {
        case library(SZLibraryRef)
        case node(SZNodeID, title: String)
    }
    struct Copy: Equatable {
        var id: SZNodeID
        var title: String
        /// the copy's live source still is what it copied
        var inSync: Bool
    }
    var origin: Origin?
    /// this node's live source differs from what it copied
    var changed: Bool
    var copies: [Copy]
}

extension SZHost {
    /// Hash of the node's live source for the project's platform; nil without a file.
    func liveSourceHash(_ id: SZNodeID) -> String? {
        guard let projectURL = loadedProjectURL,
              let data = try? Data(contentsOf: SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: id,
                                                                          target: projectTarget))
        else { return nil }
        return Self.contentHash(data)
    }

    /// The node's lineage, or nil when it came from nowhere and nothing was copied from it.
    func lineage(of id: SZNodeID) -> SZNodeLineage? {
        guard let graph = store.project?.graph, let node = graph.node(id: id) else { return nil }
        var origin: SZNodeLineage.Origin?
        if let ref = node.libraryRef {
            origin = .library(ref)
        } else if let parent = node.copiedFrom {
            origin = .node(parent, title: graph.node(id: parent)?.title ?? "a removed node")
        }
        let family = graph.lineageFamily(of: id)
        let copies = graph.nodes
            .filter { $0.id != id && $0.kind == .generated && graph.lineageFamily(of: $0.id) == family }
            .map { SZNodeLineage.Copy(id: $0.id, title: $0.title, inSync: isInSync($0)) }
        guard origin != nil || !copies.isEmpty else { return nil }
        return SZNodeLineage(origin: origin, changed: node.copiedHash != nil && !isInSync(node), copies: copies)
    }

    private func isInSync(_ node: SZNode) -> Bool {
        guard let hash = node.copiedHash else { return false }
        return liveSourceHash(node.id) == hash
    }

    /// Copy `source`'s platform file, card, contract (each copy's input values kept), title, symbol, prompt
    /// and stamp onto its copies. Targets default to the copies still in sync; others are skipped unless
    /// named. A target another build holds refuses the whole call. Sets the status line.
    @discardableResult
    func applyNodeToCopies(source: SZNodeID, to targets: [SZNodeID]?, origin: SZMutationOrigin) throws
        -> (applied: [SZNodeID], skipped: [(SZNodeID, String)]) {
        guard let projectURL = loadedProjectURL else { throw SZMCPError.message("no project loaded") }
        guard let sourceNode = store.project?.graph.node(id: source), let contract = sourceNode.contract else {
            throw SZMCPError.message("no built node \(source)")
        }
        let copies = lineage(of: source)?.copies ?? []
        var skipped: [(SZNodeID, String)] = []
        var chosen: [SZNodeID] = []
        if let targets {
            for id in targets {
                if copies.contains(where: { $0.id == id }) { chosen.append(id) }
                else { skipped.append((id, "not a copy of \(sourceNode.title)")) }
            }
        } else {
            for copy in copies {
                if copy.inSync { chosen.append(copy.id) } else { skipped.append((copy.id, "changed on its own")) }
            }
        }
        if let denial = fenceDenial(nodes: chosen, origin: origin) { throw SZMCPError.message(denial) }
        guard !chosen.isEmpty else { return ([], skipped) }

        let fm = FileManager.default
        let sourceURL = SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: source, target: projectTarget)
        let bytes = try Data(contentsOf: sourceURL)
        let hash = Self.contentHash(bytes)
        let cardURL = SZProjectIO.cardSourceURL(projectURL: projectURL, nodeID: source)
        let hasCard = projectTarget == .native && fm.fileExists(atPath: cardURL.path)
        for id in chosen {
            // only this platform's file moves; the other platform's file and stamp go stale and a target
            // switch regenerates them
            try bytes.write(to: SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: id, target: projectTarget))
            if hasCard { try Self.replaceFile(at: SZProjectIO.cardSourceURL(projectURL: projectURL, nodeID: id), with: cardURL) }
            store.mutate { project in
                guard let i = project.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
                var merged = contract
                let own = project.graph.nodes[i].contract?.inputs ?? []
                for pi in merged.inputs.indices {
                    if let kept = own.first(where: { $0.name == merged.inputs[pi].name && $0.type == merged.inputs[pi].type }) {
                        merged.inputs[pi].def = kept.def
                    }
                }
                project.graph.nodes[i].contract = merged
                project.graph.nodes[i].title = sourceNode.title
                project.graph.nodes[i].sfSymbol = sourceNode.sfSymbol
                project.graph.nodes[i].prompt = sourceNode.prompt
                project.graph.nodes[i].buildStamps[projectTarget] = sourceNode.buildStamps[projectTarget]
                project.graph.nodes[i].builtTargets.insert(projectTarget)
                project.graph.nodes[i].copiedHash = hash
            }
        }
        // the source is what its copies now hold: in sync with them from here
        store.mutate { project in
            guard let i = project.graph.nodes.firstIndex(where: { $0.id == source }) else { return }
            project.graph.nodes[i].copiedHash = hash
        }
        if let project = store.project { try SZProjectIO.save(project, to: projectURL) }
        for id in chosen {
            reloadNodeUnderPill(id, in: projectURL)
            classifyRebuild(node: id)
        }
        watchNodeSources(in: projectURL)
        noteMutation("applied node to copies", [sourceNode.title] + chosen.map(mutationTitle), origin: origin)
        var line = "Applied \(sourceNode.title) to \(chosen.count) \(chosen.count == 1 ? "copy" : "copies")"
        if !skipped.isEmpty { line += ", \(skipped.count) changed on \(skipped.count == 1 ? "its" : "their") own" }
        status = line
        return (chosen, skipped)
    }

    /// Compile one node under a Reloading pill: just that node when it is live, the whole graph otherwise.
    /// On failure the pill turns Error with the first diagnostic line and the log is recorded. Returns success.
    @discardableResult
    func reloadNodeUnderPill(_ id: SZNodeID, in projectURL: URL) -> Bool {
        nodeAgentState[id] = SZNodeAgentState(phase: .reloading)
        do {
            if let backend, backend.isNodeLoaded(id) {
                try backend.reloadNode(id: id, source: SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: id,
                                                                                 target: projectTarget))
            } else {
                try reloadBackendGraph(at: projectURL)
            }
            nodeAgentState[id] = nil
            return true
        } catch {
            let log = "\(error)"
            recordBuildErrors(log)
            nodeAgentState[id] = SZNodeAgentState(phase: .error, message: Self.firstErrorLine(in: log), errorDetail: log)
            print("[SZHost] reload failed for \(id.uuidString.prefix(8)): \(log)")
            return false
        }
    }

    /// Copy `source` over `destination`, replacing what is there.
    static func replaceFile(at destination: URL, with source: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
