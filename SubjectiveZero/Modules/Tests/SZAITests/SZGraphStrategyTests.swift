// SPDX-License-Identifier: AGPL-3.0-only
// The graph strategy driven END TO END — the REAL strategy + engine + machine together, the
// rebuild's first integration proof. Only the host boundary is stubbed: a scripted Director
// turn and coding-turn runner, a temp-dir pack root, scripted step outcomes, an identity
// router. Every scenario runs the actual pack load + validation, the actual thread machine,
// and the actual traversal engine — never a replica of any of them.
import Foundation
import Synchronization
import Testing
@testable import SZAI
@testable import SZCore

// MARK: - The test pack root

/// Write a minimal VALID two-pack library: a director whose build graph is
/// `work-left(step) --yes--> decompose(turn) --ok--> implement(dispatch)`, entering at
/// `work-left` for both `build` and `settled`; a coding pack whose item graph is the draft's
/// shape (`retrying(step)` routing cold vs continue). Step folders carry placeholder sources
/// (the tests script outcomes + declarations; nothing compiles). Templates are token-only
/// scaffolding — prompt prose ships in the real packs, not in tests.
private func makePackRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "graph-strategy-packs-\(UUID().uuidString)")
    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    try write("director/agent.json", #"{"id": "director", "seat": "director"}"#)
    try write("director/graphs/build.json", """
    {
      "name": "build", "caps": { "rounds": 2 },
      "nodes": [
        { "id": "message", "onMessage": {} },
        { "id": "work-left", "step": "work-left" },
        { "id": "decompose", "turn": { "brief": "prompts/decompose.md.mustache" } },
        { "id": "implement", "dispatch": { "to": "coding", "items": "workSet" } }
      ],
      "edges": [
        { "from": "message", "outcome": "build", "to": "work-left" },
        { "from": "message", "outcome": "settled", "to": "work-left" },
        { "from": "work-left", "outcome": "yes", "to": "decompose" },
        { "from": "decompose", "outcome": "ok", "to": "implement" }
      ]
    }
    """)
    try write("director/prompts/decompose.md.mustache",
              "DECOMPOSE r{{round}}/{{cap}}\n{{graph}}\n{{instruction}}\n")
    try write("director/steps/work-left/Step.swift", "// outcomes scripted in tests\n")

    try write("coding/agent.json", #"{"id": "coding", "seat": "coding"}"#)
    try write("coding/graphs/item.json", """
    {
      "name": "item",
      "nodes": [
        { "id": "message", "onMessage": {} },
        { "id": "retrying", "step": "retrying" },
        { "id": "implement", "turn": { "brief": "prompts/node-compile.md.mustache" } },
        { "id": "continue", "turn": { "brief": "prompts/node-reconcile.md.mustache", "session": "message" } }
      ],
      "edges": [
        { "from": "message", "outcome": "item", "to": "retrying" },
        { "from": "retrying", "outcome": "no", "to": "implement" },
        { "from": "retrying", "outcome": "yes", "to": "continue" }
      ]
    }
    """)
    try write("coding/prompts/node-compile.md.mustache", "IMPLEMENT {{node}} :: {{prompt}}\n")
    try write("coding/prompts/node-reconcile.md.mustache", "CONTINUE {{node}} :: {{blocker}}\n")
    try write("coding/steps/retrying/Step.swift", "// outcomes scripted in tests\n")
    return root
}

/// The scripted declarations the injected seam serves — what the compiled steps would export.
private let scriptedDeclarations: SZGraphDirectorStrategy.StepDeclarations = { agent, step in
    switch (agent, step) {
    case ("director", "work-left"): SZStepDeclarationInfo(outcomes: ["yes", "no"], facts: "build")
    case ("coding", "retrying"): SZStepDeclarationInfo(outcomes: ["yes", "no"], facts: "item")
    default: nil
    }
}

// MARK: - Stub seams

/// Scripted step outcomes, keyed by step name — a queue per step, last answer repeating.
/// Records every evaluation's facts document for choreography assertions.
private final class ScriptedSteps: SZStepRunning, @unchecked Sendable {
    private struct State {
        var answers: [String: [String]]
        var calls: [(step: String, facts: String)] = []
    }
    private let state: Mutex<State>

    init(_ answers: [String: [String]]) {
        state = Mutex(State(answers: answers))
    }

    var calls: [(step: String, facts: String)] { state.withLock { $0.calls } }

    func evaluate(agent: String, step: String, factsJSON: String,
                  ask: @escaping @Sendable (String) async throws -> String) async -> SZStepReport {
        let outcome: String? = state.withLock { state in
            state.calls.append((step, factsJSON))
            guard var queue = state.answers[step], !queue.isEmpty else { return nil }
            let head = queue.count == 1 ? queue[0] : queue.removeFirst()
            state.answers[step] = queue
            return head
        }
        guard let outcome else { return SZStepReport(failure: "no scripted answer for \(step)") }
        return SZStepReport(outcome: outcome)
    }
}

/// What the stubbed host boundary observed, gathered on the actor the strategy runs on.
@MainActor
private final class Recorder {
    var directorBriefs: [String] = []
    var codingTurns: [(node: SZNodeID, request: SZAgentRunRequest)] = []
    var settled: [SZSettledSummary] = []
    var codingTurnStarted = false
}

private let testBounds = SZThreadMachine.Bounds(
    roundCeiling: 8, dispatchDeadline: .seconds(900), defaultRounds: 1)

private let identityRouter = SZIdentityRouter(choice: SZModelChoice(
    providerID: "claude", model: "test-model", reasoningEffort: nil))

@MainActor
private func makeStore() -> (store: SZStore, gray: SZNodeID) {
    let camera = SZNodeID(), gray = SZNodeID()
    let graph = SZGraph(
        nodes: [
            SZNode(id: camera, kind: .generated, title: "Camera", position: SZPoint(x: 0, y: 0)),
            SZNode(id: gray, kind: .prompt, title: "Gray", prompt: "make it grayscale",
                   position: SZPoint(x: 1, y: 0)),
        ],
        connections: [
            SZConnection(from: SZPortRef(node: camera, port: "texture"),
                         to: SZPortRef(node: gray, port: "input"), kind: .data),
        ],
        renderEndpoint: SZPortRef(node: gray, port: "output"))
    let store = SZStore()
    store.setProject(SZProject(name: "t", graph: graph))
    return (store, gray)
}

private func okResult(sessionID: String?) -> SZAgentRunResult {
    SZAgentRunResult(process: SZProcessResult(exitCode: 0, output: ""),
                     outcome: SZAgentOutcome(sessionID: sessionID, failed: false))
}

@MainActor
private func makeContext(store: SZStore, recorder: Recorder,
                         codingTurn: SZCodingTurnRunner? = nil) -> SZOrchestrationContext {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "graph-strategy-run-\(UUID().uuidString)")
    return SZOrchestrationContext(
        providerID: "claude", store: store, mcpPort: 42101,
        projectURL: tmp, cacheDirectory: tmp,
        turnRunner: codingTurn ?? { node, request, _ in
            recorder.codingTurns.append((node, request))
            return okResult(sessionID: "sess-\(recorder.codingTurns.count)")
        },
        directorTurn: { prompt in
            recorder.directorBriefs.append(prompt)
            return okResult(sessionID: "director-sess")
        })
}

