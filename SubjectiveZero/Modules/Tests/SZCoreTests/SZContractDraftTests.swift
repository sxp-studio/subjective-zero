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

/// A prompt node that already ships a contract — the data-spawn seed / permission-camera shape.
private func seededPrompt(_ id: SZNodeID, _ title: String,
                          inputs: [SZPort] = [], outputs: [SZPort] = []) -> SZNode {
    var node = prompt(id, title)
    node.contract = SZNodeContract(title: node.title, sfSymbol: node.sfSymbol,
                                   summary: node.prompt ?? node.title,
                                   inputs: inputs, outputs: outputs)
    return node
}

@Test func draftsTextureContractsWiringAndEndpointFromFlow() {
    let camera = SZNodeID(), gray = SZNodeID()
    let graph = SZGraph(nodes: [prompt(camera, "Camera"), prompt(gray, "Gray")], connections: [flow(camera, gray)])

    let (g, drafted, skipped) = graph.draftContractsFromFlow()
    #expect(Set(drafted) == [camera, gray])
    #expect(skipped.isEmpty)

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

@Test func draftLeavesASeededSpawnContractUntouched() {
    // A data-wire empty-drop spawn ships a one-port contract, so drafting must never rewrite it —
    // the seeded port IS the declaration. A float3 input offers texture drafting nothing to bind,
    // so the incoming arrow stays as intent, REPORTED rather than silently dropped or realized
    // into a mistyped edge.
    let camera = SZNodeID(), seeded = SZNodeID()
    let spawn = seededPrompt(seeded, "Spawn", inputs: [SZPort(name: "input", type: .float3)])
    let graph = SZGraph(nodes: [prompt(camera, "Camera"), spawn], connections: [flow(camera, seeded)])

    let (g, drafted, skipped) = graph.draftContractsFromFlow()
    #expect(drafted == [camera])
    #expect(g.node(id: seeded)?.contract == spawn.contract)
    #expect(skipped.count == 1)
    #expect(skipped.first?.from == camera && skipped.first?.to == seeded)
    #expect(skipped.first?.reason == .noCompatiblePort)
    #expect(g.connections.contains { $0.kind == .flow && $0.to.node == seeded })   // arrow survives
    #expect(g.connections.contains { $0.kind == .data && $0.to.node == seeded } == false)
}

@Test func anArrowIntoASeededTextureInputRealizesIntoIt() {
    // The seeded-spawn counterpart of drafting's flow→data promotion: the target already ships its
    // contract (never rewritten), yet an arrow into its unwired texture input still realizes — even
    // when nothing else needs drafting. The input is deliberately NOT named "input": the edge
    // landing on "frame" proves the contracted branch bound the DECLARED port, not the drafted
    // k-convention name.
    let camera = SZNodeID(), seeded = SZNodeID()
    let cameraNode = SZNode(
        id: camera, kind: .generated, title: "Camera",
        contract: SZNodeContract(title: "Camera", sfSymbol: "camera", summary: "cam",
                                 outputs: [SZPort(name: "texture", type: .texture)]),
        position: SZPoint(x: 0, y: 0))
    let spawn = seededPrompt(seeded, "Spawn", inputs: [SZPort(name: "frame", type: .texture)])
    let graph = SZGraph(nodes: [cameraNode, spawn], connections: [flow(camera, seeded)])

    let (g, drafted, skipped) = graph.draftContractsFromFlow()
    #expect(drafted.isEmpty && skipped.isEmpty)
    #expect(g.node(id: seeded)?.contract == spawn.contract)
    #expect(g.connections.contains {
        $0.kind == .data && $0.from == SZPortRef(node: camera, port: "texture")
            && $0.to == SZPortRef(node: seeded, port: "frame")
    })
    #expect(g.connections.contains { $0.kind == .flow } == false)   // realized ⇒ resolved
    let (again, draftedAgain, skippedAgain) = g.draftContractsFromFlow()
    #expect(again == g && draftedAgain.isEmpty && skippedAgain.isEmpty)   // idempotent
}

