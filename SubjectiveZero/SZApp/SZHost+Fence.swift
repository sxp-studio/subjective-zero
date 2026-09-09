// SPDX-License-Identifier: AGPL-3.0-only
// The mutation fence — enforcement of the locks the view layer only affords. The lock icon and
// disabled inputs are only SwiftUI predicates; before this fence, every `ui_*` MCP graph edit (and
// any host caller that forgot the view-side filter) reached the unconditional store ops and could
// delete or re-port a node whose agent was mid-chat or mid-split/merge. The fence is the one
// authoritative check, consulted at the host mutation funnels and by the MCP handlers for their
// refusal messages; SZStore's `fenceBackstop` debug-assert catches future callers that bypass the
// funnels, but is origin-blind and therefore weaker (see `installStoreFenceBackstop`).
//
// Two mutation classes, per-operation — never a blanket node lock:
// - Fenced (this file's concern): delete, connect/disconnect/reconnect, port edits, content
//   updates, input defaults, display toggle, node body, split/merge target.
// - Open by documented design: move/tidy (a locked node stays repositionable —
//   SZNodeCanvasContentView), add (a new node can't be held by anyone), and an agent's flow
//   arrow (drawing intent for a wire it could not lay; `SZHost.addConnection`).
// Delete is fenced one notch tighter (`deleteDenial`): a node the fleet is still implementing
// keeps its card live but cannot be removed, because there is no undo.
import Foundation
import SZCore

/// The tool call's caller, bound task-locally by `SZHostBridge.callTool` for the duration of one
/// dispatch — same idiom as `SZTrace.context`. A per-turn agent listener knows whose turn it serves
/// (its port is the identity) and carries that turn's claim token; the shared buses carry nil.
/// The fence and the store backstop read it to tell "the turn mutating its own held node" from a
/// bystander on the same origin.
enum SZToolCaller {
    @TaskLocal static var claim: SZClaimToken?
    /// The calling turn's chat scope — bound alongside `claim` by the per-turn listener. Tells a
    /// Coding Agent's turn from the Director's under one shared run claim (the mutation journal's
    /// actor); nil on the standing buses.
    @TaskLocal static var scope: SZChatScope?
}

