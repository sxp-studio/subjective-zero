// SPDX-License-Identifier: AGPL-3.0-only
// Split / merge graph operations — the `ui_split_node` / `ui_merge_nodes` entry points and the
// editor's Split / Merge Selected, plus their deferred-commit machinery. A split/merge STAGES the new
// pieces (hidden, wired, drafted contracts + seed prompts carrying the original source) while the
// originals keep rendering with a transient pill, dispatches the Director to implement them via a run,
// then COMMITS the structural swap once they're built — or rolls back if a piece failed.
//
// Transcript policy: nodes REMOVED by these ops (the original on commitSplit, the constituents on
// commitMerge, the staged pieces on rollback, and the run:false structural variants) get the same
// chat purge as a delete (`purgeChatArtifacts`) — ids are never reused, so a kept transcript would
// be unreachable in the UI, and the Director transcript already narrates the operation.
import Foundation
import SZAI
import SZCore

extension SZHost {
    // MARK: - Split / merge

    /// Split a node into `pieces` (≥2) data-connected stages (the `ui_split_node` entry point + the
    /// editor's Split). Deferred-commit UX when `run`: STAGE the hidden stage nodes (internal wiring +
    /// drafted boundary contracts + seed prompts carrying the original's source) while the original keeps
    /// rendering with a "Splitting" pill, dispatch the Director to implement them, then COMMIT — rewire
    /// the original's external edges to the stages, move the render endpoint, remove the original, reveal
    /// the finished cards. With `run:false` it applies the full structural split immediately (drafts
    /// visible) for the Director/tests. `instruction` is the user's steer for this split, woven into every
    /// stage's seed prompt. Returns the new piece ids, or nil if rejected.
    @discardableResult
    func splitNode(id: SZNodeID, pieces: Int = 2, run: Bool = true, instruction: String? = nil) -> [SZNodeID]? {
        // A staged op is drained by ONE run; a second would share the `hiddenPieces` bag and be rolled back
        // with the first. Refuse rather than corrupt (the caller surfaces the reason).
        guard !(run && hasStagedGraphOp) else { return nil }
        // The fence: never split a node another activity holds (mid-chat, another op's original).
        if let denial = fenceDenial(nodes: [id], origin: .agent) { status = denial; return nil }
        guard let original = store.project?.graph.node(id: id) else { return nil }
        let title = original.title
        // The node's PURPOSE, not its seed prompt: prefer the contract summary (terse, stable) so
        // splitting a freshly-seeded node doesn't nest one seed prompt inside another.
        let intent = original.contract?.summary ?? original.prompt ?? original.title
        let source = nodeSource(id)   // the real code to divide — captured before the structural edit

        let staged = run ? store.project?.graph.stageSplit(node: id, into: pieces)
                         : store.project?.graph.split(node: id, into: pieces)
        guard let staged, let firstPiece = staged.pieceIDs.first else { return nil }
        store.mutate { $0.graph = staged.graph }
        let pieceIDs = staged.pieceIDs
        seedSplitPrompts(pieceIDs, original: title, intent: intent, source: source, instruction: instruction)
        _ = firstPiece

        if run {
            graphOpStatus[id] = "Splitting"                 // the original stays, flagged
            hiddenPieces.formUnion(pieceIDs)                // the stages stay hidden until commit
            pendingGraphOp = .split(original: id, pieces: pieceIDs, title: title)
            claimGraphOpSlot(label: "split of '\(title)'")
            persistGraphEditAndReload(action: "splitting \(title)…")
            narrateDirector("Splitting \(title) into \(pieceIDs.count) stages…")
        }
        // The new pieces are the fleet's work, so they join the run's work set — else the dispatch filter
        // would silently skip them. No-op off-run (the run below captures them at its start).
        noteRunCreatedWork(Set(pieceIDs))

        if run {
            // START a run, or JOIN the one already in flight. Staging begins no run of its own, so a
            // Director splitting mid-turn does NOT nest a run — the run it is already inside drains this op.
            guard startOrJoinRun(rollbackReason: "split of \(title) cancelled") else { return nil }
        } else {
            purgeChatArtifacts(for: [id])   // the structural split removed the original immediately
            persistGraphEditAndReload(action: "split \(title) into \(pieceIDs.count)")
        }
        return pieceIDs
    }

