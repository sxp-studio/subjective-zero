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

/// Amending work that has not started — the scheduler's other half. A pending task can still be
/// changed for free; a running one is a steer, and the refusal says which so the caller knows.
@MainActor
struct SZHostTaskAmendTests {

    @Test func wordsFoldIntoAPendingTaskWithoutLosingWhatWasAsked() {
        let host = SZHost()
        let id = host.mintRun(instruction: "make the circle bigger")
        #expect(host.amendTask(id, with: "actually blue, not red"))
        // Appended, never replaced: a follow-up usually refines the ask, and only the reader can
        // tell which half won.
        #expect(host.pendingTasks.first?.instruction
                == "make the circle bigger\n\nactually blue, not red")
    }

    @Test func anEmptyAmendChangesNothing() {
        let host = SZHost()
        let id = host.mintRun(instruction: "bigger")
        #expect(!host.amendTask(id, with: "   \n "))
        #expect(host.pendingTasks.first?.instruction == "bigger")
    }

    @Test func anInstructionlessTaskTakesTheAmendWhole() {
        let host = SZHost()
        let id = host.mintRun(instruction: "")     // the Build press schedules with no words
        #expect(host.amendTask(id, with: "keep the blur soft"))
        #expect(host.pendingTasks.first?.instruction == "keep the blur soft")
    }

    @Test func twoAsksBecomeOneByAmendingTheSurvivorAndCancellingTheOther() {
        let host = SZHost()
        let keep = host.mintRun(instruction: "add a glow")
        let drop = host.mintRun(instruction: "and make it warm")
        #expect(host.amendTask(keep, with: "and make it warm"))
        #expect(host.withdrawTask(drop))
        #expect(host.pendingTasks.map(\.id) == [keep])
        #expect(host.pendingTasks.first?.instruction == "add a glow\n\nand make it warm")
    }

    @Test func aRunningTaskCannotBeAmendedOrCancelled() {
        let host = SZHost()
        let node = SZNodeID()
        let claim = SZClaimToken(label: "run")
        #expect(host.ledger.tryAcquire([.node(node)], as: claim))
        let live = SZRunState(taskID: UUID(), claim: claim, instruction: "building",
                              ownsGraphOp: false, workSet: [node])
        host.activeRuns[live.taskID] = live
        // Already spending: steering it is a message to its agents, not an edit to a plan.
        #expect(!host.amendTask(live.taskID, with: "too late"))
        #expect(!host.withdrawTask(live.taskID))
    }
}

/// Scoping a task to named nodes — the thing that makes concurrency reachable at all. Without it
/// every run computes "everything dirty", the first takes the lot, and a second ask has nothing
/// left to be concurrent with.
@MainActor
struct SZHostScopedTaskTests {

    private func draft(_ title: String) -> SZNode {
        SZNode(kind: .prompt, title: title, prompt: "do \(title)", position: SZPoint(x: 0, y: 0))
    }

    @Test func aNamedWorkSetTakesOnlyThoseNodes() {
        let a = draft("A"), b = draft("B")
        let all = SZHost.workSetCandidates(in: [a, b], excluding: [])
        #expect(all.work == [a.id, b.id])   // unscoped: an ask takes everything pending

        // Scoped by the caller (`ui_run { nodes: [...] }`), the same graph yields one node — which
        // is what leaves B free for a second task to claim.
        let scoped = all.work.intersection([a.id])
        #expect(scoped == [a.id])
        #expect(all.work.subtracting(scoped) == [b.id])
    }

    @Test func aScopedTaskCarriesItsNodesFromTheStart() {
        let host = SZHost()
        let a = SZNodeID()
        let id = host.mintRun(instruction: "just this one", nodes: [a])
        // The nodes ride on the TASK, so they survive the queue and are known before admission —
        // that is what the strip reads to say what a pending task is waiting behind.
        #expect(host.pendingTasks.first?.id == id)
        #expect(host.pendingTasks.first?.workSet == [a])
    }
}

/// Stop, with more than one run live. Both were live-caught: Stop left a run alive because the
/// loop mutated the table it was walking, and the queue answered a Stop by starting the next ask.
@MainActor
struct SZHostStopTests {

    private func live(_ host: SZHost, _ node: SZNodeID, _ label: String) -> SZRunState {
        let claim = SZClaimToken(label: label)
        #expect(host.ledger.tryAcquire([.node(node), .transcript(.node(node))], as: claim))
        let run = SZRunState(taskID: UUID(), claim: claim, instruction: label,
                             ownsGraphOp: false, workSet: [node])
        host.activeRuns[run.taskID] = run
        return run
    }