extension SZHost {
    /// Who is asking for a mutation. `.agent` is the MCP `ui_*` surface (the Director / the fleet;
    /// the caller, when a per-turn listener carries it, is `SZToolCaller.claim`); `.user` is the
    /// editor UI and host-internal user actions. The rule differences: an agent may mutate nodes
    /// the run holds (steering its own fleet's work is the run's whole point) and nodes its own
    /// turn holds; a user may not (those cards are locked).
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
            if origin == .agent {
                // The caller's run, never "any live run": with runs concurrent, a holder-side
                // check let one run's Director delete, rewire and re-port nodes another run was
                // mid-implementing. A turn may touch what its own run holds, and nothing else.
                if let caller = SZToolCaller.claim {
                    if holder == caller { continue }               // the caller's own turn
                    if holder == activeRun(for: caller)?.claim { continue }   // its own run's work
                }
                // A run's own fleet work, when the caller is the run (no per-turn token bound).
                if SZToolCaller.claim == nil, isRunClaim(holder) { continue }
            }
            if origin == .user, !userLockDenies(holder: holder, node: id) { continue }
            // Two readers, two remedies. A user can wait and can press Stop; an agent turn can do
            // neither, so telling it to wait buys a promise the turn cannot keep. A wire it could
            // not lay is drawn as a flow arrow; words about the node's code go to its build.
            return origin == .agent
                ? "node '\(title)' is being built by another request. Draw a wire as a flow arrow "
                    + "(ui_connect kind flow, both ports named); send words about its code with "
                    + "ui_send_chat; then leave the node alone."
                : "node '\(title)' is held by \(holder.label) — wait for it to finish or stop it"
        }
        return nil
    }

    /// The user-lock rule, stated once — shared by `fenceDenial` (enforcement) and `lockedNodes`
    /// (the canvas/panel affordance), so what the UI dims and what the fence refuses cannot drift.
    ///
    /// The card greys only when there is nothing on it to work: a node with no build yet, being written
    /// for the first time. A node that renders stays the user's — its knobs, wires, position and viewport
    /// toggle — no matter who holds it or what they are doing to its source. Who holds it decides whether
    /// it can be deleted (`deleteDenies`), not whether it can be touched: the two questions used to be one,
    /// which is why a node with a chat open froze while it was still making pixels.
    private func userLockDenies(holder _: SZClaimToken, node id: SZNodeID) -> Bool {
        store.project?.graph.node(id: id)?.kind != .generated
    }

    /// A user delete is refused while an agent is actually working this node — losing that work to a
    /// keystroke is unrecoverable, there being no undo. "Actually working" reads differently per holder:
    /// a per-turn claim (a node chat) exists only for the length of its turn, so holding it is the work;
    /// a run holds its whole work set to run end, so there the work is the node still needing
    /// implementation, and the hold releases at that node's own promote rather than at the run's end.
    private func deleteDenies(holder: SZClaimToken, node id: SZNodeID) -> Bool {
        if userLockDenies(holder: holder, node: id) { return true }   // no build to lose yet
        guard isRunClaim(holder) else { return true }                 // a turn's claim IS its work
        return store.project?.graph.node(id: id)?.needsImplementation ?? false
    }

    /// The delete fence: never looser than `fenceDenial`, and additionally holds a node the fleet is
    /// still implementing. Called by the delete funnel in place of `fenceDenial`.
    func deleteDenial(nodes: some Sequence<SZNodeID>, origin: SZMutationOrigin) -> String? {
        // Materialized once: this reads the ids twice, and a single-pass sequence would arrive empty
        // for the second read and wave the delete through.
        let ids = Array(nodes)
        if let denial = fenceDenial(nodes: ids, origin: origin) { return denial }
        guard origin == .user else { return nil }
        for id in ids {
            guard let holder = ledger.holder(of: .node(id)), deleteDenies(holder: holder, node: id) else { continue }
            let title = store.project?.graph.node(id: id)?.title ?? String(id.uuidString.prefix(8))
            return "node '\(title)' is being rebuilt. Stop the run to delete it."
        }
        return nil
    }

    /// Node ids the user cannot delete right now — the padlock badge's source. A superset of
    /// `lockedNodes`: a rebuilding card wears the lock (it cannot be deleted) while staying editable.
    var deleteHeldNodes: Set<SZNodeID> { heldNodes(deleteDenies(holder:node:)) }

    /// The ledger's node claims filtered by one refusal rule — the single loop behind both affordance
    /// sets, so they cannot drift apart in how they read the ledger.
    private func heldNodes(_ denies: (SZClaimToken, SZNodeID) -> Bool) -> Set<SZNodeID> {
        var held: Set<SZNodeID> = []
        for (resource, holder) in ledger.holders {
            guard let id = resource.nodeID, denies(holder, id) else { continue }
            held.insert(id)
        }
        return held
    }

    /// Node ids a user-origin mutation would be refused on right now — the ledger-backed source for
    /// the canvas/panel lock affordances (`SZNodeCanvasContentView.isLocked`), derived through the
    /// same `userLockDenies` predicate the fence enforces. (Mid-split/merge originals are covered
    /// by `graphOpStatus`, which the view checks alongside this.)
    var lockedNodes: Set<SZNodeID> { heldNodes(userLockDenies(holder:node:)) }

    /// Endpoint node ids of a connection — what wiring mutations are fenced on.
    func connectionEndpoints(_ id: SZConnectionID) -> [SZNodeID] {
        guard let c = store.project?.graph.connections.first(where: { $0.id == id }) else { return [] }
        return [c.from.node, c.to.node]
    }

    /// Install the store's debug tripwire: a fenced-class store mutation on a node held by a claim
    /// that is neither the run's nor the graph-op path's should have been refused at a funnel, so
    /// assert-fail in debug to catch a future bypass; never enforced in release (store ops stay
    /// non-throwing). Called once at start.
    ///
    /// Deliberately origin-blind, and therefore strictly weaker than `fenceDenial` — do not "tighten"
    /// it to `userLockDenies`. A store op carries no `SZMutationOrigin`, so the backstop can only
    /// catch what no origin would permit; the agent rule is the permissive one, hence the `isRunClaim`
    /// and caller skips (the caller's identity does reach here — `SZToolCaller` rides the tool call's
    /// stack into the store op). The user rule would assert-fail on the fleet's own legitimate writes:
    /// a run holds its work set, and a coding agent's `ui_update_node` lands on a node that is still
    /// `kind == .prompt` until it compiles and promotes. That rule is enforced where it can see
    /// origin — at the funnels (`updateNodeContent`, `setInputDefault`, `toggleDisplay`, the
    /// connection trio, …).
    func installStoreFenceBackstop() {
        store.fenceBackstop = { [weak self] ids in
            guard let self else { return nil }
            for id in ids {
                guard let holder = self.ledger.holder(of: .node(id)) else { continue }
                if self.isRunClaim(holder) { continue }       // a run mutates its own work set
                if holder == self.graphOpClaim { continue }   // op machinery settles its own staging
                if holder == SZToolCaller.claim { continue }  // the caller's own turn — the agent
                                                              // rule the fence permits (task-local
                                                              // rides into the store op's stack)
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