    /// Commit a staged split once the Director has implemented the stages: swap the original out for the
    /// finished stages (external rewire + endpoint move + remove original) and reveal them. If a stage
    /// didn't reach `generated`, leave the staged graph in place (the user keeps the flagged original).
    private func commitSplit(original id: SZNodeID, pieces: [SZNodeID], title: String) {
        guard pieces.allSatisfy({ store.project?.graph.node(id: $0)?.kind == .generated }) else {
            rollbackGraphOp(reason: "split of \(title) cancelled"); return   // cancelled / a stage failed
        }
        store.mutate { project in
            if let g = project.graph.commitSplit(original: id, pieces: pieces) { project.graph = g }
        }
        graphOpStatus[id] = nil
        hiddenPieces.subtract(pieces)
        for pid in pieces { pinnedContracts[pid] = nil; dispatchPrompts[pid] = nil }
        purgeChatArtifacts(for: [id])   // the original left the graph — drop its transcript (see header)
        narrateDirector("Split of \(title) complete.")
        persistGraphEditAndReload(action: "split \(title) complete")
    }

    /// Merge an adjacent, data-connected linear chain into one node (the `ui_merge_nodes` entry point +
    /// the editor's Merge Selected). Deferred-commit UX when `run`: STAGE the hidden merged node (drafted
    /// boundary contract + a seed prompt carrying every constituent's source) while the originals keep
    /// rendering with a "Merging" pill, dispatch the Director, then COMMIT — rewire externals to the
    /// merged node, drop internal edges, move the endpoint, remove the constituents, reveal the result.
    /// With `run:false` it applies the full structural merge immediately. `instruction` is the user's steer
    /// for this merge, woven into the merged node's seed prompt. Returns the merged id, or nil.
    @discardableResult
    func mergeNodes(ids: [SZNodeID], run: Bool = true, instruction: String? = nil) -> SZNodeID? {
        guard !(run && hasStagedGraphOp) else { return nil }   // one staged op at a time — see `splitNode`
        if let denial = fenceDenial(nodes: ids, origin: .agent) { status = denial; return nil }
        // Capture each constituent's purpose + real source BEFORE the edit, so the agent fuses real code.
        let constituents = ids.compactMap { store.project?.graph.node(id: $0) }
            .map { (title: $0.title, intent: $0.contract?.summary ?? $0.prompt ?? $0.title, source: nodeSource($0.id)) }

        let staged = run ? store.project?.graph.stageMerge(nodes: ids)
                         : store.project?.graph.merge(nodes: ids)
        guard let staged else { return nil }
        store.mutate { $0.graph = staged.graph }
        let mergedID = staged.mergedID
        if let contract = store.project?.graph.node(id: mergedID)?.contract {
            store.updateNode(id: mergedID, prompt: SZGraphPrompts.merge(
                constituents: constituents, contract: contract, instruction: instruction))
        }

        if run {
            for cid in ids { graphOpStatus[cid] = "Merging" }   // the constituents stay, flagged
            hiddenPieces.insert(mergedID)                        // the merged node stays hidden until commit
            pendingGraphOp = .merge(constituents: ids, merged: mergedID)
            claimGraphOpSlot(label: "merge of \(ids.count) nodes")
            persistGraphEditAndReload(action: "merging \(constituents.count) nodes…")
            narrateDirector("Merging \(constituents.map(\.title).joined(separator: " + ")) into one node…")
        }
        noteRunCreatedWork([mergedID])   // the merged node is the fleet's work (no-op off-run)

        if run {
            guard startOrJoinRun(rollbackReason: "merge cancelled") else { return nil }
        } else {
            purgeChatArtifacts(for: ids)   // the structural merge removed the constituents immediately
            persistGraphEditAndReload(action: "merged \(constituents.count) nodes")
        }
        return mergedID
    }

    /// Commit a staged merge once the Director has implemented the merged node: swap the constituents out
    /// for the finished merged node and reveal it. If it didn't reach `generated`, leave the staged graph.
    private func commitMerge(constituents ids: [SZNodeID], merged: SZNodeID) {
        guard store.project?.graph.node(id: merged)?.kind == .generated else {
            rollbackGraphOp(reason: "merge cancelled"); return   // cancelled / the merged node failed
        }
        store.mutate { project in
            if let g = project.graph.commitMerge(constituents: ids, merged: merged) { project.graph = g }
        }
        for cid in ids { graphOpStatus[cid] = nil }
        hiddenPieces.remove(merged)
        pinnedContracts[merged] = nil
        dispatchPrompts[merged] = nil
        purgeChatArtifacts(for: ids)   // the constituents left the graph — drop their transcripts (see header)
        narrateDirector("Merge complete.")
        persistGraphEditAndReload(action: "merge complete")
    }

