// SPDX-License-Identifier: AGPL-3.0-only
// A built node whose contract has moved since that build: classifying WHY, and the one-click way out.
//
// `SZStore.editPorts` knows a port surface changed but cannot read `Node.swift` (SZCore stays off disk for
// graph edits), so it records the optimistic `.contractChanged`. Only the host can open the source and tell
// the two conditions apart:
//
//   .contractChanged — the contract declares ports the code hasn't implemented yet. Benign; the node draws,
//                      the new ports are inert. The ordinary gap between declaring an interface and building it.
//   .sourceMismatch  — the code names ports the contract no longer declares, so every one of those reads
//                      resolves to nil and the node silently runs on its hardcoded defaults. A real fault:
//                      `agent_compile_node` refuses to promote source in this state.
//
// Classified by CONDITION, not by cause: a port the Director removed and one a human deleted by hand leave the
// node equally broken.
//
// Either way the node heals the same two ways, and both are guaranteed by construction:
//   1. any run picks it up — `runWorkSet` is built from `needsImplementation`, and `promoteStagedNode` is the
//      one place the reason is cleared;
//   2. `stageRebuildFix` composes a message to the node's own Coding Agent (never auto-sent — the V1 ruling
//      that host-drafted messages COMPOSE), whose cold start seeds it with the current contract + source.
import Foundation
import SZCore
import SZUI

@MainActor
extension SZHost {
    /// Re-read a node's live source and record why (or whether) it needs a rebuild. Called after any port edit,
    /// and for every built node when a project opens.
    ///
    /// A node the store already flagged `.contractChanged` is only ever *upgraded* to `.sourceMismatch`, never
    /// cleared: the "contract declares a port the code ignores" half is invisible to a static scan (the audit is
    /// a string-literal scan, and `NodeLibrary/audio-bands` builds port names at runtime), so absence of errors
    /// does not mean the code is current. Only `promoteStagedNode` clears a reason.
    func classifyRebuild(node id: SZNodeID) {
        guard let projectURL = loadedProjectURL,
              let node = store.project?.graph.node(id: id), node.kind == .generated,
              let contract = node.contract else { return }
        guard let source = try? String(contentsOf: SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: id),
                                       encoding: .utf8) else { return }

        let audit = SZPortBindingAudit.audit(contract: contract, source: source)
        if !audit.errors.isEmpty {
            store.setRebuildReason(node: id, .sourceMismatch)
            // Reuse the node's existing error surface: the pill becomes the clickable diagnostic popover.
            nodeAgentState[id, default: SZNodeAgentState()].errorDetail = audit.errors.joined(separator: "\n")
        } else if node.rebuildReason == .sourceMismatch {
            // The fault was repaired without a promote (a hand edit). Fall back to the weaker claim rather than
            // declaring the node current — the scan cannot prove that.
            store.setRebuildReason(node: id, .contractChanged)
            nodeAgentState[id]?.errorDetail = nil
        }
    }

    /// Classify every built node after a project loads. `SZProjectIO.load` already set `.sourceMismatch` from the
    /// same audit; this second pass exists to attach the human-readable diagnostic, which the model doesn't carry.
    func classifyRebuildsAfterLoad() {
        for node in store.project?.graph.nodes ?? [] where node.rebuildReason == .sourceMismatch {
            classifyRebuild(node: node.id)
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
            let detail = nodeAgentState[id]?.errorDetail.map { " \(Self.oneLineDetail($0))" } ?? ""
            ask = " is out of step with its contract:\(detail) Work out which side is stale — if those ports still "
                + "matter, declare them in the contract again; if they were dropped on purpose, remove the reads. "
                + "Prefer whichever keeps the node's existing behaviour, and say which you chose and why."
        case .contractChanged:
            ask = " has ports its code doesn't implement yet — implement them in Node.swift against the current "
                + "contract, keeping everything that already works."
        }
        injectComposerDraft(SZComposerDraft(segments: [mention, .text(ask)]), scope: .node(id))
    }

    private static func oneLineDetail(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: "; ")
        return flat.count > 120 ? String(flat.prefix(117)) + "…" : flat
    }
}
