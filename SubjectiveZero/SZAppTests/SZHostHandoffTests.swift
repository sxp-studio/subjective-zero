// SPDX-License-Identifier: AGPL-3.0-only
// A run whose Director hands part of its ask to the build holding a node: the note is recorded
// for that build, and the caller's run remembers it handed off, so its receipt says where the
// ask went instead of "nothing needed building". Also the one join rule: a node the run's own
// tooling adds that needs nothing built is never counted as a build.
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostHandoffTests {

    private func node(_ title: String = "Pixel Morph") -> SZNode {
        SZNode(kind: .prompt, title: title, prompt: "morph", position: SZPoint(x: 0, y: 0))
    }

    private func run(_ host: SZHost, over nodes: Set<SZNodeID> = [], label: String) -> SZRunState {
        let claim = SZClaimToken(label: label)
        var resources: Set<SZResourceID> = []
        for id in nodes { resources.insert(.node(id)); resources.insert(.transcript(.node(id))) }
        #expect(host.ledger.tryAcquire(resources, as: claim))
        let state = SZRunState(taskID: UUID(), claim: claim, instruction: label,
                               ownsGraphOp: false, workSet: nodes)
        host.activeRuns[state.taskID] = state
        return state
    }

    /// The case from the session: a second ask's Director sends its note to the node the first
    /// build holds. The note is queued for that build, and the sender's run knows it handed off.
    @Test func aNoteToAnotherBuildsNodeIsRecordedAndRemembered() {
        let host = SZHost()
        let n = node()
        host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: [n])))
        let holder = run(host, over: [n.id], label: "run (holder)")
        let asker = run(host, label: "run (asker)")
        let routing = SZToolCaller.$claim.withValue(asker.claim) {
            host.sendChat(scope: .node(n.id), message: "add the other videos", origin: .agent)
        }
        guard case .recordedForReconcile = routing else {
            Issue.record("expected the note to be recorded, got \(routing)"); return
        }
        #expect(asker.handedOff == [n.id])
        #expect(holder.handedOff.isEmpty)
        let queued = host.pendingDirectorMessages(dispatching: [n.id.uuidString])
        #expect(queued[n.id.uuidString]?.text.contains("add the other videos") == true)
    }

    /// A Director steering its OWN run's node hands nothing off: that is ordinary steering.
    @Test func aNoteToTheRunsOwnNodeIsNotAHandoff() {
        let host = SZHost()
        let n = node()
        host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: [n])))
        let mine = run(host, over: [n.id], label: "run (mine)")
        let routing = SZToolCaller.$claim.withValue(mine.claim) {
            host.sendChat(scope: .node(n.id), message: "use Rec.709", origin: .agent)
        }
        guard case .recordedForReconcile = routing else {
            Issue.record("expected the note to be recorded, got \(routing)"); return
        }
        #expect(mine.handedOff.isEmpty)
    }

    /// A library node the run adds mid-run is built already: it joins the work set, and it is
    /// marked as never dispatched so the receipt does not report "built Camera".
    @Test func aNodeAddedThatNeedsNoBuildIsJoinedButNotCounted() {
        let host = SZHost()
        let built = SZNode(kind: .generated, title: "Camera",
                           contract: SZNodeContract(title: "Camera", sfSymbol: "s", summary: "",
                                                    inputs: [], outputs: []),
                           position: SZPoint(x: 0, y: 0))
        let dirty = node("Blur")
        host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: [built, dirty])))
        let live = run(host, label: "run (claude)")
        SZToolCaller.$claim.withValue(live.claim) {
            host.noteRunCreatedWork([built.id, dirty.id])
        }
        #expect(live.workSet == [built.id, dirty.id])
        #expect(live.wiringOnly == [built.id])
    }
}
