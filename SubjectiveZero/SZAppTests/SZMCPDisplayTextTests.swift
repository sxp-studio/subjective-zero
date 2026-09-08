// SPDX-License-Identifier: AGPL-3.0-only
// Card text an agent sends over MCP (title, summary) round-trips verbatim, and an HTML-escaped
// title is decoded at the boundary rather than shown as `&amp;` on the card.
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZMCPDisplayTextTests {
    private let nodeID = SZNodeID()

    private func host() -> SZHost {
        let node = SZNode(id: nodeID, kind: .generated, title: "Effect",
                          contract: SZNodeContract(title: "Effect", sfSymbol: "s", summary: "",
                                                   inputs: [], outputs: []),
                          position: SZPoint(x: 0, y: 0))
        let host = SZHost()
        host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: [node])))
        return host
    }

    @Test func aPlainAmpersandRoundTrips() throws {
        let host = host()
        _ = try SZHostBridge(host: host).callTool(
            name: "ui_update_node", arguments: ["node": nodeID.uuidString, "title": "A & B"],
            callerScope: .director)
        #expect(host.store.project?.graph.node(id: nodeID)?.title == "A & B")
    }

    @Test func anEscapedTitleIsDecodedAtTheBoundary() throws {
        let host = host()
        _ = try SZHostBridge(host: host).callTool(
            name: "ui_update_node",
            arguments: ["node": nodeID.uuidString, "title": "Swirl &amp; Trails",
                        "summary": "a &lt;b&gt; &quot;c&quot; &#39;d&#39; &apos;e&apos;"],
            callerScope: .director)
        let node = host.store.project?.graph.node(id: nodeID)
        #expect(node?.title == "Swirl & Trails")
        #expect(node?.contract?.title == "Swirl & Trails")
        #expect(node?.contract?.summary == "a <b> \"c\" 'd' 'e'")
    }

    @Test func promptTextStaysVerbatim() throws {
        let host = host()
        _ = try SZHostBridge(host: host).callTool(
            name: "ui_update_node", arguments: ["node": nodeID.uuidString, "prompt": "draw &amp;"],
            callerScope: .director)
        #expect(host.store.project?.graph.node(id: nodeID)?.prompt == "draw &amp;")
    }
}
