// SPDX-License-Identifier: AGPL-3.0-only
// Run-end accounting from promote evidence: `surfaceUnresolvedNodes` counts a node implemented on the
// promote it saw (+ the node's derived state), keeps an agent's own report, and only writes the generic
// failure through `recordRunFailure` — which never clobbers a specific diagnostic. A promote itself resets
// the transient agent state (`clearTransientAgentStateAfterPromote`) so no red pill outlives a green build.
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostRunAccountingTests {
    private static let surface: Set<SZNodeContract.PortSignature> =
        [.init(direction: .input, name: "input", type: .texture), .init(direction: .output, name: "output", type: .texture)]
    private static let contract = SZNodeContract(
        title: "N", sfSymbol: "circle", summary: "",
        inputs: [SZPort(name: "input", type: .texture)], outputs: [SZPort(name: "output", type: .texture)])

    /// A built node whose stamp matches its contract + prompt (clean), or whose prompt moved off the stamp.
    private static func built(prompt: String = "p", stampPrompt: String = "p") -> SZNode {
        SZNode(kind: .generated, title: "Built", prompt: prompt, contract: contract, position: SZPoint(x: 0, y: 0),
               buildStamp: SZBuildStamp(portSurface: surface, prompt: stampPrompt))
    }
    private static func draft() -> SZNode {
        SZNode(kind: .prompt, title: "Draft", prompt: "p", position: SZPoint(x: 0, y: 0))
    }

    private func host(_ nodes: [SZNode], promoted: Set<SZNodeID> = []) -> SZHost {
        let host = SZHost()
        host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: nodes)))
        host.runWorkSet = Set(nodes.map(\.id))
        host.promotedThisRun = promoted
        return host
    }
    private func directorLines(_ host: SZHost) -> [String] { host.store.messages(for: .director).map(\.text) }

    // MARK: surfaceUnresolvedNodes

    @Test func twoGreenPromotesReadTwoImplementedAndNoPills() {
        let a = Self.built(), b = Self.built()
        let host = host([a, b], promoted: [a.id, b.id])
        let (done, failed) = host.surfaceUnresolvedNodes()
        #expect(done == 2 && failed == 0)
        #expect(host.nodeAgentState[a.id] == nil && host.nodeAgentState[b.id] == nil)
        #expect(directorLines(host).isEmpty)
    }

    @Test func aSilentUnpromotedDraftFailsWithTheGenericLineButAGreenOneStillCounts() {
        let a = Self.built(), b = Self.draft()
        let host = host([a, b], promoted: [a.id])
        let (done, failed) = host.surfaceUnresolvedNodes()
        #expect(done == 1 && failed == 1)
        #expect(host.nodeAgentState[b.id]?.phase == .error)
        #expect(host.nodeAgentState[b.id]?.errorDetail == "the agent never compiled this node or reported a blocker")
        #expect(directorLines(host) == ["Draft didn't finish — the agent never compiled this node or reported a blocker."])
    }

    @Test func aRebriefedPromoteIsImplementedAndNarrated() {
        let a = Self.built(prompt: "new intent", stampPrompt: "old intent")
        let host = host([a], promoted: [a.id])
        let (done, failed) = host.surfaceUnresolvedNodes()
        #expect(done == 1 && failed == 0)
        #expect(host.nodeAgentState[a.id] == nil)   // amber Outdated pill only — no error state
        #expect(directorLines(host).first?.contains("prompt changed mid-run") == true)
    }

    @Test func aReportedProblemKeepsTheAgentsOwnWords() {
        let b = Self.draft()
        let host = host([b])
        host.recordNodeStatus(node: b.id, phase: .needsInput, message: "which palette?")
        let (done, failed) = host.surfaceUnresolvedNodes()
        #expect(done == 0 && failed == 1)
        #expect(host.nodeAgentState[b.id]?.phase == .needsInput)
        #expect(host.nodeAgentState[b.id]?.message == "which palette?")
        #expect(directorLines(host).isEmpty)
    }

    @Test func aNodeGoneFromTheGraphIsUncounted() {
        let a = Self.built()
        let host = host([a], promoted: [a.id])
        host.runWorkSet.insert(SZNodeID())   // merged away mid-run
        let (done, failed) = host.surfaceUnresolvedNodes()
        #expect(done == 1 && failed == 0)
    }

    // MARK: recordRunFailure

    @Test func recordRunFailurePreservesASpecificDiagnostic() {
        let b = Self.draft()
        let host = host([b])
        host.nodeAgentState[b.id] = SZNodeAgentState(phase: .coding, message: "", errorDetail: "port 'gain' is not declared")
        host.recordRunFailure(node: b.id, fallback: "generic")
        let state = host.nodeAgentState[b.id]
        #expect(state?.phase == .error)
        #expect(state?.message == "generic")
        #expect(state?.errorDetail == "port 'gain' is not declared")
        #expect(host.nodeStatusLines[b.id] == "error: generic")
    }

    @Test func recordRunFailureFillsOnlyWhatIsEmpty() {
        let b = Self.draft()
        let host = host([b])
        host.nodeAgentState[b.id] = SZNodeAgentState(phase: .ok, message: "halfway there", isChatting: true)
        host.recordRunFailure(node: b.id, fallback: "generic")
        let state = host.nodeAgentState[b.id]
        #expect(state?.phase == .error)
        #expect(state?.message == "halfway there")
        #expect(state?.errorDetail == "generic")
        #expect(state?.isChatting == true)
    }

    @Test func recordRunFailureIgnoresANodeOutsideTheGraph() {
        let host = host([Self.draft()])
        let ghost = SZNodeID()
        host.recordRunFailure(node: ghost, fallback: "generic")
        #expect(host.nodeAgentState[ghost] == nil)
    }

    // MARK: clearTransientAgentStateAfterPromote

    @Test func aPromoteDemotesAStaleErrorAndKeepsTheChatFlag() {
        let a = Self.built()
        let host = host([a])
        host.nodeAgentState[a.id] = SZNodeAgentState(phase: .error, message: "boom", errorDetail: "boom log", isChatting: true)
        host.clearTransientAgentStateAfterPromote(a.id)
        #expect(host.nodeAgentState[a.id] == SZNodeAgentState(phase: .ok, message: "", errorDetail: nil, isChatting: true))
        // A needsInput pill goes the same way; a coding phase is left alone.
        host.nodeAgentState[a.id] = SZNodeAgentState(phase: .needsInput, message: "q?")
        host.clearTransientAgentStateAfterPromote(a.id)
        #expect(host.nodeAgentState[a.id]?.phase == .ok)
        host.nodeAgentState[a.id] = SZNodeAgentState(phase: .coding, message: "working", errorDetail: "old")
        host.clearTransientAgentStateAfterPromote(a.id)
        #expect(host.nodeAgentState[a.id] == SZNodeAgentState(phase: .coding, message: "", errorDetail: nil))
    }
}
