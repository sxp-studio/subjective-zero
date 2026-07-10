// SPDX-License-Identifier: AGPL-3.0-only
// The node-card lock + pill derivation (SZNodeCanvasContentView). Mid-run a prompt node in the run's
// captured WORK SET is the fleet's work — locked and shown Coding. A prompt node NOT in the set (e.g. a
// draft the user dropped on the canvas during the run) stays editable and reads Draft.
import Testing
@testable import SZUI
import SZCore

@Suite struct SZPillStatusTests {
    private func node(_ id: SZNodeID = SZNodeID(), kind: SZNodeKind = .prompt) -> SZNode {
        SZNode(id: id, kind: kind, title: "N", prompt: "make it wobble", position: SZPoint(x: 0, y: 0))
    }

    // MARK: pillStatus

    /// A prompt node in the work set reads Coding mid-run while it waits for its agent to report.
    @Test func workSetNodeReadsCodingDuringRun() {
        let n = node()
        #expect(SZNodeCanvasContentView.pillStatus(for: n, agentState: [:], ops: [:], isRunning: true,
                                                   workSet: [n.id]) == .building)
    }

    /// A prompt node NOT in the work set (a user's mid-run draft) reads Draft, not Coding.
    @Test func nonWorkNodeReadsDraftDuringRun() {
        let n = node()
        #expect(SZNodeCanvasContentView.pillStatus(for: n, agentState: [:], ops: [:], isRunning: true,
                                                   workSet: []) == .draft)
    }

    /// An explicit agent phase still wins over the run-wide fallback, even for a non-work node (defensive).
    @Test func explicitCodingPhaseWinsOverWorkSet() {
        let n = node()
        let coding = [n.id: SZNodeAgentState(phase: .coding)]
        #expect(SZNodeCanvasContentView.pillStatus(for: n, agentState: coding, ops: [:], isRunning: true,
                                                   workSet: []) == .building)
    }

    /// Outside a run every prompt node is a Draft regardless of the set.
    @Test func promptNodeIsDraftWhenNotRunning() {
        let n = node()
        #expect(SZNodeCanvasContentView.pillStatus(for: n, agentState: [:], ops: [:], isRunning: false,
                                                   workSet: [n.id]) == .draft)
    }

    // MARK: isLocked

    /// A work-set prompt node locks mid-run; a non-work prompt node (user draft) does not.
    @Test func workSetNodeLocksDuringRunButNonWorkDoesNot() {
        let fleet = node(), draft = node()
        let graph = SZGraph(nodes: [fleet, draft])
        #expect(SZNodeCanvasContentView.isLocked(fleet.id, agentState: [:], ops: [:], isRunning: true,
                                                 graph: graph, workSet: [fleet.id]) == true)
        #expect(SZNodeCanvasContentView.isLocked(draft.id, agentState: [:], ops: [:], isRunning: true,
                                                 graph: graph, workSet: [fleet.id]) == false)
    }

    /// Nothing locks when no run is in flight.
    @Test func nothingLocksWhenNotRunning() {
        let n = node()
        #expect(SZNodeCanvasContentView.isLocked(n.id, agentState: [:], ops: [:], isRunning: false,
                                                 graph: SZGraph(nodes: [n]), workSet: [n.id]) == false)
    }
}

// MARK: - A built node whose contract has moved

@MainActor
private func built(_ reason: SZRebuildReason?) -> SZNode {
    SZNode(kind: .generated, title: "Kaleidoscope",
           contract: SZNodeContract(title: "K", sfSymbol: "sparkles", summary: ""),
           position: SZPoint(x: 0, y: 0), rebuildReason: reason)
}

/// Amber, not red: the contract declares ports the code hasn't written yet. Nothing failed, the node still
/// draws — this is the ordinary gap between declaring an interface and building it.
@MainActor
@Test func contractChangedReadsOutdatedNotError() {
    let n = built(.contractChanged)
    #expect(SZNodeCanvasContentView.pillStatus(for: n, agentState: [:], ops: [:], isRunning: false) == .outdated)
}

/// Red: the code names ports the contract no longer declares, so those reads resolve to nil every frame and
/// the node silently runs on its hardcoded defaults. `agent_compile_node` calls this an error too.
@MainActor
@Test func sourceMismatchReadsError() {
    let n = built(.sourceMismatch)
    #expect(SZNodeCanvasContentView.pillStatus(for: n, agentState: [:], ops: [:], isRunning: false) == .error)
}

@MainActor
@Test func aCleanBuiltNodeIsReady() {
    #expect(SZNodeCanvasContentView.pillStatus(for: built(nil), agentState: [:], ops: [:], isRunning: false) == .ready)
}

/// While the fleet is rebuilding it, it reads Building — not Outdated, and not Error. The work is in flight.
@MainActor
@Test func aNodeBeingRebuiltReadsBuilding() {
    for reason in [SZRebuildReason.contractChanged, .sourceMismatch] {
        let n = built(reason)
        #expect(SZNodeCanvasContentView.pillStatus(for: n, agentState: [:], ops: [:],
                                                   isRunning: true, workSet: [n.id]) == .building)
    }
}

/// An agent failure still outranks the drift state — that pill carries a diagnostic the user must see.
@MainActor
@Test func anAgentErrorOutranksTheDriftPill() {
    let n = built(.contractChanged)
    let state = [n.id: SZNodeAgentState(phase: .error)]
    #expect(SZNodeCanvasContentView.pillStatus(for: n, agentState: state, ops: [:], isRunning: false) == .error)
}