    /// Ensure a run exists to implement the op we just staged. If one is already in flight (the Director
    /// restructuring inside its own turn) we JOIN it — its tail drains our op — rather than starting a
    /// nested run, which `startRun` would refuse anyway. Off-run we start one.
    ///
    /// `startRun` early-returns when the provider isn't ready or the MCP port/project is missing. That would
    /// strand the op: staged pieces nobody implements, a "Splitting" pill that never clears, and — because
    /// `graphOpStatus` drives `activeScopeLocked` — a node chat composer locked forever with no recovery.
    /// Roll back instead. Returns false when the op was rolled back and the caller should report failure.
    private func startOrJoinRun(rollbackReason: String) -> Bool {
        if isRunning { return true }        // join: the in-flight run's tail will drain `pendingGraphOp`
        startRun()
        guard isRunning else { rollbackGraphOp(reason: "\(rollbackReason) — the run could not start"); return false }
        return true
    }

    /// Settle the staged split/merge at the end of the run that was implementing it — the counterpart of
    /// staging, called from `startRun`'s task tail on success, throw AND cancel. `commitSplit`/`commitMerge`
    /// each guard on every piece having reached `.generated`, so an unbuilt or cancelled op rolls back to the
    /// exact pre-split graph. Nothing else drains this: a graph op outlives neither its run nor a project switch.
    func drainPendingGraphOp() {
        guard let op = pendingGraphOp else { return }
        pendingGraphOp = nil
        releaseGraphOpSlot()   // the op settles below (commit or its internal rollback)
        switch op {
        case .split(let original, let pieces, let title):
            commitSplit(original: original, pieces: pieces, title: title)
        case .merge(let constituents, let merged):
            commitMerge(constituents: constituents, merged: merged)
        }
    }

    /// Undo an in-flight split/merge (Cancel, or a piece that failed to build): remove the staged pieces
    /// (+ their edges) and clear the flags. Staging only ADDED nodes — the originals were never modified
    /// — so dropping the pieces restores the pre-op graph exactly, with the originals still wired/rendering.
    private func rollbackGraphOp(reason: String) {
        let pieces = hiddenPieces
        // Reached both from a run's drain (op already taken) and from `startOrJoinRun` when no run could
        // start (op still staged) — clear it either way, or the next split is refused by a ghost.
        pendingGraphOp = nil
        releaseGraphOpSlot()   // idempotent (the drain may have released already)
        // Clear the op flags even on this early-out: `graphOpStatus` now drives `activeScopeLocked`,
        // so a stale entry (pieces emptied out-of-band) would permanently lock that node's composer
        // with no Stop and no recovery.
        guard !pieces.isEmpty else { status = reason; graphOpStatus = [:]; return }
        store.mutate { project in
            project.graph.nodes.removeAll { pieces.contains($0.id) }
            project.graph.connections.removeAll { pieces.contains($0.from.node) || pieces.contains($0.to.node) }
        }
        graphOpStatus = [:]
        hiddenPieces = []
        pinnedContracts = [:]
        dispatchPrompts = [:]
        purgeChatArtifacts(for: pieces)   // the staged pieces' coding-agent transcripts are orphans now
        narrateDirector(reason.prefix(1).capitalized + reason.dropFirst() + ".")
        persistGraphEditAndReload(action: reason)
    }

    /// Author each split stage's seed prompt from the SZAI template (SZCore stays prose-free). Every stage
    /// gets the same `instruction`, so they divide the work along the seam the user actually asked for.
    private func seedSplitPrompts(_ pieceIDs: [SZNodeID], original: String, intent: String,
                                  source: String?, instruction: String?) {
        for (k, pid) in pieceIDs.enumerated() {
            guard let contract = store.project?.graph.node(id: pid)?.contract else { continue }
            store.updateNode(id: pid, prompt: SZGraphPrompts.splitStage(
                original: original, intent: intent, stage: k + 1, count: pieceIDs.count,
                source: source, contract: contract, instruction: instruction))
        }
    }

    /// Read a node's current `Node.swift` source from disk (nil if it has none — an un-implemented node).
    private func nodeSource(_ id: SZNodeID) -> String? {
        guard let url = loadedProjectURL else { return nil }
        return try? String(contentsOf: SZProjectIO.nodeSourceURL(projectURL: url, nodeID: id), encoding: .utf8)
    }
}