@Test func multipleArrowsConsumeAContractedNodesInputsInDeclarationOrder() {
    // Two arrows into a two-input seeded node bind sequentially — the first-unwired scan re-reads
    // the accumulating graph per arrow, so each realization consumes a slot. The third arrow finds
    // no free input and stays as reported intent.
    let a = SZNodeID(), b = SZNodeID(), c = SZNodeID(), seeded = SZNodeID()
    func source(_ id: SZNodeID, _ title: String, port: String) -> SZNode {
        SZNode(id: id, kind: .generated, title: title,
               contract: SZNodeContract(title: title, sfSymbol: "circle", summary: "",
                                        outputs: [SZPort(name: port, type: .texture)]),
               position: SZPoint(x: 0, y: 0))
    }
    let spawn = seededPrompt(seeded, "Spawn", inputs: [SZPort(name: "frame", type: .texture),
                                                       SZPort(name: "mask", type: .texture)])
    let graph = SZGraph(nodes: [source(a, "A", port: "outA"), source(b, "B", port: "outB"),
                                source(c, "C", port: "outC"), spawn],
                        connections: [flow(a, seeded), flow(b, seeded), flow(c, seeded)])

    let (g, drafted, skipped) = graph.draftContractsFromFlow()
    #expect(drafted.isEmpty)
    #expect(g.connections.contains {
        $0.kind == .data && $0.from == SZPortRef(node: a, port: "outA")
            && $0.to == SZPortRef(node: seeded, port: "frame")
    })
    #expect(g.connections.contains {
        $0.kind == .data && $0.from == SZPortRef(node: b, port: "outB")
            && $0.to == SZPortRef(node: seeded, port: "mask")
    })
    #expect(skipped.count == 1)
    #expect(skipped.first?.from == c && skipped.first?.reason == .noCompatiblePort)
    let flows = g.connections.filter { $0.kind == .flow }
    #expect(flows.count == 1 && flows.first?.from.node == c)   // only the unbindable arrow survives
}

@Test func aPinnedArrowRealizesIntoItsSlotAndABadPinStaysAsIntent() {
    // The user dropped the flow wire on a specific blue slot: realization honors that slot over
    // first-unwired (mask before frame), and a pinned SOURCE port over the first texture output.
    // A pin naming a non-texture / missing port is never redirected — the arrow stays as intent.
    let a = SZNodeID(), b = SZNodeID(), c = SZNodeID(), seeded = SZNodeID()
    func source(_ id: SZNodeID, _ title: String, ports: [String]) -> SZNode {
        SZNode(id: id, kind: .generated, title: title,
               contract: SZNodeContract(title: title, sfSymbol: "circle", summary: "",
                                        outputs: ports.map { SZPort(name: $0, type: .texture) }),
               position: SZPoint(x: 0, y: 0))
    }
    let spawn = seededPrompt(seeded, "Spawn", inputs: [SZPort(name: "frame", type: .texture),
                                                       SZPort(name: "mask", type: .texture),
                                                       SZPort(name: "amount", type: .float)])
    let toMask = SZConnection(from: SZPortRef.flow(node: a), to: SZPortRef(node: seeded, port: "mask"), kind: .flow)
    let fromSecond = SZConnection(from: SZPortRef(node: b, port: "second"), to: SZPortRef.flow(node: seeded), kind: .flow)
    let toAmount = SZConnection(from: SZPortRef.flow(node: c), to: SZPortRef(node: seeded, port: "amount"), kind: .flow)
    let graph = SZGraph(nodes: [source(a, "A", ports: ["outA"]), source(b, "B", ports: ["first", "second"]),
                                source(c, "C", ports: ["outC"]), spawn],
                        connections: [toMask, fromSecond, toAmount])

    let (g, drafted, skipped) = graph.draftContractsFromFlow()
    #expect(drafted.isEmpty)
    #expect(g.connections.contains {
        $0.kind == .data && $0.from == SZPortRef(node: a, port: "outA") && $0.to == SZPortRef(node: seeded, port: "mask")
    })
    #expect(g.connections.contains {
        $0.kind == .data && $0.from == SZPortRef(node: b, port: "second") && $0.to == SZPortRef(node: seeded, port: "frame")
    })
    #expect(skipped.count == 1 && skipped.first?.from == c && skipped.first?.reason == .noCompatiblePort)
    #expect(g.connections.filter { $0.kind == .flow }.map(\.id) == [toAmount.id])
}

