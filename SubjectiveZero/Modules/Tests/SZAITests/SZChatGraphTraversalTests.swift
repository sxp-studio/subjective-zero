// SPDX-License-Identifier: AGPL-3.0-only
// The director's MESSAGE LANE end-to-end through the real engine and the real
// message-bound host adapter, over the SHIPPED pack (graph + templates): the TRIAGE ask
// rules on the prose FIRST (answer → the resuming fork → a turn whose brief bytes match
// the retired direct render calls; implement → the requestBuild effect and a turn-less
// end), one completion served through the real query service per ruling, with the repair
// loop behind it.
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

// MARK: - The scripted step seam (mirrors the shipped steps' contracts)

/// `resuming` answers the fact — the ONE compiled step this graph still carries; the
/// route-reply ruling is the engine's own ask form and needs nothing scripted here.
private struct ChatSteps: SZStepRunning {
    private struct Facts: Decodable { var resuming: Bool }

    func evaluate(agent: String, step: String, factsJSON: String,
                  ask: @escaping @Sendable (String) async throws -> String) async -> SZStepReport {
        guard let facts = try? JSONDecoder().decode(Facts.self, from: Data(factsJSON.utf8)) else {
            return SZStepReport(failure: "unreadable chat facts")
        }
        switch step {
        case "resuming":
            return SZStepReport(outcome: facts.resuming ? "yes" : "no")
        default:
            return SZStepReport(failure: "unknown step '\(step)'")
        }
    }
}

// MARK: - The world

/// A lock-boxed event list the escaping seams append into (the query executor is a
/// `@Sendable` closure, so a plain MainActor box cannot serve all three recorders).
private final class Recorder<Element: Sendable>: Sendable {
    private let store = Mutex<[Element]>([])
    func append(_ element: Element) { store.withLock { $0.append(element) } }
    var values: [Element] { store.withLock { $0 } }
}

/// The LIVE graph the adapter reads — mutable so a turn can draft work mid-traversal.
@MainActor
private final class GraphBox {
    var graph: SZGraph
    init(_ graph: SZGraph) { self.graph = graph }
}

private func fixtureNode(_ title: String, kind: SZNodeKind) -> SZNode {
    SZNode(kind: kind, title: title,
           contract: SZNodeContract(title: title, sfSymbol: "circle", summary: "",
                                    outputs: [SZPort(name: "output", type: .texture)]),
           position: SZPoint(x: 0, y: 0))
}

/// One built node and one PRE-EXISTING draft: work that already needed implementation at
/// delivery must never read as this turn's drafting.
@MainActor
private func fixtureGraph() -> SZGraph {
    SZGraph(nodes: [fixtureNode("Camera", kind: .generated),
                    fixtureNode("Glow", kind: .prompt)])
}

// MARK: - The harness

@MainActor
private final class ChatWorld {
    let box: GraphBox
    let effects: Recorder<String>
    let queryPrompts: Recorder<String>
    let turns: Recorder<(brief: String, session: SZAgentGraph.Turn.Session)>
    let engine: SZGraphEngine

