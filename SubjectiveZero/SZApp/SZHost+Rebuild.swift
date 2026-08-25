// SPDX-License-Identifier: AGPL-3.0-only
// A built node whose contract has moved since that build: classifying WHY, and the one-click way out.
//
// `SZNode.rebuildReason` is DERIVED — the build stamp (what the last promote compiled against) gives the two
// benign states; `SZPortBindingAudit` over the live source gives the one fault state:
// - `.contractChanged` — the contract declares ports the code hasn't implemented yet; the node draws, they are inert.
// - `.intentChanged` — the prompt moved off the brief the build was written to; the fleet must regenerate.
// - `.sourceMismatch` — the code names an undeclared port (those reads resolve to nil, so the node silently runs
//   on hardcoded defaults) or owns a live AV resource with no `setPaused`. `agent_compile_node` refuses to promote.
//
// Classified by CONDITION, not by cause: a port the Director removed and one a human deleted by hand leave the
// node equally broken. Either way it heals the same two ways: a run picks it up (`runWorkSet` is built from
// `needsImplementation`; a promote re-stamps it), or `stageRebuildFix` composes a message to the node's own
// Coding Agent (never auto-sent — host-drafted messages COMPOSE).
import Foundation
import SZCore
import SZUI

@MainActor
extension SZHost {
    /// Re-audit a node's live source against its contract and set the ephemeral `sourceMismatch` from the
    /// verdict — set when the audit errors (with the human-readable detail on the pill),
    /// cleared when it is clean. Called after a port edit, a promote, a hot reload, and for every
    /// flagged node when a project opens. Never persisted: `SZProjectIO.load` re-derives it.
    func classifyRebuild(node id: SZNodeID) {
        // A contract change may have added, removed or re-typed a file port, so re-audit its files too.
        classifyInputFiles(node: id)
        guard let node = store.project?.graph.node(id: id), let errors = auditErrors(node) else { return }
        let mismatch = !errors.isEmpty
        if mismatch != node.sourceMismatch {
            store.mutate { project in
                guard let i = project.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
                project.graph.nodes[i].sourceMismatch = mismatch
            }
        }
        if mismatch {
            // Reuse the node's existing error surface: the pill becomes the clickable diagnostic popover.
            nodeAgentState[id, default: SZNodeAgentState()].errorDetail = errors.joined(separator: "\n")
        } else if node.sourceMismatch {
            nodeAgentState[id]?.errorDetail = nil
        }
    }

    /// The live audit's human-readable errors for a built node (one line each), nil when the audit is clean
    /// or cannot run (no project / not built / unreadable source). Recomputed on demand — the fix draft and
    /// the run-end accounting read the source as it is NOW, not a cached verdict.
    func liveAuditErrors(_ id: SZNodeID) -> String? {
        guard let node = store.project?.graph.node(id: id), let errors = auditErrors(node), !errors.isEmpty
        else { return nil }
        return errors.joined(separator: "\n")
    }

    /// The evidence behind a node's `rebuildReason`, for the agent surface (`agent_read_node`'s `rebuildDetail`):
    /// the port audit's lines for `.sourceMismatch` (live, else the cached pill detail), the ports off the build
    /// stamp for `.contractChanged`; nil for `.intentChanged` (the prompt is its own evidence) and for a clean node.
    func rebuildDetail(node id: SZNodeID) -> String? {
        guard let node = store.project?.graph.node(id: id), let reason = node.rebuildReason else { return nil }
        switch reason {
        case .sourceMismatch:
            return liveAuditErrors(id) ?? nodeAgentState[id]?.errorDetail
        case .contractChanged:
            guard let stamp = node.buildStamp else { return nil }
            let now = node.contract?.portSurface ?? []
            func list(_ ports: Set<SZNodeContract.PortSignature>) -> String {
                ports.map { "\($0.direction.rawValue) \"\($0.name)\":\($0.type.rawValue)" }.sorted().joined(separator: ", ")
            }
            var parts: [String] = []
            let added = now.subtracting(stamp.portSurface), removed = stamp.portSurface.subtracting(now)
            if !added.isEmpty { parts.append("ports added since the build: \(list(added))") }
            if !removed.isEmpty { parts.append("ports removed since the build: \(list(removed))") }
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        case .intentChanged:
            return nil
        }
    }

