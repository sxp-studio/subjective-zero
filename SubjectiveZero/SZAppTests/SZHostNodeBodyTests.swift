// SPDX-License-Identifier: AGPL-3.0-only
// `applyNodeBody` — the ONE resolve+apply path for a node card's body (MCP `ui_set_node_body`, the
// context-menu card toggle, auto-size, the failed chip). Pins the
// validation each mode carries and that a `.custom` body is refused without a `Card.swift` on disk
// (geometry never reserves a region nothing can fill). The mounted-card path itself needs a
// project on disk + swiftc, so it's exercised by the live drive, not here.
import Foundation
import Testing
import SZCore
import SZUI
@testable import SubjectiveZero

@MainActor
struct SZHostNodeBodyTests {
    private func host(with node: SZNode) -> SZHost {
        let host = SZHost()
        host.store.setProject(SZProject(name: "t", graph: SZGraph(nodes: [node])))
        return host
    }

    private func textureNode() -> SZNode {
        SZNode(kind: .generated, title: "T",
               contract: SZNodeContract(title: "T", sfSymbol: "s", summary: "",
                                        inputs: [SZPort(name: "amount", type: .float)],
                                        outputs: [SZPort(name: "output", type: .texture, display: true),
                                                  SZPort(name: "level", type: .float)]),
               position: SZPoint(x: 0, y: 0))
    }

    @Test func noneAndPreviewResolveAgainstTheContract() throws {
        let node = textureNode()
        let host = host(with: node)
        #expect(try host.applyNodeBody(node: node.id, mode: .none) == SZNodeBody(mode: .none))
        // Preview picks the preferred texture output when no port is given …
        #expect(try host.applyNodeBody(node: node.id, mode: .preview).previewPort == "output")
        // … honours an explicit texture output, and refuses a non-texture one.
        #expect(try host.applyNodeBody(node: node.id, mode: .preview, port: "output").previewPort == "output")
        #expect(throws: SZHost.NodeBodyError.self) {
            try host.applyNodeBody(node: node.id, mode: .preview, port: "level")
        }
        // The applied body is what the store holds.
        #expect(host.store.project?.graph.node(id: node.id)?.body?.mode == .preview)
    }

    // MARK: - Folding the plugs

    @Test func foldingHoldsTheCardsTopEdge() throws {
        var node = textureNode()
        node.position = SZPoint(x: 0, y: 0)
        let host = host(with: node)
        _ = try host.applyNodeBody(node: node.id, mode: .preview)

        let before = host.store.project!.graph.node(id: node.id)!
        let topBefore = SZNodeLayout.cardRect(of: before).minY

        #expect(host.toggleNodePlugs(node: node.id)?.plugs == false)
        let folded = host.store.project!.graph.node(id: node.id)!
        #expect(!SZNodeLayout.showsPlugs(of: folded))
        #expect(SZNodeLayout.height(of: folded) < SZNodeLayout.height(of: before))
        #expect(SZNodeLayout.cardRect(of: folded).minY == topBefore, "the header must not move")

        // …and unfolding puts it back exactly.
        #expect(host.toggleNodePlugs(node: node.id)?.plugs == true)
        let reopened = host.store.project!.graph.node(id: node.id)!
        #expect(reopened.position.y == before.position.y)
        #expect(SZNodeLayout.cardRect(of: reopened).minY == topBefore)
    }

    /// The card host re-applies `.custom` with fresh rows all session long (auto-size, backdrop
    /// aspect). A fold must survive that, or a card would silently unfold while it settles.
    @Test func foldSurvivesAReapply() throws {
        let node = textureNode()
        let host = host(with: node)
        _ = try host.applyNodeBody(node: node.id, mode: .preview)
        _ = host.toggleNodePlugs(node: node.id)
        // A retarget of the preview port carries the fold forward.
        #expect(try host.applyNodeBody(node: node.id, mode: .preview, port: "output").plugs == false)
        // And an explicit override still wins.
        #expect(try host.applyNodeBody(node: node.id, mode: .preview, plugs: true).plugs == true)
    }

    @Test func aCardWithNoBodyRefusesToFold() {
        // No texture output and no card: nothing to show in place of the rows.
        let node = SZNode(kind: .generated, title: "Add",
                          contract: SZNodeContract(title: "Add", sfSymbol: "s", summary: "",
                                                   inputs: [SZPort(name: "a", type: .float)],
                                                   outputs: [SZPort(name: "sum", type: .float)]),
                          position: SZPoint(x: 0, y: 0))
        let host = host(with: node)
        #expect(host.toggleNodePlugs(node: node.id) == nil)
        #expect(host.store.project?.graph.node(id: node.id)?.body == nil)
    }

    @Test func customNeedsACardSourceOnDisk() {
        let node = textureNode()
        let host = host(with: node)
        // No project folder → no Card.swift → refused, and the body is left untouched.
        #expect(!host.nodeHasCardSource(node.id))
        #expect(throws: SZHost.NodeBodyError.self) {
            try host.applyNodeBody(node: node.id, mode: .custom)
        }
        #expect(host.store.project?.graph.node(id: node.id)?.body == nil)
    }

    @Test func aPromptCardHasNoBody() {
        let prompt = SZNode(kind: .prompt, title: "P", position: SZPoint(x: 0, y: 0))
        let host = host(with: prompt)
        #expect(throws: SZHost.NodeBodyError.self) {
            try host.applyNodeBody(node: prompt.id, mode: .preview)
        }
    }
}