    /// `resuming` picks the fork; `rulingReply` scripts the query executor; `turnDrafts`
    /// makes the TURN add a fresh prompt node to the live graph (the drafted-work case).
    init(resuming: Bool, rulingReply: String = #"{"outcome": "answer"}"#,
         turnDrafts: Bool = false) throws {
        let loaded = SZAgentPackLoader.load(root: shippedPacksRoot)
        let director = try #require(loaded.packs.first { $0.id == "director" })
        let graph = try #require(director.graph(routing: .message))
        let attachments = [
            "resuming": SZStepAttachment(outcomes: ["yes", "no"]),
        ]
        let renderer = SZBriefRenderer(packRoot: shippedPacksRoot)
        let router = SZIdentityRouter(choice: SZModelChoice(providerID: "claude",
                                                            model: nil, reasoningEffort: nil))
        let box = GraphBox(fixtureGraph())
        let effects = Recorder<String>()
        let queryPrompts = Recorder<String>()
        let turns = Recorder<(brief: String, session: SZAgentGraph.Turn.Session)>()
        let queries = SZQueryService(
            renderer: renderer, router: router,
            cacheDirectory: FileManager.default.temporaryDirectory
                .appending(path: "sz-chat-traversal-\(UUID().uuidString)"),
            executor: { request, _ in
                queryPrompts.append(request.prompt)
                return rulingReply
            })
        let host = SZChatTraversalHost(
            message: "make it warmer", resuming: resuming,
            renderer: renderer, graphName: graph.name, queries: queries,
            liveGraph: { box.graph },
            turn: { order in
                turns.append((order.brief, order.session))
                if turnDrafts {
                    box.graph.nodes.append(fixtureNode("Soft Glow", kind: .prompt))
                }
                return SZTurnReport(failed: false)
            },
            effect: { name, kind in
                #expect(kind == .message)
                effects.append(name)
            })
        self.box = box
        self.effects = effects
        self.queryPrompts = queryPrompts
        self.turns = turns
        self.engine = SZGraphEngine(agent: director.id, graph: graph,
                                    attachments: attachments, host: host,
                                    steps: ChatSteps(), router: router)
    }
}

// MARK: - Tests

@MainActor
struct SZChatGraphTraversalTests {

    @Test func anAnswerRulingRunsTheColdTurnWithThePinnedBriefBytes() async throws {
        let world = try ChatWorld(resuming: false)
        let result = await world.engine.run(kind: .message)
        // Triage first, turn second, and the turn's ending IS the traversal's — no
        // post-turn ruling exists any more.
        #expect(result.conclusion == .ended(node: "cold", outcome: "ok"))
        let turns = world.turns.values
        #expect(turns.count == 1)
        #expect(turns.first?.session == .spawn)
        // The SAME bytes the retired direct render call produced — the gate's contract,
        // asserted across the two living paths.
        #expect(turns.first?.brief
            == SZDirectorPrompt.renderChat(graph: world.box.graph, message: "make it warmer"))
        #expect(world.effects.values.isEmpty)
        // The triage completion carries the user's prose into the pack's template.
        let prompts = world.queryPrompts.values
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains("make it warmer") == true)
        #expect(prompts.first?.contains(#"{"outcome": "answer"}"#) == true)
    }

    @Test func anAnswerRulingRunsTheResumedBriefOverItsSession() async throws {
        let world = try ChatWorld(resuming: true)
        let result = await world.engine.run(kind: .message)
        #expect(result.conclusion == .ended(node: "resumed", outcome: "ok"))
        let turns = world.turns.values
        #expect(turns.count == 1)
        #expect(turns.first?.session == .message)
        #expect(turns.first?.brief
            == SZDirectorPrompt.renderResumedChat(graph: world.box.graph, message: "make it warmer"))
    }

    @Test func anImplementRulingFiresTheBuildAndRunsNoTurn() async throws {
        // The front-door triage: "build this" never spends a conversational turn — the
        // ruling fires the requestBuild effect and the traversal ends at the ask.
        let world = try ChatWorld(resuming: false, rulingReply: #"{"outcome": "implement"}"#)
        let result = await world.engine.run(kind: .message)
        #expect(result.conclusion == .ended(node: "triage", outcome: "implement"))
        #expect(world.effects.values == ["requestBuild"])
        #expect(world.turns.values.isEmpty)
        #expect(world.queryPrompts.values.count == 1)
    }

    @Test func aMalformedRulingIsRepairedOnceThenRuled() async throws {
        // The ask form's repair loop: prose first, prose again — two completions total,
        // the second carrying the repair framing, then an honest defect.
        let world = try ChatWorld(resuming: false, rulingReply: "let me think about that")
        let result = await world.engine.run(kind: .message)
        guard case .defect(let node, _) = result.conclusion else {
            Issue.record("prose twice must defect honestly, got \(result.conclusion)")
            return
        }
        #expect(node == "triage")
        #expect(world.queryPrompts.values.count == 2)
        #expect(world.queryPrompts.values.last?.contains("previous reply did not decode") == true)
        #expect(world.effects.values.isEmpty)
        #expect(world.turns.values.isEmpty)
    }
}