    /// Run `SZPortBindingAudit` over a built node's live source + contract; nil when it cannot run.
    private func auditErrors(_ node: SZNode) -> [String]? {
        guard let projectURL = loadedProjectURL, node.kind == .generated, let contract = node.contract,
              let source = try? String(contentsOf: SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: node.id),
                                       encoding: .utf8) else { return nil }
        return SZPortBindingAudit.audit(contract: contract, source: source).errors
    }

    /// After a project loads: `SZProjectIO.load` already audited every built node; this pass attaches the
    /// human-readable diagnostic to the ones it flagged (the model doesn't carry the text).
    func classifyRebuildsAfterLoad() {
        for node in store.project?.graph.nodes ?? [] where node.sourceMismatch {
            classifyRebuild(node: node.id)
        }
        // Files are a separate question and every node is a candidate — a node with a perfectly good
        // build renders black when its file has gone. Kept OUT of the loop above deliberately: that one
        // reads each `Node.swift` off disk, this one is a stat per file port.
        auditInputFiles()
    }

    /// Re-audit every node's file inputs — project open, and whenever the app comes back to the front
    /// (a file can be moved or deleted in the Finder while we are in the background, which is exactly
    /// what the session behind this feature did).
    func auditInputFiles() {
        for node in store.project?.graph.nodes ?? [] { classifyInputFiles(node: node.id) }
    }

    /// Re-audit ONE node's file inputs and store the verdict — the file-side sibling of `classifyRebuild`.
    /// One `stat` per file port holding an unconnected, non-empty value; nothing here reads a node source
    /// or touches the GPU. Writes only on a real change, so a clean node costs a comparison.
    func classifyInputFiles(node id: SZNodeID) {
        guard let projectURL = loadedProjectURL,
              let graph = store.project?.graph, let node = graph.node(id: id) else { return }
        let faults = SZFileInputAudit.faults(in: node,
                                             connected: SZFileInputAudit.connectedInputs(of: id, in: graph),
                                             projectURL: projectURL)
        guard faults != node.unreadableInputs else { return }
        store.mutate { project in
            guard let i = project.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
            project.graph.nodes[i].unreadableInputs = faults
        }
    }

    /// The pill's one-click fix: compose (never send) a message to the node's Coding Agent, and reveal that tab.
    /// Mirrors the split/merge suggestion path.
    ///
    /// A `.sourceMismatch` says the source and the contract disagree — it does NOT say which one is stale, and
    /// the two repairs are opposites. A port the code reads may have been wrongly dropped from the contract (the
    /// bug this whole feature exists for: a Director re-declaring a node's ports and deleting its knobs), or it
    /// may have been deliberately removed and the read is the leftover. Telling the agent to "rewrite Node.swift
    /// against the contract" silently picks the destructive reading and deletes working controls. So the draft
    /// states the conflict and leaves the judgement where the evidence is — the agent can see both files, and it
    /// may stage a contract as well as a source.
    ///
    /// The user still reads and sends this, so a wrong guess is theirs to correct before any token is spent.
    func stageRebuildFix(node id: SZNodeID) {
        guard let node = store.project?.graph.node(id: id), let reason = node.rebuildReason else { return }
        let mention = SZMessageSegment.mention(.node(id), display: node.title)
        let ask: String
        switch reason {
        case .sourceMismatch:
            // Fresh audit first — the cached detail is a fallback for a source that cannot be read now.
            let detail = (liveAuditErrors(id) ?? nodeAgentState[id]?.errorDetail).map { ": \(Self.oneLineDetail($0))" } ?? ""
            ask = " is out of step with its contract\(detail). Work out which side is stale — if those ports still "
                + "matter, declare them in the contract again; if they were dropped on purpose, remove the reads. "
                + "Prefer whichever keeps the node's existing behaviour, and say which you chose and why."
        case .contractChanged:
            ask = " has ports its code doesn't implement yet — implement them in Node.swift against the current "
                + "contract, keeping everything that already works."
        case .intentChanged:
            ask = " was re-briefed after it was built — re-implement Node.swift against the node's current "
                + "prompt, keeping its declared ports and everything the new intent doesn't change."
        }
        // The one composer addresses the Director; the node rides in the mention, which is how
        // the triage is told what the ask is about. Scoping this to the node would mean the
        // injection never matched the panel and the draft silently never appeared.
        injectComposerDraft(SZComposerDraft(segments: [mention, .text(ask)]), scope: .director)
    }

    /// One line, bounded, with no trailing terminator (the caller's template supplies the sentence's own) —
    /// shared with the run-end accounting, which quotes the same audit text.
    static func oneLineDetail(_ s: String) -> String {
        var flat = s.split(whereSeparator: \.isNewline).joined(separator: "; ")
        if flat.count > 120 { flat = String(flat.prefix(117)) + "…" }
        while let last = flat.last, last == "." || last == ";" || last == " " { flat.removeLast() }
        return flat
    }
}
