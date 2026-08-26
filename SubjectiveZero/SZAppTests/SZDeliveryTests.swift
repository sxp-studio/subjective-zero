// SPDX-License-Identifier: AGPL-3.0-only
// The delivery's snapshot rule: a step evaluation and its asks see ONE pinned
// (message, world) pair — `facts()` pins, `serveAsk` renders against the pin, and a world
// that moves mid-evaluation (a fleet child promoting a node, a status landing) must not
// leak into an ask the step already started. The comment on `SZDelivery.pinned` claimed
// this; this makes it load-bearing.
import Foundation
import Synchronization
import Testing
import SZAI
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZDeliveryTests {

    @Test func anAskRendersAgainstTheEvaluationsPinnedSnapshot() async throws {
        let prompts = Mutex<[String]>([])
        let renderer = SZBriefRenderer { _, path in
            path == "prompts/probe.md.mustache" ? "round {{round}}" : ""
        }
        let queries = SZQueryService(
            renderer: renderer,
            router: SZIdentityRouter(choice: SZModelChoice(providerID: "claude", model: nil,
                                                           reasoningEffort: nil)),
            cacheDirectory: FileManager.default.temporaryDirectory
                .appending(path: "sz-delivery-test-\(UUID().uuidString)"),
            executor: { request, _ in
                prompts.withLock { $0.append(request.prompt) }
                return "{}"
            })
        var round = 1
        let delivery = SZDelivery(
            agent: "director", message: "", renderer: renderer, queries: queries,
            world: { SZWorld(run: SZRun(workSet: [], round: round, roundCap: 3,
                                        steers: [], instruction: "")) },
            turn: { _, _ in SZTurnReport(failed: true, detail: "no turns in this test") },
            effect: { _ in }, onNote: { _ in })

        _ = delivery.facts()   // the evaluation starts: round 1 is pinned
        round = 2              // the world moves underneath it
        _ = try await delivery.serveAsk(step: "probe", slot: nil,
                                        requestJSON: #"{"template": "probe", "attempt": 0}"#)
        #expect(prompts.withLock { $0 } == ["round 1"])
    }

    @Test func theConversationIsTheWorldsProjectionFormattedForATurn() {
        // The delivery adds nothing of its own: what the host projects is what a turn reads.
        let renderer = SZBriefRenderer { _, _ in "" }
        let queries = SZQueryService(
            renderer: renderer,
            router: SZIdentityRouter(choice: SZModelChoice(providerID: "claude", model: nil,
                                                           reasoningEffort: nil)),
            cacheDirectory: FileManager.default.temporaryDirectory
                .appending(path: "sz-delivery-test-\(UUID().uuidString)"),
            executor: { _, _ in "{}" })
        var messages: [SZChatMessage] = []
        let delivery = SZDelivery(
            agent: "director", message: "", renderer: renderer, queries: queries,
            world: { SZWorld(conversation: messages) },
            turn: { _, _ in SZTurnReport(failed: true, detail: "no turns in this test") },
            effect: { _ in }, onNote: { _ in })
        #expect(delivery.conversation() == nil)
        messages = [SZChatMessage(role: .user, text: "hello")]
        #expect(delivery.conversation()?.contains("user: hello") == true)
    }

    @Test func aMentionInTheConversationResolvesAgainstTheWorldsGraph() {
        let renderer = SZBriefRenderer { _, _ in "" }
        let queries = SZQueryService(
            renderer: renderer,
            router: SZIdentityRouter(choice: SZModelChoice(providerID: "claude", model: nil,
                                                           reasoningEffort: nil)),
            cacheDirectory: FileManager.default.temporaryDirectory
                .appending(path: "sz-delivery-test-\(UUID().uuidString)"),
            executor: { _, _ in "{}" })
        let glow = SZNode(kind: .prompt, title: "Glow",
                          contract: SZNodeContract(title: "Glow", sfSymbol: "circle", summary: "",
                                                   outputs: [SZPort(name: "output", type: .texture)]),
                          position: SZPoint(x: 0, y: 0))
        let text = SZMentionMarkup.encode([.text("tweak "), .mention(.node(glow.id), display: "Glow")])
        let delivery = SZDelivery(
            agent: "director", message: "", renderer: renderer, queries: queries,
            world: { SZWorld(graph: SZGraph(nodes: [glow]),
                             conversation: [SZChatMessage(role: .user, text: text)]) },
            turn: { _, _ in SZTurnReport(failed: true, detail: "no turns in this test") },
            effect: { _ in }, onNote: { _ in })
        let recap = delivery.conversation() ?? ""
        #expect(recap.contains("user: tweak @Glow"))
        #expect(recap.contains("Mentioned in the conversation above:"))
        #expect(recap.contains(glow.id.uuidString))
    }
}
