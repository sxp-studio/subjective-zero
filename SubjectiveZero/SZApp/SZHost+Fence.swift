// SPDX-License-Identifier: AGPL-3.0-only
// The mutation fence — ENFORCEMENT of the locks the view layer only affords. The lock icon and
// disabled inputs live in SwiftUI predicates; before this fence, every `ui_*` MCP graph edit (and
// any host caller that forgot the view-side filter) reached the unconditional store ops and could
// delete or re-port a node whose agent was mid-chat or mid-split/merge. The fence is the ONE
// authoritative check, consulted at the host mutation funnels (delete, the connection trio, input
// defaults, display, node body, split/merge targets) and by the MCP handlers for their refusal
// messages; SZStore's `fenceBackstop` debug-assert catches future callers that bypass the funnels.
//
// Two mutation classes, per-operation — never a blanket node lock:
// - FENCED (this file's concern): delete, connect/disconnect/reconnect, port edits, content
//   updates, input defaults, display toggle, node body, split/merge target.
// - OPEN by documented design: move/tidy (a locked node stays repositionable —
//   SZNodeCanvasContentView) and add (a new node can't be held by anyone).
import Foundation
import SZCore

extension SZHost {
    /// Who is asking for a mutation. `.agent` is the MCP `ui_*` surface (the Director / the fleet —
    /// a raw TCP connection carries no finer identity); `.user` is the editor UI and host-internal
    /// user actions. The one rule difference: an agent may mutate nodes the RUN holds (steering its
    /// own fleet's work is the run's whole point); a user may not (those cards are locked).
    enum SZMutationOrigin { case user, agent }

    /// The authoritative lock check for fenced mutations. Returns a human refusal naming the
    /// holder, or nil when the mutation may proceed. Checks the ledger's `.node` claims (a chat
    /// turn holds its node; a run holds its work set) plus the staged-graph-op flags (the originals
    /// of an in-flight split/merge must stay untouched until it settles).
    func fenceDenial(nodes: some Sequence<SZNodeID>, origin: SZMutationOrigin) -> String? {
        for id in nodes {
            let title = store.project?.graph.node(id: id)?.title ?? String(id.uuidString.prefix(8))
            if let op = graphOpStatus[id] {
                return "node '\(title)' is mid-\(op.lowercased()) — the operation settles when its run ends (or Stop the run)"
            }
            guard let holder = ledger.holder(of: .node(id)) else { continue }
            if origin == .agent, let runClaim, holder == runClaim { continue }
            return "node '\(title)' is held by \(holder.label) — wait for it to finish or stop it"
        }
        return nil
    }

    /// Endpoint node ids of a connection — what wiring mutations are fenced on.
    func connectionEndpoints(_ id: SZConnectionID) -> [SZNodeID] {
        guard let c = store.project?.graph.connections.first(where: { $0.id == id }) else { return [] }
        return [c.from.node, c.to.node]
    }

    /// Install the store's debug tripwire: a fenced-class store mutation on a node held by a claim
    /// that is neither the run's nor the graph-op path's should have been refused at a funnel —
    /// assert-fail in debug so a future bypass is caught in development, never enforced in release
    /// (store ops stay non-throwing). Called once at start.
    func installStoreFenceBackstop() {
        store.fenceBackstop = { [weak self] ids in
            guard let self else { return nil }
            for id in ids {
                guard let holder = self.ledger.holder(of: .node(id)) else { continue }
                if holder == self.runClaim { continue }       // the run mutates its own work set
                if holder == self.graphOpClaim { continue }   // op machinery settles its own staging
                return "node \(id.uuidString.prefix(8)) is held by \(holder.label)"
            }
            return nil
        }
    }

    // MARK: - Graph-op slot claim

    /// Claim the single staged split/merge slot for the op's lifetime — `hasStagedGraphOp` stays
    /// the API; this makes the slot ledger-visible (blocks project ops via `anyHeld`, shows up in
    /// wait-graph diagnostics). The originals themselves are guarded by `graphOpStatus` in the
    /// fence, not claimed — mid-run they are typically already held by the run's claim.
    func claimGraphOpSlot(label: String) {
        let token = SZClaimToken(label: label)
        let claimed = ledger.tryAcquire([.graphOp], as: token)
        assert(claimed, "graph-op slot contended — hasStagedGraphOp guard should have refused")
        graphOpClaim = token
    }

    /// Idempotent — reached from both a run's drain and a failed `startOrJoinRun` rollback.
    func releaseGraphOpSlot() {
        guard let claim = graphOpClaim else { return }
        ledger.releaseAll(of: claim)
        graphOpClaim = nil
    }
}
