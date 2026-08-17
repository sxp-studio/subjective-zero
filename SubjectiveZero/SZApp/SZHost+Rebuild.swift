// SPDX-License-Identifier: AGPL-3.0-only
// A built node whose contract has moved since that build: classifying WHY, and the one-click way out.
//
// `SZNode.rebuildReason` is DERIVED from evidence, never stored — the build stamp (what the last promote
// compiled against) gives `.contractChanged` / `.intentChanged`; the host's audit of the live source gives
// the one fault state:
//
//   .contractChanged — the contract declares ports the code hasn't implemented yet. Benign; the node draws,
//                      the new ports are inert. The ordinary gap between declaring an interface and building it.
//   .intentChanged   — the prompt moved off the brief the build was written to. Benign, but the fleet must
//                      regenerate against the new intent.
//   .sourceMismatch  — the code names ports the contract no longer declares, so every one of those reads
//                      resolves to nil and the node silently runs on its hardcoded defaults. A real fault:
//                      `agent_compile_node` refuses to promote source in this state.
//
// Classified by CONDITION, not by cause: a port the Director removed and one a human deleted by hand leave the
// node equally broken. Either way the node heals the same two ways: any run picks it up (`runWorkSet` is built
// from `needsImplementation`; a promote re-stamps it), or `stageRebuildFix` composes a message to the node's
// own Coding Agent (never auto-sent — host-drafted messages COMPOSE).
import Foundation
import SZCore
import SZUI

@MainActor
extension SZHost {
    /// Re-audit a node's live source against its contract and set the ephemeral `sourceMismatch` from the
    /// verdict — set when the code names undeclared ports (with the human-readable detail on the pill),
    /// cleared when the audit is clean. Called after a port edit, a promote, a hot reload, and for every
    /// flagged node when a project opens. Never persisted: `SZProjectIO.load` re-derives it.
    func classifyRebuild(node id: SZNodeID) {
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
        injectComposerDraft(SZComposerDraft(segments: [mention, .text(ask)]), scope: .node(id))
    }

    /// One line, bounded, with no trailing terminator (the template supplies the sentence's own).
    private static func oneLineDetail(_ s: String) -> String {
        var flat = s.split(whereSeparator: \.isNewline).joined(separator: "; ")
        if flat.count > 120 { flat = String(flat.prefix(117)) + "…" }
        while let last = flat.last, last == "." || last == ";" || last == " " { flat.removeLast() }
        return flat
    }
}
