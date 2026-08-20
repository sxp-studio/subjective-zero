// SPDX-License-Identifier: AGPL-3.0-only
// The SHIPPED director graph end-to-end through the real engine: the door decides —
// a granted build goes straight to the build lane with ZERO model calls; prose is triaged
// through the real query service over the pack's own triage template, and an `implement`
// ruling fires `requestBuild` and ends without a turn. The door's Swift is compiled only
// in the app, so a scripted step mirrors its contract here; the graph, templates, and
// serving path are the real ones.
import Foundation
import Synchronization
import Testing
@testable import SZAI
@testable import SZCore

private let shippedPacksRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()   // SZAITests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // Modules
    .appending(path: "Sources/SZAI/Resources/Agents")

// MARK: - The scripted steps (mirroring the shipped doors' contracts)

/// The director's door and work-left gate, as the shipped Step.swift files decide them:
/// a live run routes `build` before any ask; prose is triaged through the engine-provided
/// ask closure; `implement` rides the requestBuild effect.
private struct DirectorSteps: SZStepRunning {
    private struct Facts: Decodable {
        var resuming: Bool
        var run: Run?
        struct Run: Decodable { var workSet: [UUID] }
    }
    private struct Ruling: Decodable { let outcome: String }

    func evaluate(agent: String, step: String, factsJSON: String,
                  ask: @escaping @Sendable (String) async throws -> String) async -> SZStepReport {
        guard let facts = try? JSONDecoder().decode(Facts.self, from: Data(factsJSON.utf8)) else {
            return SZStepReport(failure: "unreadable facts")
        }
        switch step {
        case "door":
            if facts.run != nil { return SZStepReport(outcome: "build") }
            do {
                let reply = try await ask(#"{"template": "triage", "attempt": 0}"#)
                guard let ruling = try? JSONDecoder().decode(Ruling.self, from: Data(reply.utf8)) else {
                    return SZStepReport(failure: "triage reply did not decode: \(reply)")
                }
                if ruling.outcome == "implement" {
                    return SZStepReport(outcome: "implement", effects: ["requestBuild"])
                }
                return SZStepReport(outcome: facts.resuming ? "answer-resumed" : "answer")
            } catch {
                return SZStepReport(failure: String(describing: error))
            }
        case "work-left":
            // The stub world never shrinks, so the gate is scripted: the run is done after
            // its first fleet.
            return SZStepReport(outcome: "no")
        default:
            return SZStepReport(failure: "unknown step '\(step)'")
        }
    }
}

// MARK: - The world

/// A lock-boxed event list the escaping seams append into.
private final class Recorder<Element: Sendable>: Sendable {
    private let store = Mutex<[Element]>([])
    func append(_ element: Element) { store.withLock { $0.append(element) } }
    var values: [Element] { store.withLock { $0 } }
}

private func fixtureNode(_ title: String, kind: SZNodeKind) -> SZNode {
    SZNode(kind: kind, title: title,
           contract: SZNodeContract(title: title, sfSymbol: "circle", summary: "",
                                    outputs: [SZPort(name: "output", type: .texture)]),
           position: SZPoint(x: 0, y: 0))
}

// MARK: - The harness

@MainActor
private final class DirectorDelivery: SZTraversalServing {
    let message: String
    let world: SZWorld
    let queries: SZQueryService
    let effects = Recorder<SZEffect>()
    let queryPrompts: Recorder<String>
    let turns = Recorder<(brief: String, session: SZAgentGraph.Turn.Session)>()
    let renderer: SZBriefRenderer
    /// Scripted fleet summaries; empty = a delivery with no fleet.
    var summaries: [SZSettledSummary?] = []

    init(message: String, world: SZWorld, rulingReply: String) {
        let prompts = Recorder<String>()
        self.message = message
        self.world = world
        self.queryPrompts = prompts
        self.renderer = SZBriefRenderer(packRoot: shippedPacksRoot)
        self.queries = SZQueryService(
            renderer: renderer,
            router: SZIdentityRouter(choice: SZModelChoice(providerID: "claude",
                                                           model: nil, reasoningEffort: nil)),
            cacheDirectory: FileManager.default.temporaryDirectory
                .appending(path: "sz-door-traversal-\(UUID().uuidString)"),
            executor: { request, _ in
                prompts.append(request.prompt)
                return rulingReply
            })
    }

