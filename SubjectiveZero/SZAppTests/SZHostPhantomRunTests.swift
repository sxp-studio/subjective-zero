// SPDX-License-Identifier: AGPL-3.0-only
// Who may schedule work. `ui_run` sits on every agent's tool surface, so a turn inside a run
// could ask for the work its own run is already doing: a second Director run, a second decompose
// turn, and a "Nothing to build there" refusal beside the first run's receipt. The gate is the
// caller's claim, never an agent name, so it holds on every provider — the per-turn tool
// allowlist is one CLI's flag, not a rule.
import Foundation
import SZCore
import Testing
@testable import SubjectiveZero

@Suite("A turn inside a run cannot schedule work")
@MainActor
struct SZHostPhantomRunTests {

    /// A host with one live run holding `nodes`, and the ledger claim that run presents.
    private func hostWithLiveRun(over nodes: Set<SZNodeID>,
                                 instruction: String = "make it warmer")
        -> (host: SZHost, bridge: SZHostBridge, claim: SZClaimToken) {
        let host = SZHost()
        let claim = SZClaimToken(label: "run (claude)")
        var resources: Set<SZResourceID> = []
        for node in nodes { resources.insert(.node(node)); resources.insert(.transcript(.node(node))) }
        #expect(host.ledger.tryAcquire(resources, as: claim))
        let run = SZRunState(taskID: UUID(), claim: claim, instruction: instruction,
                             ownsGraphOp: false, workSet: nodes)
        host.activeRuns[run.taskID] = run
        return (host, SZHostBridge(host: host), claim)
    }

    private func uiRun(_ bridge: SZHostBridge, caller: SZClaimToken?,
                       arguments: [String: Any] = [:]) throws -> [String: Any] {
        let result = try bridge.callTool(name: "ui_run", arguments: arguments,
                                         surface: .agent, caller: caller)
        guard case .text(let text) = result else { throw SZMCPError.message("expected text") }
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: - the backstop

    @Test func aTurnInsideARunIsRefusedAndSchedulesNothing() throws {
        let pair = hostWithLiveRun(over: [SZNodeID()])

        let answer = try uiRun(pair.bridge, caller: pair.claim,
                               arguments: ["instruction": "keep the HDR path byte for byte"])

        #expect(answer["status"] as? String == "refused")
        // The reason has to say what to do instead, or the agent tries again next turn.
        #expect((answer["reason"] as? String)?.contains("ui_send_chat") == true)
        // The phantom's signature at rest: a task nobody asked for, sitting in the queue.
        #expect(pair.host.pendingTasks.isEmpty)
    }

    @Test func aCodingAgentIsRefusedByTheSameRule() throws {
        // A Coding Agent's turn carries its run's claim just as a director run turn does, so one
        // rule covers both. Pinned separately because the fix is one node further out there.
        let node = SZNodeID()
        let pair = hostWithLiveRun(over: [node])

        let answer = try uiRun(pair.bridge, caller: pair.claim,
                               arguments: ["nodes": [node.uuidString]])

        #expect(answer["status"] as? String == "refused")
        #expect(pair.host.pendingTasks.isEmpty)
    }

    @Test func aChatTurnStillSchedules() throws {
        // The real caller must survive: a conversation turn deciding mid-reply that work is
        // needed is the one thing `ui_run` exists for.
        let pair = hostWithLiveRun(over: [SZNodeID()])
        let chatTurn = SZClaimToken(label: "chat turn 'director'")

        let answer = try uiRun(pair.bridge, caller: chatTurn,
                               arguments: ["instruction": "add a bloom node"])

        #expect(answer["status"] as? String == "queued")
        #expect(pair.host.pendingTasks.map(\.instruction) == ["add a bloom node"])
    }

    @Test func theBuildPressStillSchedules() throws {
        // No task-local at all — the GUI and the door's own effect mint through the same lane.
        let pair = hostWithLiveRun(over: [SZNodeID()])

        let answer = try uiRun(pair.bridge, caller: nil, arguments: ["instruction": "build it"])

        #expect(answer["status"] as? String != "refused")
        #expect(pair.host.pendingTasks.count == 1)
    }

    // MARK: - the ask that names nodes a run already holds

    @Test func namedNodesAlreadyBuildingParkTheAsk() {
        // A change cannot be folded into a build that is already generating the old code, so an
        // ask over nodes a live build holds WAITS: it stays in the queue, shows in the strip, and
        // runs its own build the moment those nodes are free. No steer rides the current build.
        let node = SZNodeID()
        let pair = hostWithLiveRun(over: [node])
        let task = SZTask(title: "make it cooler", instruction: "make it cooler",
                          workSet: [node])

        #expect(pair.host.startRun(task: task, narrateContention: false) == .waiting)
        #expect(pair.host.pendingDirectorMessages(dispatching: [node.uuidString]).isEmpty)
    }

    /// The line #48 is named for. A worded ask over a node that is built and clean used to get
    /// "Nothing to build there — say what should change", answering an ask that had just said.
    /// Words earn a run; the Director's turn is what acts on them.
    @Test func aWordedAskOverACleanNamedNodeIsNotRefusedOutright() {
        let host = SZHost()
        let node = SZNodeID()
        let task = SZTask(title: "make wrap false", instruction: "make wrap default false",
                          workSet: [node])

        // A bare host cannot actually start (no MCP port, no project), and `.waiting` is what says
        // "not refused" here — the refusal would have been terminal, dropping the ask.
        #expect(host.startRun(task: task, narrateContention: false) == .waiting)
        #expect(host.store.messages(for: .director).isEmpty)
    }

    @Test func aWordlessAskOverNodesAlreadyBuildingParksAndSendsNothing() {
        let node = SZNodeID()
        let pair = hostWithLiveRun(over: [node])
        let task = SZTask(title: "build", instruction: "", workSet: [node])

        // A repeat of work under way waits for it rather than starting a duplicate; when it is
        // admitted the nodes are built and its own decompose settles cheaply. No steer either way.
        #expect(pair.host.startRun(task: task, narrateContention: false) == .waiting)
        #expect(pair.host.pendingDirectorMessages(dispatching: [node.uuidString]).isEmpty)
    }
}