    @Test func stopEndsEveryLiveRunNotJustOne() {
        let host = SZHost()
        live(host, SZNodeID(), "run a")
        live(host, SZNodeID(), "run b")
        live(host, SZNodeID(), "run c")
        host.cancelRun()
        // Snapshot-then-cancel: walking `activeRuns.values` while deregistering skipped runs.
        #expect(host.activeRuns.isEmpty)
        #expect(!host.isRunning)
    }

    @Test func stopLeavesTheQueueStandingWithoutStartingIt() {
        let host = SZHost()
        live(host, SZNodeID(), "run a")
        host.mintRun(instruction: "the next thing")
        host.cancelRun()
        // The ask survives…
        #expect(host.pendingTasks.map(\.instruction) == ["the next thing"])
        // …and is NOT launched on the way out of a Stop.
        host.admitPendingTasks()
        #expect(host.pendingTasks.count == 1)
        #expect(!host.isRunning)
    }

    @Test func stopSuspendsAdmissionBeforeItReleasesAnything() {
        let host = SZHost()
        let node = SZNodeID()
        let claim = SZClaimToken(label: "run a")
        #expect(host.ledger.tryAcquire([.node(node), .transcript(.node(node))], as: claim))
        let live = SZRunState(taskID: UUID(), claim: claim, instruction: "a",
                              ownsGraphOp: false, workSet: [node])
        host.activeRuns[live.taskID] = live
        host.mintRun(instruction: "the next thing")
        // Releasing a claim re-enters the pump synchronously, so a flag set AFTER the cancels
        // arrives too late to stop anything — the queue has already started.
        host.ledger.onAvailabilityChanged = { host.admitPendingTasks() }
        host.cancelRun()
        #expect(host.admissionSuspended)
        #expect(host.pendingTasks.map(\.instruction) == ["the next thing"])
    }

    @Test func theNextAskReleasesTheQueueAgain() {
        let host = SZHost()
        live(host, SZNodeID(), "run a")
        host.mintRun(instruction: "queued")
        host.cancelRun()
        #expect(host.admissionSuspended)
        host.mintRun(instruction: "a new ask")   // the user acting again
        #expect(!host.admissionSuspended)
    }
}

/// The host-wide singletons a run touches. Each was safe when only one run could exist; every one
/// of these is a cross-run hazard: safe while only one run could exist, wrong once two can.
@MainActor
struct SZHostRunScopingTests {

    private func run(_ host: SZHost, _ nodes: Set<SZNodeID>, _ label: String) -> SZRunState {
        let claim = SZClaimToken(label: label)
        var res: Set<SZResourceID> = []
        for n in nodes { res.insert(.node(n)); res.insert(.transcript(.node(n))) }
        #expect(host.ledger.tryAcquire(res, as: claim))
        let state = SZRunState(taskID: UUID(), claim: claim, instruction: label,
                               ownsGraphOp: false, workSet: nodes)
        host.activeRuns[state.taskID] = state
        return state
    }

    private func steer(_ host: SZHost, to node: SZNodeID, _ text: String) -> UUID {
        let envelope = SZMessageEnvelope(
            recipient: SZChatScope.node(node).key, sender: "director", intent: .steer,
            message: SZChatMessage(role: .director, text: text))
        host.mailbox.enqueue(envelope)
        return envelope.id
    }

    @Test func aRunDrainsOnlyTheSteersAimedAtItsOwnNodes() {
        let host = SZHost()
        let mine = SZNodeID(), theirs = SZNodeID()
        let a = run(host, [mine], "run a")
        run(host, [theirs], "run b")
        _ = steer(host, to: mine, "for A")
        let other = steer(host, to: theirs, "for B")

        let taken = host.takeDirectorMessages(for: a)
        #expect(taken.keys.map(\.self) == [mine])
        // B's steer is untouched and still deliverable — an unscoped drain consumed and discarded it.
        #expect(host.mailbox.envelope(for: other)?.state == .queued)
    }

    @Test func aRunEndingSweepsOnlyItsOwnSteers() {
        let host = SZHost()
        let mine = SZNodeID(), theirs = SZNodeID()
        let a = run(host, [mine], "run a")
        run(host, [theirs], "run b")
        let ours = steer(host, to: mine, "for A")
        let other = steer(host, to: theirs, "for B")

        host.sweepUnconsumedSteers(for: a)
        #expect(host.mailbox.envelope(for: ours)?.state == .failed)
        // One run ending must not destroy a concurrent run's pending steering.
        #expect(host.mailbox.envelope(for: other)?.state == .queued)
    }

