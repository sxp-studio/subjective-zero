// SPDX-License-Identifier: AGPL-3.0-only
// The director's CHAT GRAPH end-to-end through the real engine and the real chat-bound
// host adapter, over the SHIPPED pack (graph + templates): the resuming fork renders the
// SAME bytes the retired direct render calls produced, the turn streams through the
// injected runner, and the route-reply ruling ends the traversal — answer/plan bare,
// build with the requestBuild effect. `resuming` is the one scripted step; route-reply is
// an ASK NODE now — engine-native, no compiled step — so what this suite pins is the whole
// declarative lane: the pack's route-reply template rendered against the live facts, ONE
// completion served through the real query service, the {"outcome"} ruling routed, and
// only `build` carrying the effect.
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
        let graph = try #require(director.graph(routing: .chat))
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
                #expect(kind == .chat)
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

    @Test func aColdTurnRendersTheChatBriefBytesAndSpawnsFresh() async throws {
        let world = try ChatWorld(resuming: false)
        let result = await world.engine.run(kind: .chat)
        #expect(result.conclusion == .ended(node: "route-reply", outcome: "answer"))
        let turns = world.turns.values
        #expect(turns.count == 1)
        #expect(turns.first?.session == .spawn)
        // The SAME bytes the retired direct render call produced — the gate's contract,
        // asserted across the two living paths.
        #expect(turns.first?.brief
            == SZDirectorPrompt.renderChat(graph: world.box.graph, message: "make it warmer"))
        #expect(world.effects.values.isEmpty)
    }

    @Test func aResumedTurnRendersTheResumedBriefOverItsSession() async throws {
        let world = try ChatWorld(resuming: true)
        let result = await world.engine.run(kind: .chat)
        #expect(result.conclusion == .ended(node: "route-reply", outcome: "answer"))
        let turns = world.turns.values
        #expect(turns.count == 1)
        #expect(turns.first?.session == .message)
        #expect(turns.first?.brief
            == SZDirectorPrompt.renderResumedChat(graph: world.box.graph, message: "make it warmer"))
    }

    @Test func aTypedBuildRulingFiresTheEffectThroughOneServedQuery() async throws {
        let world = try ChatWorld(resuming: false, rulingReply: #"{"outcome": "build"}"#)
        let result = await world.engine.run(kind: .chat)
        #expect(result.conclusion == .ended(node: "route-reply", outcome: "build"))
        #expect(world.effects.values == ["requestBuild"])
        // One completion, rendered from the PACK's route-reply template against the live
        // facts — the user's message travels into the classification ask.
        let prompts = world.queryPrompts.values
        #expect(prompts.count == 1)
        #expect(prompts.first?.contains("make it warmer") == true)
        #expect(prompts.first?.contains(#"{"outcome": "answer"}"#) == true)
    }

    @Test func aPlanRulingEndsTheTraversalWithNoEffect() async throws {
        let world = try ChatWorld(resuming: false, rulingReply: #"{"outcome": "plan"}"#)
        let result = await world.engine.run(kind: .chat)
        #expect(result.conclusion == .ended(node: "route-reply", outcome: "plan"))
        #expect(world.effects.values.isEmpty)
    }

    @Test func aMalformedRulingIsRepairedOnceThenRuled() async throws {
        // The ask form's repair loop: prose first, the typed object on the re-ask — two
        // completions total, the second carrying the repair framing.
        let world = try ChatWorld(resuming: false, rulingReply: "let me think about that")
        let result = await world.engine.run(kind: .chat)
        guard case .defect(let node, _) = result.conclusion else {
            Issue.record("prose twice must defect honestly, got \(result.conclusion)")
            return
        }
        #expect(node == "route-reply")
        #expect(world.queryPrompts.values.count == 2)
        #expect(world.queryPrompts.values.last?.contains("previous reply did not decode") == true)
        #expect(world.effects.values.isEmpty)
    }
}
