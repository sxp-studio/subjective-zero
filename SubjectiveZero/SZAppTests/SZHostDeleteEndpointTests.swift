// SPDX-License-Identifier: AGPL-3.0-only
// Deleting the node that holds the viewport must not leave the viewport black. The host adopts a
// survivor through the run's own rule (`runRenderEndpoint`), so the two refusals that rule exists for
// must hold here too: a node that is not `.generated` can declare a texture it cannot render, and a
// staged split/merge piece is still hidden.
import Foundation
import Testing
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostDeleteEndpointTests {

    private func texNode(_ title: String, kind: SZNodeKind = .generated, inputs: [String] = []) -> SZNode {
        SZNode(kind: kind, title: title,
               contract: SZNodeContract(title: title, sfSymbol: "circle", summary: "",
                                        inputs: inputs.map { SZPort(name: $0, type: .texture) },
                                        outputs: [SZPort(name: "output", type: .texture, display: true)]),
               position: SZPoint(x: 0, y: 0))
    }

    private func data(_ from: SZNode, _ to: SZNode) -> SZConnection {
        SZConnection(from: SZPortRef(node: from.id, port: "output"),
                     to: SZPortRef(node: to.id, port: "input"), kind: .data)
    }

    private func host(_ nodes: [SZNode], _ connections: [SZConnection], endpoint: SZNode) -> SZHost {
        var graph = SZGraph(nodes: nodes)
        graph.connections = connections
        graph.renderEndpoint = SZPortRef(node: endpoint.id, port: "output")
        let host = SZHost()
        host.store.setProject(SZProject(name: "t", graph: graph))
        return host
    }

    /// The chain case from the stress test: delete the last stage and the stage that fed it takes over.
    @Test func deletingTheEndpointHolderShowsWhatFedIt() {
        let plate = texNode("Plate")
        let blur = texNode("Blur", inputs: ["input"])
        let out = texNode("Out", inputs: ["input"])
        let host = host([plate, blur, out], [data(plate, blur), data(blur, out)], endpoint: out)

        #expect(host.deleteNode(id: out.id))
        #expect(host.store.project?.graph.renderEndpoint == SZPortRef(node: blur.id, port: "output"))
    }

    /// Nothing fed it: the newest surviving sink takes the viewport rather than nothing.
    @Test func aStandaloneEndpointHolderFallsBackToTheNewestSink() {
        let older = texNode("Older")
        let newer = texNode("Newer")
        let out = texNode("Out")
        let host = host([older, newer, out], [], endpoint: out)

        #expect(host.deleteNode(id: out.id))
        #expect(host.store.project?.graph.renderEndpoint?.node == newer.id)
    }

    /// A drafted node carries a texture contract before its source compiles, so adopting it would
    /// trade the viewport for black. It is skipped even when it is the thing that fed the deleted node.
    @Test func theFallbackRefusesANodeThatIsNotGenerated() {
        let fill = texNode("Fill")
        let draft = texNode("Draft", kind: .prompt)
        let out = texNode("Out", inputs: ["input"])
        let host = host([fill, draft, out], [data(draft, out)], endpoint: out)

        #expect(host.deleteNode(id: out.id))
        #expect(host.store.project?.graph.renderEndpoint?.node == fill.id)
    }

    /// A staged split/merge piece is hidden until its run commits it, and the commit moves the
    /// endpoint. A delete must not put one on screen early.
    @Test func theFallbackRefusesAStagedPiece() {
        let gradient = texNode("Gradient")
        let piece = texNode("Piece")
        let out = texNode("Out", inputs: ["input"])
        let host = host([gradient, piece, out], [data(piece, out)], endpoint: out)
        host.hiddenPieces = [piece.id]

        #expect(host.deleteNode(id: out.id))
        #expect(host.store.project?.graph.renderEndpoint?.node == gradient.id)
    }

    /// Deleting anything else leaves the viewport where the user put it.
    @Test func deletingAnotherNodeLeavesTheEndpointAlone() {
        let spare = texNode("Spare")
        let out = texNode("Out")
        let host = host([spare, out], [], endpoint: out)

        #expect(host.deleteNode(id: spare.id))
        #expect(host.store.project?.graph.renderEndpoint == SZPortRef(node: out.id, port: "output"))
    }
}