    @Test func onlyTheOwningRunSettlesAStagedGraphOp() {
        let host = SZHost()
        let a = run(host, [SZNodeID()], "run a")
        let b = run(host, [SZNodeID()], "run b")
        a.ownsGraphOp = true
        // Ownership rides on the run, so a sibling finishing first cannot roll back A's pieces.
        #expect(a.ownsGraphOp)
        #expect(!b.ownsGraphOp)
    }

    @Test func createdWorkGoesToTheCallersRunOrNowhere() {
        let host = SZHost()
        let a = run(host, [SZNodeID()], "run a")
        let fresh = SZNodeID()
        // No caller identity: attributing this to "the only live run" pulled nodes into a fleet
        // that never asked for them.
        host.noteRunCreatedWork([fresh])
        #expect(!a.workSet.contains(fresh))

        SZToolCaller.$claim.withValue(a.claim) { host.noteRunCreatedWork([fresh]) }
        #expect(a.workSet.contains(fresh))
    }

    @Test func aNodeAnotherRunHoldsIsNeverAdopted() {
        let host = SZHost()
        let theirs = SZNodeID()
        let a = run(host, [SZNodeID()], "run a")
        run(host, [theirs], "run b")
        SZToolCaller.$claim.withValue(a.claim) { host.noteRunCreatedWork([theirs]) }
        // Contended is a legitimate state now, so this skips rather than asserting.
        #expect(!a.workSet.contains(theirs))
    }

    @Test func eachRunKeepsItsOwnDirectorSession() {
        let host = SZHost()
        let a = run(host, [SZNodeID()], "run a")
        let b = run(host, [SZNodeID()], "run b")
        a.directorSession = SZAgentSession(providerID: "claude", sessionID: "A")
        b.directorSession = SZAgentSession(providerID: "claude", sessionID: "B")
        // Sharing the scope-keyed slot interleaved two runs in one CLI conversation.
        #expect(a.directorSession?.sessionID == "A")
        #expect(b.directorSession?.sessionID == "B")
        #expect(host.agentSessions[SZChatScope.directorKey] == nil)
    }
}

/// Lifecycle gates that only became reachable once runs could overlap.
@MainActor
struct SZHostLifecycleScopingTests {

    @Test func aRunWithNoWorkSetStillCountsAsBusy() {
        let host = SZHost()
        // An ask that creates its own work claims NOTHING (the `.run` slot is gone), so a gate
        // built on `ledger.anyHeld` stopped seeing it and let a project switch tear the graph out
        // from under a live traversal.
        let run = SZRunState(taskID: UUID(), claim: SZClaimToken(label: "run"),
                             instruction: "make me something new", ownsGraphOp: false, workSet: [])
        host.activeRuns[run.taskID] = run
        #expect(!host.ledger.anyHeld)
        #expect(host.isBusyForProjectOps)
    }

    @Test func aBuildPressReleasesAStopsHoldOnTheQueue() {
        let host = SZHost()
        host.mintRun(instruction: "queued")
        host.cancelRun()
        #expect(host.admissionSuspended)
        host.buildPressed()   // the user asking again
        #expect(!host.admissionSuspended)
    }
}

/// What the HUD may offer while something is already building. The Build control used to BECOME
/// Stop during a run, so a draft added mid-run had no control that would queue it.
@MainActor
struct SZHostPendingWorkTests {

    private func draft(_ title: String) -> SZNode {
        SZNode(kind: .prompt, title: title, prompt: "do \(title)", position: SZPoint(x: 0, y: 0))
    }

    @Test func aNodeAnotherRunIsBuildingIsNotPendingWork() {
        let host = SZHost()
        let building = draft("Grayscale"), fresh = draft("Distortion")
        host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: [building, fresh])))

        let claim = SZClaimToken(label: "run")
        #expect(host.ledger.tryAcquire([.node(building.id)], as: claim))
        let run = SZRunState(taskID: UUID(), claim: claim, instruction: "",
                             ownsGraphOp: false, workSet: [building.id])
        host.activeRuns[run.taskID] = run

        // Only the draft nobody holds — counting the one being built made Build offer work it
        // could not take.
        #expect(host.pendingNodeCount == 1)
        // And it is still offered AT ALL while a run is live, which is the whole point.
        #expect(host.pendingWorkAvailable)
    }

    @Test func aBuildPressIsScheduledSoItSurvivesContention() {
        let host = SZHost()
        host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: [draft("A")])))
        host.buildPressed()
        // Bare host: the start cannot succeed, and a press that went straight to `startRun` would
        // simply vanish. It stands as an ask instead.
        #expect(host.pendingTasks.count == 1)
    }
}

