// SPDX-License-Identifier: AGPL-3.0-only
// The run-end verdict for one work-set node — the pure decision the host's accounting applies.
//
// - Success is keyed on EVIDENCE: a promote that happened during the run + the node's derived state now.
//   A stale flag or a phase an agent forgot to update can no longer turn a green build into "0 implemented".
// - "Built, then moved": a promote followed by a prompt/contract edit is an implemented node that needs another
//   pass — narrated as such, never a failure.
// - An agent that reported a real problem (`.error` / `.needsInput`) always wins — even over a clean build:
//   a promote clears a stale report, so one still standing came AFTER the compile. Its own words stand.
// - Only a node with NO promote and NO explanation gets the generic "never compiled" line.
import Foundation

public enum SZRunNodeVerdict: Equatable, Sendable {
    /// Promoted this run (or already current): counts as implemented, nothing to say.
    case implemented
    /// Promoted, but the prompt moved off the brief the build was written to — implemented + narrate.
    case implementedButRebriefed
    /// Promoted, but the contract's ports moved after the build — implemented + narrate.
    case implementedButContractMoved
    /// Promoted, yet the live source names ports the contract does not declare — failed; the audit text is the detail.
    case failedSourceMismatch
    /// The agent reported `.error` / `.needsInput` itself — failed; keep its own message untouched.
    case failedAsReported
    /// Nothing happened: no promote, no explanation — failed with the generic line.
    case failedSilently

    /// Counted as implemented in the run summary.
    public var isImplemented: Bool {
        switch self {
        case .implemented, .implementedButRebriefed, .implementedButContractMoved: return true
        case .failedSourceMismatch, .failedAsReported, .failedSilently: return false
        }
    }

    /// - promoted: `promoteStagedNode` ran for the node during THIS run.
    /// - stillDirty: `SZNode.needsImplementation` now. - derivedReason: `SZNode.rebuildReason` now.
    /// - phase: the node's agent phase now.
    public static func classify(promoted: Bool, stillDirty: Bool, derivedReason: SZRebuildReason?,
                                phase: SZNodeAgentPhase) -> SZRunNodeVerdict {
        let reported = phase == .error || phase == .needsInput
        // The promoted source names ports the contract doesn't declare: a real defect in what landed.
        if promoted, stillDirty, derivedReason == .sourceMismatch { return .failedSourceMismatch }
        // A promote demotes a stale `.error`/`.needsInput`, so a report STILL standing is newer than the
        // build it followed ("it compiles, but it renders black"): the agent's own word beats a clean stamp.
        if reported { return .failedAsReported }
        // Clean now = nothing left to do, whether this run's promote or an edit that healed it got it there.
        if !stillDirty { return .implemented }
        if promoted, derivedReason == .intentChanged { return .implementedButRebriefed }
        if promoted, derivedReason == .contractChanged { return .implementedButContractMoved }
        return .failedSilently
    }
}
