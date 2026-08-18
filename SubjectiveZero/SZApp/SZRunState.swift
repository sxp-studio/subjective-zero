// SPDX-License-Identifier: AGPL-3.0-only
// ONE RUN's state — everything that used to be a singular `run*` field on the host.
//
// - A run is a task that got admitted: it holds a claim over its work set and lives until its
//   traversal concludes. Several can be live at once, so none of this can be host-wide.
// - The claim IS the identity. A cancelled run's task unwinds seconds later as a zombie; it
//   writes into the object it captured, and `SZHost.isLive(_:)` says whether that object is
//   still the registered run — replacing the old `if runClaim == claim` guard at every write.
// - Single-writer: the host and its MCP surface write, the UI reads aggregates off the host.
import Foundation
import SZCore

@MainActor final class SZRunState {
    /// The scheduled task this run is executing.
    let taskID: UUID
    /// Holds the work set's node + transcript pairs and the run's identity. Released at the end.
    let claim: SZClaimToken
    /// The run's TRACE identity, stamped into run-owned turns' events (`SZTraceContext.runID`).
    let traceID = UUID()
    /// The agent-graph record id this run's build traversal leads — its work children share it,
    /// and it is what a narration or a strip row links to.
    let thread = UUID()
    /// The standing instruction every brief carries ("" = none given).
    let instruction: String
    /// Was this run STARTED FOR a staged split/merge? Then it narrates at commit and owns the
    /// hidden-piece UX.
    let ownsGraphOp: Bool
    let startedAt = Date()
    /// The monotonic twin of `startedAt` — durations survive an NTP step mid-run.
    let startedMono = ContinuousClock.now

    /// The nodes this run implements: snapshotted at admission, grown by `noteRunCreatedWork`
    /// as the run's own tooling creates work. The fleet, the editor lock and the `ui_connect`
    /// guard all read it.
    var workSet: Set<SZNodeID>
    /// Nodes `promoteStagedNode` landed for their LATEST dispatch — this run's success evidence.
    /// Cleared per node at each redispatch: a redispatch says the previous build did not settle it.
    var promoted: Set<SZNodeID> = []
    /// This run's finished turns, folded into the run-complete rollup.
    var turnLog: [SZTurnBreakdown.RunTurn] = []
    /// The traversal task, so Stop can cancel exactly this run.
    var task: Task<Void, Never>?

    init(taskID: UUID, claim: SZClaimToken, instruction: String,
         ownsGraphOp: Bool, workSet: Set<SZNodeID>) {
        self.taskID = taskID
        self.claim = claim
        self.instruction = instruction
        self.ownsGraphOp = ownsGraphOp
        self.workSet = workSet
    }
}
