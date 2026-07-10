// SPDX-License-Identifier: AGPL-3.0-only
// Contract-first drafting (SZGraph+ContractDraft) — the procedural Director strategy's flow
// consumer. A drawn prompt graph (prompt nodes + flow edges, no contracts) gets texture contracts + data
// wiring + a render endpoint UPFRONT, so the cards show their I/O before any code exists.
import Testing
@testable import SZCore

private func prompt(_ id: SZNodeID, _ title: String) -> SZNode {
    SZNode(id: id, kind: .prompt, title: title, prompt: "do \(title)", position: SZPoint(x: 0, y: 0))
}

private func flow(_ a: SZNodeID, _ b: SZNodeID) -> SZConnection {
    SZConnection(from: SZPortRef(node: a, port: "flow"), to: SZPortRef(node: b, port: "flow"), kind: .flow)
}

@Test func draftsTextureContractsWiringAndEndpointFromFlow() {
    let camera = SZNodeID(), gray = SZNodeID()
    let graph = SZGraph(nodes: [prompt(camera, "Camera"), prompt(gray, "Gray")], connections: [flow(camera, gray)])

    let (g, drafted) = graph.draftContractsFromFlow()
    #expect(Set(drafted) == [camera, gray])

    // Head: no inputs, one texture output. Tail: one texture input, one texture output.
    let cam = g.node(id: camera)!.contract!
    #expect(cam.inputs.isEmpty)
    #expect(cam.outputs.map(\.name) == ["output"] && cam.outputs.allSatisfy { $0.type == .texture })
    let grey = g.node(id: gray)!.contract!
    #expect(grey.inputs.map(\.name) == ["input"] && grey.inputs.allSatisfy { $0.type == .texture })
    #expect(grey.outputs.map(\.name) == ["output"])

    // The flow edge is realized as a data edge (Camera.output → Gray.input) so the textures bind —
    // and, being realized, the intent arrow is resolved (removed): no flow edges remain.
    #expect(g.connections.contains {
        $0.kind == .data && $0.from == SZPortRef(node: camera, port: "output")
            && $0.to == SZPortRef(node: gray, port: "input")
    })
    #expect(g.connections.contains { $0.kind == .flow } == false)

    // The terminal node becomes the render endpoint (display flagged), so it renders with no manual toggle.
    #expect(g.renderEndpoint == SZPortRef(node: gray, port: "output"))
    #expect(g.node(id: gray)!.contract!.outputs.first { $0.name == "output" }?.display == true)
}

@Test func draftIsIdempotentAndLeavesExistingContractsAlone() {
    let camera = SZNodeID(), gray = SZNodeID()
    let graph = SZGraph(nodes: [prompt(camera, "Camera"), prompt(gray, "Gray")], connections: [flow(camera, gray)])

    let (once, _) = graph.draftContractsFromFlow()
    let (twice, draftedAgain) = once.draftContractsFromFlow()
    #expect(draftedAgain.isEmpty)                       // nothing left to draft — both already have contracts
    #expect(twice.connections.filter { $0.kind == .data }.count == 1)   // no duplicate data edge
    #expect(twice == once)                              // fully idempotent
}

@Test func draftWiresFromAnExistingUpstreamOutputName() {
    // Upstream already implemented (a library camera) with a non-default texture output name.
    let camera = SZNodeID(), gray = SZNodeID()
    let cameraNode = SZNode(
        id: camera, kind: .generated, title: "Camera",
        contract: SZNodeContract(title: "Camera", sfSymbol: "camera", summary: "cam",
                                 outputs: [SZPort(name: "texture", type: .texture)]),
        position: SZPoint(x: 0, y: 0))
    let graph = SZGraph(nodes: [cameraNode, prompt(gray, "Gray")], connections: [flow(camera, gray)])

    let (g, drafted) = graph.draftContractsFromFlow()
    #expect(drafted == [gray])                          // the generated camera is left untouched
    #expect(g.connections.contains {                    // data edge uses the camera's real output name
        $0.kind == .data && $0.from == SZPortRef(node: camera, port: "texture")
            && $0.to == SZPortRef(node: gray, port: "input")
    })
}
