// SPDX-License-Identifier: AGPL-3.0-only
// `chatFeed` — the one conversation, projected from the per-scope transcripts. Pins the two
// filters a node's messages pass: the run stamp (a build turn joins only under View ▸ Show Agent
// Activity) and `feedEpoch` (anything older predates the stamp, so it stays out either way).
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostChatFeedTests {
    /// `SZHost()` reads this machine's real app-state.json for its preferences, so every test
    /// here states the switch it means rather than trusting whatever the last session left.
    private func host(node: SZNode, activity: Bool = false) -> SZHost {
        let host = SZHost()
        host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: [node])))
        host.showAgentActivity = activity
        return host
    }

    private func node() -> SZNode {
        SZNode(kind: .generated, title: "Point Cloud",
               contract: SZNodeContract(title: "Point Cloud", sfSymbol: "s", summary: "",
                                        inputs: [], outputs: []),
               position: SZPoint(x: 0, y: 0))
    }

    /// A node's own reply is conversation and always shows; a build turn is the fleet's and does not.
    @Test func buildTurnsStayOutWhileActivityIsOff() {
        let n = node()
        let host = host(node: n)
        let scope = SZChatScope.node(n.id)
        host.store.appendChatMessage(SZChatMessage(role: .assistant, text: "spoke to you"), to: scope)
        let build = host.store.appendChatMessage(SZChatMessage(role: .assistant, text: "built it"),
                                                 to: scope)
        host.store.setChatGraphRun(UUID(), build, in: scope)

        #expect(host.chatFeed.map(\.message.text) == ["spoke to you"])
    }

    /// Turned on, the build's turn joins the conversation — and keeps its own scope, so the
    /// panel still labels it with the node that said it.
    @Test func buildTurnsJoinWhenActivityIsOn() {
        let n = node()
        let host = host(node: n, activity: true)
        let scope = SZChatScope.node(n.id)
        let build = host.store.appendChatMessage(SZChatMessage(role: .assistant, text: "built it"),
                                                 to: scope)
        host.store.setChatGraphRun(UUID(), build, in: scope)

        #expect(host.chatFeed.map(\.message.text) == ["built it"])
        #expect(host.chatFeed.first?.scope == scope)
    }

    /// The epoch gates BOTH ways: an old project's coding turns predate the stamp, so turning
    /// activity on must not pour its whole build history into the conversation.
    @Test func prehistoryStaysOutEvenWithActivityOn() {
        let n = node()
        let host = host(node: n, activity: true)
        let scope = SZChatScope.node(n.id)
        let old = Date(timeIntervalSince1970: 1_000)
        host.store.appendChatMessage(SZChatMessage(role: .assistant, text: "ancient",
                                                   timestamp: old), to: scope)
        host.feedEpoch = Date(timeIntervalSince1970: 2_000)

        #expect(host.chatFeed.isEmpty)
    }

    /// The Director is never filtered — it is the conversation, activity switch or not.
    @Test func directorIsAlwaysInTheFeed() {
        let host = host(node: node())
        let turn = host.store.appendChatMessage(SZChatMessage(role: .assistant, text: "thinking"),
                                                to: .director)
        host.store.setChatGraphRun(UUID(), turn, in: .director)

        #expect(host.chatFeed.map(\.message.text) == ["thinking"])
    }
}
