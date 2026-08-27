// SPDX-License-Identifier: AGPL-3.0-only
// `chatFeed` — the one conversation, projected from the per-scope transcripts. Every node
// message joins it, build turns included; the one filter left is `feedEpoch`, which keeps a
// project's pre-stamp history out.
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostChatFeedTests {
    private func host(node: SZNode) -> SZHost {
        let host = SZHost()
        host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: [node])))
        return host
    }

    private func node() -> SZNode {
        SZNode(kind: .generated, title: "Point Cloud",
               contract: SZNodeContract(title: "Point Cloud", sfSymbol: "s", summary: "",
                                        inputs: [], outputs: []),
               position: SZPoint(x: 0, y: 0))
    }

    /// A build turn is the fleet working, and watching it work is the point: it joins the
    /// conversation beside the node's own replies, in the order they were said.
    @Test func buildTurnsAreInTheFeed() {
        let n = node()
        let host = host(node: n)
        let scope = SZChatScope.node(n.id)
        host.store.appendChatMessage(SZChatMessage(role: .assistant, text: "spoke to you"), to: scope)
        let build = host.store.appendChatMessage(SZChatMessage(role: .assistant, text: "built it"),
                                                 to: scope)
        host.store.setChatGraphRun(UUID(), build, in: scope)

        #expect(host.chatFeed.map(\.message.text) == ["spoke to you", "built it"])
    }

    /// A build turn keeps its own scope, so the panel labels it with the node that said it.
    @Test func aBuildTurnKeepsTheNodeThatSaidIt() {
        let n = node()
        let host = host(node: n)
        let scope = SZChatScope.node(n.id)
        let build = host.store.appendChatMessage(SZChatMessage(role: .assistant, text: "built it"),
                                                 to: scope)
        host.store.setChatGraphRun(UUID(), build, in: scope)

        #expect(host.chatFeed.first?.scope == scope)
    }

    /// The epoch is the one filter left: an old project's coding turns predate the stamp, so
    /// opening it must not pour its whole build history into the conversation.
    @Test func prehistoryStaysOut() {
        let n = node()
        let host = host(node: n)
        let scope = SZChatScope.node(n.id)
        let old = Date(timeIntervalSince1970: 1_000)
        host.store.appendChatMessage(SZChatMessage(role: .assistant, text: "ancient",
                                                   timestamp: old), to: scope)
        host.feedEpoch = Date(timeIntervalSince1970: 2_000)

        #expect(host.chatFeed.isEmpty)
    }

    /// The Director is never filtered — it is the conversation.
    @Test func directorIsAlwaysInTheFeed() {
        let host = host(node: node())
        let turn = host.store.appendChatMessage(SZChatMessage(role: .assistant, text: "thinking"),
                                                to: .director)
        host.store.setChatGraphRun(UUID(), turn, in: .director)

        #expect(host.chatFeed.map(\.message.text) == ["thinking"])
    }
}
