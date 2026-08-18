// SPDX-License-Identifier: AGPL-3.0-only
// Run-end accounting from promote evidence: `surfaceUnresolvedNodes` counts a node implemented on the
// promote it saw (+ the node's derived state), keeps an agent's own report, and only writes the generic
// failure through `recordRunFailure` — which never clobbers a specific diagnostic. Bad news the HOST wrote
// (a work traversal that died) is a reason, never a verdict: it can't fail a node that built. A promote
// itself resets the transient agent state (`clearTransientAgentStateAfterPromote`) so no red pill outlives
// a green build, and `cancelRun` counts + narrates the Stop once, retiring the pills its run left mid-flight.
import Foundation
import Testing
import SZAI
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

    /// A host with one live run over every given node — the accounting reads that run's own
    /// captured work set and promote evidence, so the fixture builds a real `SZRunState`.
    private func host(_ nodes: [SZNode], promoted: Set<SZNodeID> = []) -> SZHost {
        let host = SZHost()
        host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: nodes)))
        let run = SZRunState(taskID: UUID(), claim: SZClaimToken(label: "run"), instruction: "",
                             ownsGraphOp: false, workSet: Set(nodes.map(\.id)))
        run.promoted = promoted
        host.activeRuns[run.taskID] = run
        return host
    }
    /// The fixture's single run.
    private func run(_ host: SZHost) -> SZRunState { host.activeRuns.values.first! }
    private func directorLines(_ host: SZHost) -> [String] { host.store.messages(for: .director).map(\.text) }

    // MARK: surfaceUnresolvedNodes

    @Test func twoGreenPromotesReadTwoImplementedAndNoPills() {
        let a = Self.built(), b = Self.built()
        let host = host([a, b], promoted: [a.id, b.id])
        let (done, failed) = host.surfaceUnresolvedNodes(run(host))
        #expect(done == 2 && failed == 0)
        #expect(host.nodeAgentState[a.id] == nil && host.nodeAgentState[b.id] == nil)
        #expect(directorLines(host).isEmpty)
    }

    @Test func aSilentUnpromotedDraftFailsWithTheGenericLineButAGreenOneStillCounts() {
        let a = Self.built(), b = Self.draft()
        let host = host([a, b], promoted: [a.id])
        let (done, failed) = host.surfaceUnresolvedNodes(run(host))
        #expect(done == 1 && failed == 1)
        #expect(host.nodeAgentState[b.id]?.phase == .error)
        #expect(host.nodeAgentState[b.id]?.errorDetail == "the agent never compiled this node or reported a blocker")
        #expect(directorLines(host) == ["Draft didn't finish — the agent never compiled this node or reported a blocker."])
    }

    @Test func aRebriefedPromoteIsImplementedAndNarrated() {
        let a = Self.built(prompt: "new intent", stampPrompt: "old intent")
        let host = host([a], promoted: [a.id])
        let (done, failed) = host.surfaceUnresolvedNodes(run(host))
        #expect(done == 1 && failed == 0)
        #expect(host.nodeAgentState[a.id] == nil)   // amber Outdated pill only — no error state
        #expect(directorLines(host).first?.contains("prompt changed mid-run") == true)
    }

    @Test func aReportedProblemKeepsTheAgentsOwnWords() {
        let b = Self.draft()
        let host = host([b])
        host.recordNodeStatus(node: b.id, phase: .needsInput, message: "which palette?")
        let (done, failed) = host.surfaceUnresolvedNodes(run(host))
        #expect(done == 0 && failed == 1)
        #expect(host.nodeAgentState[b.id]?.phase == .needsInput)
        #expect(host.nodeAgentState[b.id]?.message == "which palette?")
        #expect(host.nodeAgentState[b.id]?.reportedByAgent == true)   // signed: this one IS the verdict
        #expect(directorLines(host).isEmpty)
    }

    /// The incident: the agent promotes green at minute 3, keeps polishing, and its turn's budget runs
    /// out. The work traversal ends `.failed`, the host paints the node — and the run must STILL read it
    /// as built, with the red pill retired. The agent's transcript keeps the timeout line either way.
    @Test func aPromotedNodeWhoseTurnDiedLaterIsStillImplemented() {
        let a = Self.built()
        let host = host([a], promoted: [a.id])
        let record = UUID()
        host.beginAgentGraphRun(SZTraversalSighting(id: record, agent: "coding", work: a.id.uuidString),
                                thread: record)
        host.concludeAgentGraphRun(record, .failed(reason: "the agent timed out after 15m without finishing"))
        #expect(host.nodeAgentState[a.id]?.phase == .error)          // the pill while the run is still up
        #expect(host.nodeAgentState[a.id]?.reportedByAgent == false)  // …written by the host, not the agent
        let (done, failed) = host.surfaceUnresolvedNodes(run(host))
        #expect(done == 1 && failed == 0)
        #expect(host.nodeAgentState[a.id]?.phase == .ok)
        #expect(host.nodeAgentState[a.id]?.errorDetail == nil)
        #expect(directorLines(host).isEmpty)
        #expect(host.nodeStatusLines[a.id] == "ok")   // nothing left to feed the next run as a blocker
    }

    /// The same host line on a node that built NOTHING is a failure — and a better reason than the
    /// generic "never compiled", both on the pill and in the run's narration.
    @Test func aHostRecordedReasonStandsInForTheGenericLine() {
        let b = Self.draft()
        let host = host([b])
        host.recordHostFailure(node: b.id, message: "the agent went silent for 5m and was stopped")
        let (done, failed) = host.surfaceUnresolvedNodes(run(host))
        #expect(done == 0 && failed == 1)
        #expect(host.nodeAgentState[b.id]?.message == "the agent went silent for 5m and was stopped")
        #expect(directorLines(host) == ["Draft didn't finish — the agent went silent for 5m and was stopped."])
    }

    /// A node whose source and contract disagree is narrated in the AUDIT's words — the audit raises
    /// more than one fault, so a fixed "reads ports the contract doesn't declare" sentence would send
    /// the Director hunting port names for a `setPaused` fault. (No project on disk here, so the fresh
    /// audit can't run and the cached pill detail stands in — the same text either way.)
    @Test func aSourceMismatchIsNarratedInTheAuditsOwnWords() throws {
        var a = Self.built()
        a.sourceMismatch = true
        let host = host([a], promoted: [a.id])
        host.nodeAgentState[a.id] = SZNodeAgentState(
            phase: .ok, errorDetail: "Node.swift creates an AVAudioEngine, which keeps running when the "
                + "graph's clock stops. Stop it in `func setPaused(_ paused: Bool)` — see node-abi.")
        let (done, failed) = host.surfaceUnresolvedNodes(run(host))
        #expect(done == 0 && failed == 1)
        let line = try #require(directorLines(host).first)
        #expect(line.contains("setPaused"))
        #expect(!line.contains("reads ports"))
        #expect(host.nodeAgentState[a.id]?.message.contains("setPaused") == true)
    }

    @Test func aNodeGoneFromTheGraphIsUncounted() {
        let a = Self.built()
        let host = host([a], promoted: [a.id])
        run(host).workSet.insert(SZNodeID())   // merged away mid-run
        let (done, failed) = host.surfaceUnresolvedNodes(run(host))
        #expect(done == 1 && failed == 0)
    }

    // MARK: cancelRun

    /// The count + narration happen synchronously in the cancel, while the work set is still this run's —
    /// the cancelled task's own catch is a zombie and stays silent (so a Stop-then-Build can't stamp a
    /// stray "cancelled" line under the new run's start line).
    @Test func cancelNarratesTheUnfinishedCountOnceAndRetiresWorkingPills() {
        let a = Self.built(), b = Self.draft()
        let host = host([a, b])
        host.nodeAgentState[a.id] = SZNodeAgentState(phase: .coding, message: "wiring the mask polygon")
        host.nodeAgentState[b.id] = SZNodeAgentState(phase: .queued)
        host.cancelRun()
        #expect(directorLines(host) == ["Run cancelled — 1 node unfinished."])   // the built one is done
        #expect(host.nodeAgentState[a.id]?.phase == .idle)
        #expect(host.nodeAgentState[b.id]?.phase == .idle)
        #expect(host.nodeStatusLines.isEmpty)   // nothing left to feed the next run as a blocker
    }

    @Test func cancelKeepsAnAgentsOwnReport() {
        let b = Self.draft()
        let host = host([b])
        host.recordNodeStatus(node: b.id, phase: .needsInput, message: "which palette?")
        host.cancelRun()
        #expect(host.nodeAgentState[b.id]?.phase == .needsInput)
        #expect(host.nodeAgentState[b.id]?.message == "which palette?")
    }

    @Test func cancelWithNothingLeftUnfinishedSaysSo() {
        let host = host([Self.built()])
        host.cancelRun()
        #expect(directorLines(host) == ["Run cancelled."])
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

    /// A progress note left by an agent that then died is not the blocker — the run's reason replaces it.
    @Test func recordRunFailurePrefersTheRunReasonOverAStaleProgressNote() {
        let b = Self.draft()
        let host = host([b])
        host.nodeAgentState[b.id] = SZNodeAgentState(phase: .coding, message: "wiring the mask polygon", isChatting: true)
        host.recordRunFailure(node: b.id, fallback: "generic")
        let state = host.nodeAgentState[b.id]
        #expect(state?.phase == .error)
        #expect(state?.message == "generic")
        #expect(state?.errorDetail == "generic")
        #expect(state?.isChatting == true)
    }

    /// The verdict table routes a reported phase elsewhere, but if one ever lands here its words stand.
    @Test func recordRunFailureKeepsAReportedMessage() {
        let b = Self.draft()
        let host = host([b])
        host.recordNodeStatus(node: b.id, phase: .needsInput, message: "which palette?")
        host.recordRunFailure(node: b.id, fallback: "generic")
        #expect(host.nodeAgentState[b.id]?.message == "which palette?")
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
        host.nodeAgentState[a.id] = SZNodeAgentState(phase: .error, message: "boom", errorDetail: "boom log",
                                                     isChatting: true, reportedByAgent: true)
        host.clearTransientAgentStateAfterPromote(a.id)
        // The report goes with it: a green build is newer evidence, so nothing of it may outrank the next one.
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