@Test func anArrowFromASourceWithNoTextureOutputStaysAsIntent() {
    // A seeded float3 SOURCE declares no texture output, so its arrow has no texture wiring to
    // realize — it must stay as reported intent, never an edge to a nonexistent or mistyped port
    // (such an edge is invisible on canvas and dead at runtime).
    let seeded = SZNodeID(), gray = SZNodeID()
    let spawn = seededPrompt(seeded, "Spawn", outputs: [SZPort(name: "output", type: .float3)])
    let graph = SZGraph(nodes: [spawn, prompt(gray, "Gray")], connections: [flow(seeded, gray)])

    let (g, drafted, skipped) = graph.draftContractsFromFlow()
    #expect(drafted == [gray])                          // the target still drafts its contract
    #expect(skipped.count == 1)
    #expect(skipped.first?.from == seeded && skipped.first?.to == gray)
    #expect(skipped.first?.reason == .noCompatiblePort)
    #expect(g.connections.contains { $0.kind == .data } == false)   // no phantom/mistyped edge
    #expect(g.connections.contains { $0.kind == .flow && $0.from.node == seeded })   // arrow survives
}

@Test func draftIsIdempotentAndLeavesExistingContractsAlone() {
    let camera = SZNodeID(), gray = SZNodeID()
    let graph = SZGraph(nodes: [prompt(camera, "Camera"), prompt(gray, "Gray")], connections: [flow(camera, gray)])

    let (once, _, _) = graph.draftContractsFromFlow()
    let (twice, draftedAgain, _) = once.draftContractsFromFlow()
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

    let (g, drafted, _) = graph.draftContractsFromFlow()
    #expect(drafted == [gray])                          // the generated camera is left untouched
    #expect(g.connections.contains {                    // data edge uses the camera's real output name
        $0.kind == .data && $0.from == SZPortRef(node: camera, port: "texture")
            && $0.to == SZPortRef(node: gray, port: "input")
    })
}

@Test func aFlowArrowThatWouldCloseADataCycleStaysAsIntent() {
    // Drawn a ⇄ b plus a → c. Pass 2 realizes b → a first (a is drafted first); realizing a → b
    // would then close a data cycle, so THAT arrow stays flow — visible unresolved intent — while
    // the rest of the drawing still realizes.
    let a = SZNodeID(), b = SZNodeID(), c = SZNodeID()
    let graph = SZGraph(nodes: [prompt(a, "A"), prompt(b, "B"), prompt(c, "C")],
                        connections: [flow(a, b), flow(b, a), flow(a, c)])

    let (g, drafted, skipped) = graph.draftContractsFromFlow()
    #expect(Set(drafted) == [a, b, c])
    #expect(skipped.count == 1)
    #expect(skipped.first?.from == a && skipped.first?.to == b)
    #expect(skipped.first?.reason == .wouldCloseCycle)

    // b → a and a → c realized as data; a → b not.
    #expect(g.connections.contains { $0.kind == .data && $0.from.node == b && $0.to.node == a })
    #expect(g.connections.contains { $0.kind == .data && $0.from.node == a && $0.to.node == c })
    #expect(g.connections.contains { $0.kind == .data && $0.from.node == a && $0.to.node == b } == false)
    // The skipped arrow survives as flow intent; the realized ones are resolved away.
    let flows = g.connections.filter { $0.kind == .flow }
    #expect(flows.count == 1)
    #expect(flows.first?.from.node == a && flows.first?.to.node == b)
    // And the drafted graph still orders — the whole point of skipping.
    #expect(g.topologicalOrder() != nil)
}