/// Interrupting ONE agent graph. Stop used to be all-or-nothing, which stopped making sense the
/// moment two builds could be in flight for different reasons.
@MainActor
struct SZHostInterruptOneRunTests {

    private func run(_ host: SZHost, _ node: SZNodeID, _ label: String) -> SZRunState {
        let claim = SZClaimToken(label: label)
        #expect(host.ledger.tryAcquire([.node(node), .transcript(.node(node))], as: claim))
        let state = SZRunState(taskID: UUID(), claim: claim, instruction: label,
                               ownsGraphOp: false, workSet: [node])
        host.activeRuns[state.taskID] = state
        return state
    }

    @Test func stoppingOneThreadLeavesTheOthersBuilding() {
        let host = SZHost()
        let a = run(host, SZNodeID(), "run a")
        let b = run(host, SZNodeID(), "run b")

        #expect(host.cancelRun(thread: a.thread))
        #expect(!host.isLive(a))
        #expect(host.isLive(b))
        #expect(host.isRunning)
        // And the interrupted run gave its nodes back, so the work is claimable again.
        #expect(host.ledger.holder(of: .node(a.workSet.first!)) == nil)
    }

    @Test func anUnknownThreadStopsNothing() {
        let host = SZHost()
        let a = run(host, SZNodeID(), "run a")
        #expect(!host.cancelRun(thread: UUID()))
        #expect(host.isLive(a))
    }

    /// The pump that a Stop fires must see the world the Stop just made. Releasing the claim
    /// re-enters `pumpMailboxes` synchronously, so a run still registered in `activeRuns` at that
    /// moment makes its own freed nodes read as taken — and no pump follows.
    @Test func theNodesAStopFreesAreFreeToTheVeryPumpItFires() {
        let host = SZHost()
        let node = SZNodeID()
        let a = run(host, node, "run a")
        var takenDuringRelease: Set<SZNodeID>?
        host.ledger.onAvailabilityChanged = { takenDuringRelease = host.runWorkSet }

        host.cancelRun(thread: a.thread)

        #expect(takenDuringRelease == [])          // not [node] — the run was gone before the release
        #expect(host.runWorkSet.isEmpty)
    }

    @Test func interruptingOneRunDoesNotFreezeTheQueue() {
        let host = SZHost()
        let a = run(host, SZNodeID(), "run a")
        host.mintRun(instruction: "next")
        host.cancelRun(thread: a.thread)
        // Suspending admission is what the ALL-stop means ("I want this to stop"). Interrupting one
        // graph is narrower: the rest of the plan still stands.
        #expect(!host.admissionSuspended)
        #expect(host.pendingTasks.count == 1)
    }
}

/// The chat strip lists every build, so the host has to hand it every live thread — showing only
/// the oldest was a window onto one run in a world where three can be going.
@Suite("A surface asking what is running is told about all of it")
@MainActor
struct SZHostLiveThreadsTests {

    private func start(_ host: SZHost, _ label: String) -> SZRunState {
        let node = SZNodeID()
        let claim = SZClaimToken(label: label)
        #expect(host.ledger.tryAcquire([.node(node), .transcript(.node(node))], as: claim))
        let state = SZRunState(taskID: UUID(), claim: claim, instruction: label,
                               ownsGraphOp: false, workSet: [node])
        host.activeRuns[state.taskID] = state
        return state
    }

    @Test func everyLiveBuildIsListedOldestFirst() {
        let host = SZHost()
        let first = start(host, "first")
        let second = start(host, "second")
        let third = start(host, "third")

        #expect(host.liveThreadIDs == [first.thread, second.thread, third.thread])
    }

    @Test func aFinishedBuildLeavesTheList() {
        let host = SZHost()
        let kept = start(host, "kept")
        let gone = start(host, "gone")
        host.activeRuns[gone.taskID] = nil

        #expect(host.liveThreadIDs == [kept.thread])
    }
}

/// WHERE a waiting task is shown. The transcript used to narrate "Queued — it starts when the work
/// it needs is free." — a sentence the run strip already renders as a row that ALSO names what the
/// task is behind and offers the ✕ to drop it. Queueing is a state, and state belongs to the strip;
/// the conversation now says nothing at all about it. These tests pin the contract at its new home.
@Suite("A waiting task is shown in the strip, never narrated")
@MainActor
struct SZHostQueueNarrationTests {