@MainActor
private func makeStrategy(packsRoot: URL, steps: ScriptedSteps,
                          recorder: Recorder) -> SZGraphDirectorStrategy {
    SZGraphDirectorStrategy(
        packsRoot: packsRoot, steps: steps, router: identityRouter, bounds: testBounds,
        declarations: scriptedDeclarations,
        onSettled: { recorder.settled.append($0) })
}

// MARK: - Scenarios

@MainActor
struct SZGraphStrategyTests {

    /// (a) The happy path, end to end: the build entry's step answers yes → the decompose turn
    /// runs through the Director runner → the dispatch fans the work set out → the item graph
    /// implements the node through the coding runner → the settled reply re-enters → the step
    /// answers no → the thread ends, returning the run's collected sessions.
    @Test func happyPathBuildDispatchItemsSettledConclude() async throws {
        let root = try makePackRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, gray) = makeStore()
        let steps = ScriptedSteps(["work-left": ["yes", "no"], "retrying": ["no"]])
        let recorder = Recorder()
        let context = makeContext(store: store, recorder: recorder)
        let strategy = makeStrategy(packsRoot: root, steps: steps, recorder: recorder)

        let sessions = try await strategy.run(context)

        #expect(sessions == [gray: "sess-1"])
        // The decompose brief rendered round 0 against the graph's declared cap and the live
        // graph projection.
        #expect(recorder.directorBriefs.count == 1)
        #expect(recorder.directorBriefs[0].contains("DECOMPOSE r0/2"))
        #expect(recorder.directorBriefs[0].contains("Gray"))
        // One coding turn, cold: the rendered item brief names the node + its prompt, the
        // request mirrors the frozen assembly (MCP port, package dir, router's model, no resume).
        #expect(recorder.codingTurns.count == 1)
        let request = recorder.codingTurns[0].request
        #expect(recorder.codingTurns[0].node == gray)
        #expect(request.prompt.contains("IMPLEMENT \(gray.uuidString) :: make it grayscale"))
        #expect(request.mcpServerPort == 42101)
        #expect(request.packageDirectory == context.projectURL)
        #expect(request.model == "test-model")
        #expect(request.resumeSessionID == nil)
        // The set's one settled reply carried the ok outcome, and the settled re-entry ran the
        // entry step once more, one round later.
        #expect(recorder.settled.count == 1)
        #expect(recorder.settled[0].outcomes == [gray.uuidString: "ok"])
        let workLeft = steps.calls.filter { $0.step == "work-left" }
        #expect(workLeft.count == 2)
        #expect(workLeft[0].facts.contains(#""round":0"#))
        #expect(workLeft[1].facts.contains(#""round":1"#))
        #expect(workLeft[0].facts.contains(#""workSet":["\#(gray.uuidString)"]"#))
    }

    /// (b) No work left: the entry step answers no on round 0 — the traversal ends where it
    /// stands, nothing dispatches, no Director turn is spent, and the thread ends structurally.
    @Test func noWorkLeftConcludesWithoutDispatch() async throws {
        let root = try makePackRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _) = makeStore()
        let steps = ScriptedSteps(["work-left": ["no"]])
        let recorder = Recorder()
        let strategy = makeStrategy(packsRoot: root, steps: steps, recorder: recorder)

        let sessions = try await strategy.run(makeContext(store: store, recorder: recorder))

        #expect(sessions.isEmpty)
        #expect(recorder.directorBriefs.isEmpty)
        #expect(recorder.codingTurns.isEmpty)
        #expect(recorder.settled.isEmpty)
        #expect(steps.calls.count == 1)
    }

    /// (c) A failing item: the coding turn throws — the item traversal fails, its outcome
    /// string carries the detail into the settled reply verbatim, and the settled re-entry
    /// still runs (the machine's reply → re-entry choreography).
    @Test func aFailingItemCarriesItsDetailAndTheSettledReentryRuns() async throws {
        struct Boom: Error, CustomStringConvertible {
            var description: String { "the agent exploded" }
        }
        let root = try makePackRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, gray) = makeStore()
        let steps = ScriptedSteps(["work-left": ["yes", "no"], "retrying": ["no"]])
        let recorder = Recorder()
        let context = makeContext(store: store, recorder: recorder,
                                  codingTurn: { _, _, _ in throw Boom() })
        let strategy = makeStrategy(packsRoot: root, steps: steps, recorder: recorder)

        let sessions = try await strategy.run(context)

        #expect(sessions.isEmpty)   // a failed turn leaves no session behind
        #expect(recorder.settled.count == 1)
        let outcome = try #require(recorder.settled[0].outcomes[gray.uuidString])
        #expect(outcome.hasPrefix("error: "))
        #expect(outcome.contains("the agent exploded"))
        // The settled re-entry ran — the failure closed the set, it did not end the thread.
        #expect(steps.calls.filter { $0.step == "work-left" }.count == 2)
    }

    /// (d) Cancelling the run task mid-items: the parked coding turn is cancelled, the set
    /// closes, and the thread settles cleanly as a stop — surfacing as the documented
    /// `CancellationError` (the same shape a cancelled provider turn surfaces from the frozen
    /// strategies), never a hang and never a defect.
    @Test func cancellationMidItemsSettlesAsAStop() async throws {
        let root = try makePackRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _) = makeStore()
        let steps = ScriptedSteps(["work-left": ["yes", "no"], "retrying": ["no"]])
        let recorder = Recorder()
        let context = makeContext(store: store, recorder: recorder, codingTurn: { _, _, _ in
            recorder.codingTurnStarted = true
            try await Task.sleep(for: .seconds(600))   // parks until the cancel arrives
            return okResult(sessionID: "never")
        })
        let strategy = makeStrategy(packsRoot: root, steps: steps, recorder: recorder)

        let task = Task { @MainActor in try await strategy.run(context) }
        for _ in 0..<5000 where !recorder.codingTurnStarted {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(recorder.codingTurnStarted)
        task.cancel()

        switch await task.result {
        case .success(let sessions):
            Issue.record("expected the stop to throw CancellationError, got \(sessions)")
        case .failure(let error):
            #expect(error is CancellationError, "\(error)")
        }
    }
}
