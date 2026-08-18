// SPDX-License-Identifier: AGPL-3.0-only
// Runs are scoped by their WORK SET, not serialized. What these pin: several runs are live at
// once and each owns its own state; stopping one leaves the others untouched; and the queue
// admits oldest-first without a blocked task blocking a disjoint one behind it.
// (Starting a run for real needs an MCP port, a project and a provider CLI — the admission
// arithmetic is exercised here against registered run state, the whole path on the MCP drive.)
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostConcurrentRunsTests {

    /// A live run over `nodes`, holding them exactly as `startRun` would.
    @discardableResult
    private func run(_ host: SZHost, _ nodes: Set<SZNodeID>, label: String) -> SZRunState {
        let claim = SZClaimToken(label: label)
        var resources: Set<SZResourceID> = []
        for id in nodes { resources.insert(.node(id)); resources.insert(.transcript(.node(id))) }
        #expect(host.ledger.tryAcquire(resources, as: claim))
        let state = SZRunState(taskID: UUID(), claim: claim, instruction: label,
                               ownsGraphOp: false, workSet: nodes)
        host.activeRuns[state.taskID] = state
        return state
    }

    @Test func twoRunsOverDisjointNodesAreLiveTogether() {
        let host = SZHost()
        let a = SZNodeID(), b = SZNodeID()
        let first = run(host, [a], label: "run a")
        let second = run(host, [b], label: "run b")
        #expect(host.isRunning)
        #expect(host.activeRuns.count == 2)
        // The work set the UI locks on is every live run's, together.
        #expect(host.runWorkSet == [a, b])
        // Each node answers with ITS run — that is how a per-node write finds its evidence.
        #expect(host.activeRun(holding: a) === first)
        #expect(host.activeRun(holding: b) === second)
    }

    @Test func aRunsWorkSetRefusesAnotherRunsClaim() {
        let host = SZHost()
        let shared = SZNodeID()
        run(host, [shared], label: "run a")
        // The ledger IS the exclusion: the second ask cannot claim what the first holds, which is
        // what makes an overlapping task wait instead of interleaving.
        let contender = SZClaimToken(label: "run b")
        #expect(!host.ledger.tryAcquire([.node(shared), .transcript(.node(shared))], as: contender))
    }

    @Test func stoppingOneRunLeavesTheOtherUntouched() {
        let host = SZHost()
        let a = SZNodeID(), b = SZNodeID()
        let first = run(host, [a], label: "run a")
        let second = run(host, [b], label: "run b")
        host.cancelRun(first)
        #expect(!host.isLive(first))
        #expect(host.isLive(second))
        #expect(host.isRunning)                       // B still holds the floor
        #expect(host.runWorkSet == [b])
        #expect(host.ledger.holder(of: .node(b)) == second.claim)
        // A's nodes are free again — a queued task over them can now be admitted.
        #expect(host.ledger.holder(of: .node(a)) == nil)
    }

    @Test func stoppingIsIdempotentAndAZombieCannotResettleItsRun() {
        let host = SZHost()
        let node = SZNodeID()
        let only = run(host, [node], label: "run")
        host.cancelRun(only)
        host.cancelRun(only)                          // the zombie's second settle
        #expect(!host.isRunning)
        #expect(host.activeRuns.isEmpty)
    }

    @Test func stopEndsWhatIsRunningAndLeavesTheQueueStanding() {
        let host = SZHost()
        run(host, [SZNodeID()], label: "run a")
        run(host, [SZNodeID()], label: "run b")
        host.mintRun(instruction: "still wanted")
        host.cancelRun()                              // the HUD Stop: every live run
        #expect(!host.isRunning)
        // Stop ends work; it does not empty the queue — the ask survives to be admitted.
        #expect(host.pendingTasks.map(\.instruction) == ["still wanted"])
    }

    @Test func admissionKeepsUnstartableTasksInOrder() {
        let host = SZHost()   // bare: no MCP port, no project — every start answers `waiting`
        host.mintRun(instruction: "first")
        host.mintRun(instruction: "second")
        host.admitPendingTasks()
        // Waiting keeps a task's PLACE (a refusal would drop it), and order is arrival order.
        #expect(host.pendingTasks.map(\.instruction) == ["first", "second"])
    }

    @Test func aNewRunsWorkSetExcludesWhatIsAlreadyBeingBuilt() {
        let draft = { SZNode(kind: .prompt, title: "D", prompt: "p", position: SZPoint(x: 0, y: 0)) }
        let mine = draft(), theirs = draft()
        let blank = SZNode(kind: .prompt, title: "Blank", prompt: "  ", position: SZPoint(x: 0, y: 0))
        let built = SZNode(kind: .generated, title: "Built", position: SZPoint(x: 0, y: 0),
                           buildStamp: SZBuildStamp(portSurface: [], prompt: nil))

        let free = SZHost.workSetCandidates(in: [mine, theirs, blank, built], excluding: [])
        #expect(free.work == [mine.id, theirs.id])   // built nodes aren't dirty; blank ones aren't work
        #expect(free.blank == [blank.id])
        #expect(free.taken.isEmpty)

        // With one node already someone's work, a new run takes only what is left — and `taken`
        // is what lets the refusal say "already being built" instead of "nothing to implement".
        let contended = SZHost.workSetCandidates(in: [mine, theirs, blank, built], excluding: [theirs.id])
        #expect(contended.work == [mine.id])
        #expect(contended.taken == [theirs.id])

        // Everything dirty is taken: no work of its own, and nothing to mistake for a finished graph.
        let none = SZHost.workSetCandidates(in: [mine, blank], excluding: [mine.id])
        #expect(none.work.isEmpty && none.taken == [mine.id])
    }

    @Test func aTaskCarriesATitleFromTheWordsThatScheduledIt() {
        #expect(SZTask.title(fromInstruction: "make the circle bigger", nodeCount: 1)
                == "make the circle bigger")
        // A Build press schedules with no words at all — it is named for its work instead.
        #expect(SZTask.title(fromInstruction: "", nodeCount: 3) == "Implement 3 nodes")
        #expect(SZTask.title(fromInstruction: "", nodeCount: 1) == "Implement 1 node")
        // Only the first line, clipped — a strip row is one line high.
        #expect(SZTask.title(fromInstruction: "warmer\nand slower", nodeCount: 0) == "warmer")
        #expect(SZTask.title(fromInstruction: String(repeating: "x", count: 80), nodeCount: 0).count == 60)
    }
}