    /// All of these assert unconditionally. An earlier pair branched on `pendingTasks` and asserted
    /// something in each branch, which passes whatever the code does — the exact failure the
    /// change was supposed to make impossible.
    @Test func aTaskThatIsStillWaitingBecomesAStripRowAndNotALine() {
        let host = SZHost()
        // Nothing can start here (no project, no MCP port), so every minted task genuinely waits.
        host.mintRun(instruction: "make it snow")

        #expect(host.pendingTasks.count == 1)
        #expect(host.scheduledTaskRows.count == 1)
        // Not "no Queued line" — NO line. Minting is not something the host says.
        #expect(host.store.messages(for: .director).isEmpty)
    }

    /// The strip lists what is ahead by showing it, in order — which is what "Queued behind 1 other
    /// task." was spending a sentence to approximate.
    @Test func theQueueIsShownInTheOrderItWillRun() {
        let host = SZHost()
        host.mintRun(instruction: "first", title: "first")
        host.mintRun(instruction: "second", title: "second")

        #expect(host.scheduledTaskRows.map(\.title) == ["first", "second"])
        #expect(host.store.messages(for: .director).isEmpty)
    }

    /// The strip row reads the LEDGER, so it can name the holder the sentence never could.
    @Test func aBlockedTaskNamesWhatItIsBehind() {
        let host = SZHost()
        let node = SZNodeID()
        let claim = SZClaimToken(label: "Warm Orange")
        #expect(host.ledger.tryAcquire([.node(node), .transcript(.node(node))], as: claim))

        host.mintRun(instruction: "rebuild it", title: "rebuild it", nodes: [node])

        #expect(host.scheduledTaskRows.map(\.waitingOn) == ["Warm Orange"])
    }

    /// The strip reads the QUEUE, not the world. A task that never entered the queue must not be
    /// described by a row about queueing, no matter how busy the app is.
    @Test func aLiveBuildElsewhereDoesNotMakeAnAskQueued() {
        let host = SZHost()
        let claim = SZClaimToken(label: "someone else")
        let node = SZNodeID()
        #expect(host.ledger.tryAcquire([.node(node), .transcript(.node(node))], as: claim))
        host.activeRuns[UUID()] = SZRunState(taskID: UUID(), claim: claim, instruction: "other",
                                             ownsGraphOp: false, workSet: [node])

        host.pendingTasks.removeAll()
        // Withdraw it the moment it is minted: what is pinned is that the ROW follows the queue's
        // state, so a task that leaves the queue leaves no queue presence behind either.
        let id = host.mintRun(instruction: "unrelated")
        host.withdrawTask(id)

        #expect(host.scheduledTaskRows.isEmpty)
        #expect(host.store.messages(for: .director).isEmpty)
    }
}

/// Who owns a staged split/merge. Nothing else drains one, so an op whose implementing run was
/// denied ownership is stranded for the rest of the session: pieces hidden, the node's pill stuck
/// on "Splitting", and every later split refused by the ghost.
@Suite("A staged graph op belongs to the run that staged it")
@MainActor
struct SZHostGraphOpOwnershipTests {

    private func liveRun(_ host: SZHost, _ label: String) -> SZRunState {
        let node = SZNodeID()
        let claim = SZClaimToken(label: label)
        #expect(host.ledger.tryAcquire([.node(node), .transcript(.node(node))], as: claim))
        let state = SZRunState(taskID: UUID(), claim: claim, instruction: label,
                               ownsGraphOp: false, workSet: [node])
        host.activeRuns[state.taskID] = state
        return state
    }

    @Test func aRunTakesOwnershipOnlyWhenItAsks() {
        let host = SZHost()
        // No project / MCP port here, so nothing starts; what this pins is the DEFAULT — a run
        // admitted from the queue while an op is staged never adopts it.
        let started = host.startRun(instruction: "unrelated")
        #expect(started == .waiting)
        #expect(host.activeRuns.values.allSatisfy { !$0.ownsGraphOp })
    }

    @Test func anotherLiveBuildDoesNotVetoOwnership() {
        let host = SZHost()
        _ = liveRun(host, "someone else's build")
        // The gate used to be the host-wide `!isRunning`, so this second run — the one actually
        // implementing the staged pieces — silently lost ownership whenever anything else was up.
        // The state object records what was asked for, independent of who else is running.
        let state = SZRunState(taskID: UUID(), claim: SZClaimToken(label: "op run"),
                               instruction: "split", ownsGraphOp: true, workSet: [])
        host.activeRuns[state.taskID] = state
        #expect(host.activeRuns.values.filter(\.ownsGraphOp).count == 1)
        #expect(host.isRunning)
    }
}
