// SPDX-License-Identifier: AGPL-3.0-only
// The run-end verdict for one work-set node — the pure decision the host's accounting applies.
//
// - Success is keyed on EVIDENCE: a promote that happened during the run + the node's derived state now.
//   A stale flag or a phase an agent forgot to update can no longer turn a green build into "0 implemented".
// - "Built, then moved": a promote followed by a prompt/contract edit is an implemented node that needs another
//   pass — narrated as such, never a failure.
// - An AGENT that reported a real problem (`.error` / `.needsInput`) always wins, even over a clean build:
//   it is the only party that can judge its own work ("it compiles, but it renders black"). Bad news the HOST
//   wrote on its behalf — a provider that died, a spent turn budget — says nothing about what was built, so a
//   node that promoted clean stays implemented.
// - Only a node with NO promote and NO explanation gets the generic "never compiled" line.
import Foundation

public enum SZRunNodeVerdict: Equatable, Sendable {
    /// Promoted this run (or already current): counts as implemented, nothing to say.
    case implemented
    /// Promoted, but the prompt moved off the brief the build was written to — implemented + narrate.
    case implementedButRebriefed
    /// Promoted, but the contract's ports moved after the build — implemented + narrate.
    case implementedButContractMoved
    /// Promoted, yet the live source disagrees with the contract — failed; the audit text is the detail.
    case failedSourceMismatch
    /// The agent reported `.error` / `.needsInput` itself — failed; keep its own message untouched.
    case failedAsReported
    /// Promoted this run, yet the node reports a fault at render (`ctx.reportError`, a shader that
    /// failed at first frame) — failed; the node's own words are the detail.
    case failedRuntimeFault
    /// Nothing happened: no promote, no agent explanation — failed with whatever reason the run holds.
    case failedSilently

    /// Counted as implemented in the run summary.
    public var isImplemented: Bool {
        switch self {
        case .implemented, .implementedButRebriefed, .implementedButContractMoved: return true
        case .failedSourceMismatch, .failedAsReported, .failedRuntimeFault, .failedSilently: return false
        }
    }

    /// - node: the work-set node as it stands NOW (`needsImplementation` / `rebuildReason` are derived).
    /// - promoted: `promoteStagedNode` ran for the node during THIS dispatch.
    /// - state: the node's agent state now — its phase and WHO wrote it.
    /// - runtimeFault: what the node reports at render, when the caller judges this run made that build.
    public static func classify(node: SZNode, promoted: Bool,
                                state: SZNodeAgentState?, runtimeFault: String? = nil) -> SZRunNodeVerdict {
        let stillDirty = node.needsImplementation
        // The promoted source disagrees with the contract: a real defect in what landed.
        if promoted, stillDirty, node.rebuildReason == .sourceMismatch { return .failedSourceMismatch }
        // The agent's own report — newer than the build it followed (a promote clears a stale one), and
        // the only judgement that beats a clean stamp. A host-written `.error` is not one of these.
        if state?.reportedProblem == true { return .failedAsReported }
        // The build landed and the node says at render that it does not work.
        if runtimeFault != nil { return .failedRuntimeFault }
        // Clean now = nothing left to do, whether this run's promote or an edit that healed it got it there.
        if !stillDirty { return .implemented }
        if promoted, node.rebuildReason == .intentChanged { return .implementedButRebriefed }
        if promoted, node.rebuildReason == .contractChanged { return .implementedButContractMoved }
        return .failedSilently
    }
}