    func facts() -> SZFacts { world.facts(message: message) }
    func render(template: String) throws -> String {
        try renderer.render(agent: "director", template: template,
                            message: message, world: world)
    }
    func runTurn(_ order: SZTurnOrder) async -> SZTurnReport {
        turns.append((order.brief, order.session))
        return SZTurnReport(failed: false)
    }
    func serveAsk(step: String, slot: String?, requestJSON: String) async throws -> String {
        try await queries.serve(agent: "director", step: step, message: message,
                                world: world, requestJSON: requestJSON)
    }
    func perform(effect: SZEffect) async { effects.append(effect) }
    func deliver(orders: [SZWorkOrder], to seat: String,
                 progress: @escaping @MainActor @Sendable (SZAgentGraphRun.Tally) -> Void)
        async -> SZSettledSummary? {
        summaries.isEmpty ? nil : summaries.removeFirst()
    }
    func note(_ note: SZTraversalNote) {}
}

private let directorAttachments = [
    "door": SZStepAttachment(outcomes: ["build", "answer", "answer-resumed", "implement"]),
    "unresolved": SZStepAttachment(outcomes: ["yes", "no"]),
]

@MainActor
private func makeEngine(_ delivery: DirectorDelivery) throws -> SZGraphEngine {
    let loaded = SZAgentPackLoader.load(root: shippedPacksRoot)
    let director = try #require(loaded.packs.first { $0.id == "director" })
    let graph = try #require(director.graph)
    return SZGraphEngine(agent: director.id, graph: graph, attachments: directorAttachments,
                        host: delivery, steps: DirectorSteps(),
                        router: SZIdentityRouter(choice: SZModelChoice(providerID: "claude",
                                                                       model: nil,
                                                                       reasoningEffort: nil)))
}

// MARK: - Tests

@MainActor
struct SZDirectorGraphTraversalTests {

    private func world(resuming: Bool = false, run: SZRun? = nil) -> SZWorld {
        SZWorld(graph: SZGraph(nodes: [fixtureNode("Camera", kind: .generated),
                                       fixtureNode("Glow", kind: .prompt)]),
                resuming: resuming, run: run)
    }

    @Test func anAnswerRulingRunsTheColdTurn() async throws {
        let delivery = DirectorDelivery(message: "make it warmer",
                                        world: world(),
                                        rulingReply: #"{"outcome": "answer"}"#)
        let result = try await makeEngine(delivery).run()
        // Triage first, turn second, and the turn's ending IS the traversal's.
        #expect(result.conclusion == .ended(node: "chat", outcome: "ok"))
        let turns = delivery.turns.values
        #expect(turns.count == 1)
        #expect(turns.first?.session == .spawn)
        #expect(turns.first?.brief.contains("make it warmer") == true)
        #expect(delivery.effects.values.isEmpty)
        // The triage completion carried the user's prose into the pack's own template.
        let prompts = delivery.queryPrompts.values
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains("make it warmer") == true)
        #expect(prompts.first?.contains(#"{"outcome": "answer"}"#) == true)
    }

    @Test func anAnswerRulingResumesTheSessionWhenTheScopeKnowsUs() async throws {
        let delivery = DirectorDelivery(message: "now dim the highlights",
                                        world: world(resuming: true),
                                        rulingReply: #"{"outcome": "answer"}"#)
        let result = try await makeEngine(delivery).run()
        #expect(result.conclusion == .ended(node: "chat-resumed", outcome: "ok"))
        #expect(delivery.turns.values.first?.session == .resume)
    }

    @Test func anImplementRulingFiresTheBuildAndRunsNoTurn() async throws {
        // "build this" never spends a conversational turn — the door's ruling fires the
        // requestBuild effect and the traversal ends at the door's unwired outcome.
        let delivery = DirectorDelivery(message: "build it",
                                        world: world(),
                                        rulingReply: #"{"outcome": "implement"}"#)
        let result = try await makeEngine(delivery).run()
        #expect(result.conclusion == .ended(node: SZAgentGraph.doorID, outcome: "implement"))
        #expect(delivery.effects.values == [.requestBuild])
        #expect(delivery.turns.values.isEmpty)
        #expect(delivery.queryPrompts.values.count == 1)
    }

    @Test func aGrantedBuildRunsTheWholeLaneWithZeroModelCalls() async throws {
        // The fleet path is deterministic: a live run routes `build` in door CODE — no
        // triage, no tokens — then decompose, the waiting dispatch, and the settled loop's
        // gate ending the run when nothing is owed.
        let node = UUID()
        let delivery = DirectorDelivery(
            message: "",
            world: world(run: SZRun(workSet: [node], round: 0, roundCap: 2,
                                    steers: [], instruction: "make it gray")),
            rulingReply: "never asked")
        delivery.summaries = [SZSettledSummary(setID: 1, from: "coding",
                                               outcomes: [node.uuidString: "ok"], round: 1)]
        let result = try await makeEngine(delivery).run()
        #expect(result.conclusion == .ended(node: "unresolved", outcome: "no"))
        // Decompose ran as the lane's one turn; NOTHING asked a model.
        #expect(delivery.turns.values.count == 1)
        #expect(delivery.turns.values.first?.session == .spawn)
        #expect(delivery.queryPrompts.values.isEmpty)
        #expect(delivery.effects.values.isEmpty)
    }
}
