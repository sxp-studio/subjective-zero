// SPDX-License-Identifier: AGPL-3.0-only
// The named graph-edit ops on SZStore — the one shared mutation path for the SwiftUI
// node editor (SZUI) and the `ui_*` MCP handlers (SZApp). Exercised headlessly here so both callers
// inherit tested behaviour (add/connect/disconnect/update/move, plus the no-project no-op guard).
import Foundation
import Testing
@testable import SZCore

@MainActor
private func loadedStore() -> SZStore {
    let store = SZStore()
    store.setProject(SZProject(name: "Edits"))
    return store
}

@MainActor
@Test func addPromptNodeAppendsAPromptNode() {
    let store = loadedStore()
    let id = store.addPromptNode(prompt: "make it glow", position: SZPoint(x: 10, y: 20))
    #expect(id != nil)
    let node = store.project?.graph.node(id: id!)
    #expect(node?.kind == .prompt)
    #expect(node?.prompt == "make it glow")
    #expect(node?.position == SZPoint(x: 10, y: 20))
}

@MainActor
@Test func addPromptNodeWithASeedDeclaresExactlyThatPort() {
    let store = loadedStore()
    // The data-wire empty-drop spawn: one port of the dragged type, draft-convention name.
    let sink = store.addPromptNode(prompt: "", position: SZPoint(x: 0, y: 0), seed: .input(.float3))!
    let sinkNode = store.project?.graph.node(id: sink)
    #expect(sinkNode?.kind == .prompt)
    #expect(sinkNode?.contract?.inputs == [SZPort(name: "input", type: .float3)])
    #expect(sinkNode?.contract?.outputs.isEmpty == true)

    let source = store.addPromptNode(prompt: "", position: SZPoint(x: -100, y: 0),
                                     seed: .output(.float3))!
    let sourceNode = store.project?.graph.node(id: source)
    #expect(sourceNode?.contract?.inputs.isEmpty == true)
    #expect(sourceNode?.contract?.outputs == [SZPort(name: "output", type: .float3)])

    // The spawn's follow-up connect lands on the seeded ports. (No type claim here — `connect`
    // deliberately doesn't type-check; that's SZUI's `canConnect`, pinned in SZUITests.)
    #expect(store.connect(from: SZPortRef(node: source, port: "output"),
                          to: SZPortRef(node: sink, port: "input"), kind: .data) != nil)
}

@MainActor
@Test func editOpsNoOpWithoutAProject() {
    let store = SZStore()   // nothing loaded
    #expect(store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0)) == nil)
    #expect(store.connect(from: SZPortRef(node: SZNodeID(), port: "o"),
                          to: SZPortRef(node: SZNodeID(), port: "i"), kind: .data) == nil)
    #expect(store.disconnect(connection: SZConnectionID()) == false)
    #expect(store.updateNode(id: SZNodeID(), title: "x").found == false)
    #expect(store.moveNode(id: SZNodeID(), to: SZPoint(x: 1, y: 1)) == false)
}

@MainActor
@Test func connectThenDisconnect() {
    let store = loadedStore()
    let a = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    let b = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 0))!
    let cid = store.connect(from: SZPortRef(node: a, port: "output"),
                            to: SZPortRef(node: b, port: "input"), kind: .flow)
    #expect(cid != nil)
    #expect(store.project?.graph.connections.count == 1)
    #expect(store.project?.graph.connections.first?.kind == .flow)
    #expect(store.disconnect(connection: cid!) == true)
    #expect(store.project?.graph.connections.isEmpty == true)
    #expect(store.disconnect(connection: cid!) == false)   // already gone
}

@MainActor
@Test func updateNodeFieldsAndMissingNode() {
    let store = loadedStore()
    let id = store.addPromptNode(prompt: "old", position: SZPoint(x: 0, y: 0))!
    store.editPorts(node: id, .init(upsertOutputs: [SZPort(name: "output", type: .texture, display: true)]))
    #expect(store.updateNode(id: id, title: "Grayscale", sfSymbol: "circle.lefthalf.filled",
                             prompt: "new", summary: "luminance").found == true)
    let node = store.project?.graph.node(id: id)
    #expect(node?.title == "Grayscale")
    #expect(node?.sfSymbol == "circle.lefthalf.filled")
    #expect(node?.prompt == "new")
    #expect(node?.contract?.summary == "luminance")   // contract identity tracks the node's
    #expect(node?.contract?.outputs.first?.name == "output")
    // A nil field leaves the existing value untouched.
    #expect(store.updateNode(id: id, sfSymbol: "sparkles").found == true)
    #expect(store.project?.graph.node(id: id)?.title == "Grayscale")
    #expect(store.updateNode(id: SZNodeID(), title: "x").found == false)   // missing node
}

@MainActor
@Test func removeNodeAlsoDropsItsConnectionsAndEndpoint() {
    let store = loadedStore()
    let a = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    let b = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 0))!
    _ = store.connect(from: SZPortRef(node: a, port: "output"), to: SZPortRef(node: b, port: "input"), kind: .data)
    store.mutate { $0.graph.renderEndpoint = SZPortRef(node: b, port: "output") }
    #expect(store.removeNode(id: b) == true)
    #expect(store.project?.graph.nodes.contains { $0.id == b } == false)
    #expect(store.project?.graph.connections.isEmpty == true)   // edge to b dropped
    #expect(store.project?.graph.renderEndpoint == nil)         // endpoint cleared
    #expect(store.removeNode(id: b) == false)                   // already gone
}

/// The render endpoint must name a real `texture` output — the same rule the node card's monitor icon
/// applies (it renders only for a texture output), and the one `ui_toggle_display` surfaces as a
/// rejection. A `display: true` flag is NOT required: that only picks a run's default endpoint.
@MainActor
@Test func setRenderEndpointOnlyAcceptsATextureOutput() {
    let store = loadedStore()
    let id = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    store.editPorts(node: id, .init(
        upsertInputs: [SZPort(name: "speed", type: .float)],
        upsertOutputs: [SZPort(name: "output", type: .texture), SZPort(name: "amount", type: .float)]))

    #expect(store.setRenderEndpoint(SZPortRef(node: id, port: "ghost")) == false)     // no such port
    #expect(store.setRenderEndpoint(SZPortRef(node: id, port: "amount")) == false)    // output, not texture
    #expect(store.setRenderEndpoint(SZPortRef(node: id, port: "speed")) == false)     // an input
    #expect(store.setRenderEndpoint(SZPortRef(node: SZNodeID(), port: "output")) == false)  // no such node
    #expect(store.project?.graph.renderEndpoint == nil)                              // nothing leaked

    #expect(store.setRenderEndpoint(SZPortRef(node: id, port: "output")) == true)    // texture output, no `display`
    #expect(store.project?.graph.renderEndpoint == SZPortRef(node: id, port: "output"))
    #expect(store.setRenderEndpoint(nil) == true)                                    // clearing always succeeds
    #expect(store.project?.graph.renderEndpoint == nil)
}

/// `setNodeBody` stores a fully-resolved body (callers resolve the preview port), clears back to
/// nil (= the editor's legacy auto-preview fallback), and reports a missing node.
@MainActor
@Test func setNodeBodySetsClearsAndReportsMissing() {
    let store = loadedStore()
    let id = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    store.editPorts(node: id, .init(upsertOutputs: [SZPort(name: "output", type: .texture)]))

    let body = SZNodeBody(mode: .preview, previewPort: "output")
    #expect(store.setNodeBody(id: id, body: body) == true)
    #expect(store.project?.graph.node(id: id)?.body == body)

    #expect(store.setNodeBody(id: id, body: SZNodeBody(mode: .none)) == true)   // explicit compact pin
    #expect(store.project?.graph.node(id: id)?.body == SZNodeBody(mode: .none))

    #expect(store.setNodeBody(id: id, body: nil) == true)                       // back to unset/legacy
    #expect(store.project?.graph.node(id: id)?.body == nil)

    #expect(store.setNodeBody(id: SZNodeID(), body: body) == false)             // no such node
}

@MainActor
@Test func dataConnectionResolvesTheFlowIntentEdge() {
    let store = loadedStore()
    let a = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    let b = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 0))!
    // Draw an intent arrow a → b, then realize it with a data edge: the arrow resolves (is removed).
    _ = store.connect(from: SZPortRef(node: a, port: "flow"), to: SZPortRef(node: b, port: "flow"), kind: .flow)
    #expect(store.project!.graph.connections.contains { $0.kind == .flow && $0.from.node == a && $0.to.node == b })
    _ = store.connect(from: SZPortRef(node: a, port: "texture"), to: SZPortRef(node: b, port: "input"), kind: .data)
    let conns = store.project!.graph.connections
    #expect(conns.contains { $0.kind == .data })
    #expect(conns.contains { $0.kind == .flow } == false)   // no companion layer — the intent is resolved
    // A data edge on its own never creates flow.
    let c = store.addPromptNode(prompt: nil, position: SZPoint(x: 200, y: 0))!
    _ = store.connect(from: SZPortRef(node: b, port: "output"), to: SZPortRef(node: c, port: "input"), kind: .data)
    #expect(store.project!.graph.connections.contains { $0.kind == .flow } == false)
}

@MainActor
@Test func realizingOneIntentLeavesOtherArrowsIntact() {
    let store = loadedStore()
    let a = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    let b = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 0))!
    let c = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 100))!
    _ = store.connect(from: SZPortRef(node: a, port: "flow"), to: SZPortRef(node: b, port: "flow"), kind: .flow)
    _ = store.connect(from: SZPortRef(node: a, port: "flow"), to: SZPortRef(node: c, port: "flow"), kind: .flow)
    // Realize only a → b; the a → c arrow must remain unresolved.
    _ = store.connect(from: SZPortRef(node: a, port: "output"), to: SZPortRef(node: b, port: "input"), kind: .data)
    let flows = store.project!.graph.connections.filter { $0.kind == .flow }
    #expect(flows.count == 1)
    #expect(flows.first?.to.node == c)
}

// MARK: - Connection cardinality (single-incoming data inputs)

@MainActor
@Test func connectingAnOccupiedDataInputSwapsTheOldEdgeOut() {
    let store = loadedStore()
    let a = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    let b = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 100))!
    let c = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 50))!
    let input = SZPortRef(node: c, port: "input")
    let first = store.connect(from: SZPortRef(node: a, port: "output"), to: input, kind: .data)!
    let second = store.connect(from: SZPortRef(node: b, port: "output"), to: input, kind: .data)!
    #expect(first != second)
    let incoming = store.project!.graph.connections.filter { $0.kind == .data && $0.to == input }
    #expect(incoming.count == 1)                 // the old edge was swapped out
    #expect(incoming.first?.id == second)
    #expect(incoming.first?.from.node == b)
    // Flow is no longer a companion layer — swapping a data input creates no flow edges.
    #expect(store.project!.graph.connections.contains { $0.kind == .flow } == false)
}

@MainActor
@Test func repeatingAnExistingConnectionReturnsTheExistingID() {
    let store = loadedStore()
    let a = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    let b = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 0))!
    let data = store.connect(from: SZPortRef(node: a, port: "output"),
                             to: SZPortRef(node: b, port: "input"), kind: .data)!
    #expect(store.connect(from: SZPortRef(node: a, port: "output"),
                          to: SZPortRef(node: b, port: "input"), kind: .data) == data)
    // A flow (intent) edge dedups by node pair regardless of port name ("" vs "flow"). Use a fresh pair
    // so the data edge above doesn't resolve it away.
    let c = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 100))!
    let flow = store.connect(from: SZPortRef(node: a, port: "flow"),
                             to: SZPortRef(node: c, port: "flow"), kind: .flow)!
    #expect(store.connect(from: SZPortRef(node: a, port: ""),
                          to: SZPortRef(node: c, port: ""), kind: .flow) == flow)
    #expect(store.project!.graph.connections.filter { $0.kind == .flow }.count == 1)   // no duplicate
}

@MainActor
@Test func aPinnedFlowArrowIsItsOwnIntentAndResolvesOnlyWithItsSlot() {
    let store = loadedStore()
    let a = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    let b = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 0))!
    let plain = store.connect(from: SZPortRef.flow(node: a), to: SZPortRef.flow(node: b), kind: .flow)!
    // pinned to b.mask: a different intent from the plain arrow, and from a pin to another slot
    let mask = store.connect(from: SZPortRef.flow(node: a), to: SZPortRef(node: b, port: "mask"), kind: .flow)!
    #expect(mask != plain)
    #expect(store.connect(from: SZPortRef(node: a, port: ""), to: SZPortRef(node: b, port: "mask"), kind: .flow) == mask)
    let input = store.connect(from: SZPortRef.flow(node: a), to: SZPortRef(node: b, port: "input"), kind: .flow)!
    #expect(store.project!.graph.connections.filter { $0.kind == .flow }.count == 3)
    // laying a.output → b.input realizes the plain arrow and the `input` pin; the `mask` pin stays
    _ = store.connect(from: SZPortRef(node: a, port: "output"), to: SZPortRef(node: b, port: "input"), kind: .data)
    let flows = store.project!.graph.connections.filter { $0.kind == .flow }
    #expect(flows.map(\.id) == [mask])
    _ = input
}

@MainActor
@Test func distinctDataInputsOnTheSameNodeEachKeepTheirEdge() {
    let store = loadedStore()
    let a = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    let b = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 100))!
    let c = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 50))!
    _ = store.connect(from: SZPortRef(node: a, port: "output"), to: SZPortRef(node: c, port: "in1"), kind: .data)
    _ = store.connect(from: SZPortRef(node: b, port: "output"), to: SZPortRef(node: c, port: "in2"), kind: .data)
    #expect(store.project!.graph.connections.filter { $0.kind == .data && $0.to.node == c }.count == 2)
}

@MainActor
@Test func reconnectSequenceMovesTheEdgeToTheNewInput() {
    // The store contract behind SZHost.reconnectConnection: disconnect + connect(from: old.from).
    let store = loadedStore()
    let a = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    let b = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 0))!
    let c = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 100))!
    let from = SZPortRef(node: a, port: "output")
    let old = store.connect(from: from, to: SZPortRef(node: b, port: "input"), kind: .data)!
    #expect(store.disconnect(connection: old) == true)
    let moved = store.connect(from: from, to: SZPortRef(node: c, port: "input"), kind: .data)
    #expect(moved != nil && moved != old)
    let dataEdges = store.project!.graph.connections.filter { $0.kind == .data }
    #expect(dataEdges.count == 1)
    #expect(dataEdges.first?.to == SZPortRef(node: c, port: "input"))
}

@MainActor
@Test func flowInputsStillAcceptMultipleSources() {
    let store = loadedStore()
    let a = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    let b = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 100))!
    let c = store.addPromptNode(prompt: nil, position: SZPoint(x: 100, y: 50))!
    _ = store.connect(from: SZPortRef(node: a, port: ""), to: SZPortRef(node: c, port: ""), kind: .flow)
    _ = store.connect(from: SZPortRef(node: b, port: ""), to: SZPortRef(node: c, port: ""), kind: .flow)
    #expect(store.project!.graph.connections.filter { $0.kind == .flow && $0.to.node == c }.count == 2)
}

@MainActor
@Test func moveNode() {
    let store = loadedStore()
    let id = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    #expect(store.moveNode(id: id, to: SZPoint(x: 42, y: 7)) == true)
    #expect(store.project?.graph.node(id: id)?.position == SZPoint(x: 42, y: 7))
}

// MARK: - Port edits + the rebuild flag
//
// The regression these pin: a Director added one input to the Kaleidoscope by re-sending a whole contract that
// omitted the node's seven knobs, which deleted them; and because nothing marked the node for rebuild, its
// compiled source kept running against a contract it no longer matched.
//
// And the one below it (#54): re-sending a port the user had already filled in wiped the value with it — a
// picked model file back to empty, a dragged slider back to the authored default, nothing said.

@MainActor
private func generatedNode(_ store: SZStore, inputs: [SZPort] = [], outputs: [SZPort] = []) -> SZNodeID {
    let id = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!
    store.editPorts(node: id, .init(upsertInputs: inputs, upsertOutputs: outputs))
    // `promoteStagedNode` (the only producer of a built node) lives in SZApp, out of reach here: flip the kind
    // and stamp the build with what it "compiled" against, as a promote would.
    store.mutate { p in
        guard let i = p.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        p.graph.nodes[i].kind = .generated
        p.graph.nodes[i].buildStamp = .trusting(contract: p.graph.nodes[i].contract, prompt: p.graph.nodes[i].prompt)
    }
    return id
}

@MainActor
@Test func upsertingOneInputPreservesTheOthers() {
    let store = loadedStore()
    let knobs = [SZPort(name: "segments", type: .float), SZPort(name: "spin", type: .float),
                 SZPort(name: "twist", type: .float)]
    let id = generatedNode(store, inputs: [SZPort(name: "input", type: .texture)] + knobs,
                           outputs: [SZPort(name: "output", type: .texture)])

    store.editPorts(node: id, .init(upsertInputs: [SZPort(name: "audioDrive", type: .float)]))

    let names = store.project!.graph.node(id: id)!.contract!.inputs.map(\.name)
    #expect(names == ["input", "segments", "spin", "twist", "audioDrive"])   // nothing dropped, appended last
}

@MainActor
@Test func aPortSurfaceChangeMarksRebuildButNeverUnbuildsTheNode() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "input", type: .texture)])

    let result = store.editPorts(node: id, .init(upsertInputs: [SZPort(name: "audioDrive", type: .float)]))
    #expect(result.raisedRebuild)
    let node = store.project!.graph.node(id: id)!
    // Derived: the surface moved off the build stamp. The store cannot read Node.swift, so whether the code
    // merely lags or contradicts the contract is the host's audit to say.
    #expect(node.rebuildReason == .contractChanged)
    // The black-frame guard: `renderableSubgraph` keys on `kind`, so a rebuild must never flip it back.
    #expect(node.kind == .generated)
    #expect(node.needsImplementation)
}

@MainActor
@Test func aPortMovedFromInputToOutputMarksRebuild() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "level", type: .float)])
    // Same name, same type, other side — a read becomes a write. A direction-blind surface would miss this.
    let result = store.editPorts(node: id, .init(removeInputs: ["level"],
                                                 upsertOutputs: [SZPort(name: "level", type: .float)]))
    #expect(result.raisedRebuild)
}

/// Derived, not latched: undoing the edit puts the surface back on the stamp, and the node reads clean again
/// without a rebuild — the flag has no way to outlive its cause.
@MainActor
@Test func revertingAPortEditHealsWithoutARebuild() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "input", type: .texture)])
    #expect(store.editPorts(node: id, .init(upsertInputs: [SZPort(name: "audioDrive", type: .float)])).raisedRebuild)
    #expect(store.project!.graph.node(id: id)!.needsRebuild)
    let revert = store.editPorts(node: id, .init(removeInputs: ["audioDrive"]))
    #expect(revert.raisedRebuild == false)
    #expect(store.project!.graph.node(id: id)!.needsRebuild == false)
}

@MainActor
@Test func retypingAPortMarksRebuild() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "amount", type: .float)])
    let result = store.editPorts(node: id, .init(upsertInputs: [SZPort(name: "amount", type: .texture)]))
    #expect(result.raisedRebuild)
    #expect(store.project!.graph.node(id: id)!.contract!.inputs.first!.type == .texture)
}

// The regression these pin: a Director edited a built node's prompt (`ui_update_node`) and nothing raised a
// rebuild flag, so the node kept running its old build while the user repeated the ask for three turns —
// the toolbelt prompt even taught "only changing a node's PORTS needs a rebuild".

@MainActor
@Test func aPromptEditOnABuiltNodeMarksRebuildButNeverUnbuildsIt() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "input", type: .texture)])

    let result = store.updateNode(id: id, prompt: "make it pulse with the beat")
    #expect(result.raisedRebuild)
    let node = store.project!.graph.node(id: id)!
    #expect(node.rebuildReason == .intentChanged)
    #expect(node.prompt == "make it pulse with the beat")
    // The black-frame guard, same as a port edit: the old build keeps rendering until regenerated.
    #expect(node.kind == .generated)
    #expect(node.needsImplementation)
}

@MainActor
@Test func aPromptEditOnAnUnbuiltNodeNeverMarksRebuild() {
    let store = loadedStore()
    let id = store.addPromptNode(prompt: "old intent", position: SZPoint(x: 0, y: 0))!
    let result = store.updateNode(id: id, prompt: "new intent")
    #expect(result.raisedRebuild == false)
    let node = store.project!.graph.node(id: id)!
    #expect(node.needsRebuild == false)     // nothing built → nothing to invalidate
    #expect(node.needsImplementation)       // still pending, because it was never built
}

@MainActor
@Test func resendingTheSamePromptDoesNotMarkRebuild() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "input", type: .texture)])
    store.updateNode(id: id, prompt: "same")
    store.mutate { p in   // re-stamp the build against the new brief, as a promote would
        guard let i = p.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        p.graph.nodes[i].buildStamp = .trusting(contract: p.graph.nodes[i].contract, prompt: "same")
    }
    let result = store.updateNode(id: id, prompt: "same")
    #expect(result.raisedRebuild == false)
    #expect(store.project!.graph.node(id: id)!.needsRebuild == false)
}

@MainActor
@Test func aPromptEditNeverDowngradesASourceMismatch() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "input", type: .texture)])
    store.mutate { p in   // the host's audit found a real fault
        guard let i = p.graph.nodes.firstIndex(where: { $0.id == id }) else { return }
        p.graph.nodes[i].sourceMismatch = true
    }
    let result = store.updateNode(id: id, prompt: "new intent")
    #expect(result.raisedRebuild == false)   // already awaiting a rebuild — no new work raised
    #expect(store.project!.graph.node(id: id)!.rebuildReason == .sourceMismatch)
}

/// Nothing outside the port surface or the intent may invalidate a build — over-invalidation would regenerate
/// a node on every slider drag or rename. One case per excluded field.
@MainActor
@Test func presentationAndValueEditsNeverMarkRebuild() {
    let store = loadedStore()
    let id = generatedNode(store,
                           inputs: [SZPort(name: "amount", type: .float, ui: SZPortUI(kind: .slider, min: 0, max: 1))],
                           outputs: [SZPort(name: "output", type: .texture)])

    // identity + summary + permissions (`prompt` is NOT presentation — see the intent tests below)
    #expect(store.updateNode(id: id, title: "T", sfSymbol: "star", summary: "s",
                             permissions: [.microphone]).found == true)
    #expect(store.project!.graph.node(id: id)!.needsRebuild == false)

    // an unconnected input's default
    #expect(store.setInputDefault(node: id, port: "amount", value: .float(0.5)) == true)
    #expect(store.project!.graph.node(id: id)!.needsRebuild == false)

    // the display flag on an output
    #expect(store.setRenderEndpoint(SZPortRef(node: id, port: "output")) == true)
    #expect(store.project!.graph.node(id: id)!.needsRebuild == false)

    // re-upserting a port with a new ui but the same (name, type) — the value it holds is kept, not the
    // authored one (see the value tests below)
    let r = store.editPorts(node: id, .init(upsertInputs: [
        SZPort(name: "amount", type: .float, ui: SZPortUI(kind: .field), def: .float(0.9))]))
    #expect(r.raisedRebuild == false)
    #expect(store.project!.graph.node(id: id)!.needsRebuild == false)
    #expect(store.project!.graph.node(id: id)!.contract!.inputs.first!.def == .float(0.5))
}

@MainActor
@Test func removingAPortDropsItsEdgesAndClearsTheEndpoint() {
    let store = loadedStore()
    let src = generatedNode(store, outputs: [SZPort(name: "output", type: .texture)])
    let dst = generatedNode(store, inputs: [SZPort(name: "input", type: .texture)],
                            outputs: [SZPort(name: "output", type: .texture)])
    _ = store.connect(from: SZPortRef(node: src, port: "output"),
                      to: SZPortRef(node: dst, port: "input"), kind: .data)
    #expect(store.setRenderEndpoint(SZPortRef(node: dst, port: "output")) == true)

    let result = store.editPorts(node: dst, .init(removeInputs: ["input"], removeOutputs: ["output"]))

    #expect(result.droppedConnections.count == 1)         // the edge naming the removed input
    #expect(result.clearedRenderEndpoint)                 // the endpoint named the removed output
    #expect(store.project!.graph.connections.isEmpty)
    #expect(store.project!.graph.renderEndpoint == nil)
}

@MainActor
@Test func retypingAPortDropsAnEdgeThatNoLongerTypeMatches() {
    let store = loadedStore()
    let src = generatedNode(store, outputs: [SZPort(name: "output", type: .texture)])
    let dst = generatedNode(store, inputs: [SZPort(name: "input", type: .texture)])
    _ = store.connect(from: SZPortRef(node: src, port: "output"),
                      to: SZPortRef(node: dst, port: "input"), kind: .data)

    let result = store.editPorts(node: dst, .init(upsertInputs: [SZPort(name: "input", type: .float)]))

    #expect(result.droppedConnections.count == 1)   // texture → float is not a legal data edge
    #expect(store.project!.graph.connections.isEmpty)
}

/// The far end of an edge may legitimately have no contract yet — a prompt node the user wired ahead of its
/// declaration. This edit says nothing about that node, so it must not become an excuse to delete the user's wire.
@MainActor
@Test func editingPortsKeepsEdgesToStillUndeclaredNodes() {
    let store = loadedStore()
    let undeclared = store.addPromptNode(prompt: nil, position: SZPoint(x: 0, y: 0))!   // no contract at all
    let dst = generatedNode(store, inputs: [SZPort(name: "input", type: .texture)])
    _ = store.connect(from: SZPortRef(node: undeclared, port: "output"),
                      to: SZPortRef(node: dst, port: "input"), kind: .data)

    let result = store.editPorts(node: dst, .init(upsertInputs: [SZPort(name: "gain", type: .float)]))

    #expect(result.droppedConnections.isEmpty)
    #expect(store.project!.graph.connections.count == 1)
}

@MainActor
@Test func editingPortsOnAnUnbuiltNodeNeverMarksRebuild() {
    let store = loadedStore()
    let id = store.addPromptNode(prompt: "kaleidoscope my camera", position: SZPoint(x: 0, y: 0))!
    // Declaring a prompt node's I/O for the first time is the Director's main job — it has no build to invalidate.
    let result = store.editPorts(node: id, .init(upsertInputs: [SZPort(name: "input", type: .texture)]))
    #expect(result.raisedRebuild == false)
    let node = store.project!.graph.node(id: id)!
    #expect(node.needsRebuild == false)
    #expect(node.contract?.inputs.first?.name == "input")   // contract synthesized from the node's identity
    #expect(node.needsImplementation)                       // still pending, because it was never built
}

/// `summary`/`permissions` live inside the contract, but the Director may set them before a node has one — e.g.
/// "this node needs the microphone", then declare its I/O. Dropping them would be the same silent loss this
/// whole split exists to prevent.
@MainActor
@Test func permissionsSetBeforeAnyPortsSurviveTheLaterPortEdit() {
    let store = loadedStore()
    let id = store.addPromptNode(prompt: "capture the mic", position: SZPoint(x: 0, y: 0))!
    #expect(store.project!.graph.node(id: id)!.contract == nil)   // nothing declared yet

    #expect(store.updateNode(id: id, title: "Microphone", summary: "live mic", permissions: [.microphone]).found == true)
    #expect(store.project!.graph.node(id: id)!.contract?.permissions == [.microphone])

    // Declaring ports afterwards must not clobber the permissions already recorded.
    store.editPorts(node: id, .init(upsertOutputs: [SZPort(name: "samples", type: .floatArray)]))
    let contract = store.project!.graph.node(id: id)!.contract!
    #expect(contract.permissions == [.microphone])
    #expect(contract.summary == "live mic")
    #expect(contract.outputs.map(\.name) == ["samples"])
    #expect(store.project!.graph.node(id: id)!.needsRebuild == false)   // never built → nothing to rebuild
}

// MARK: - A re-declared port keeps the value the user set (#54)
//
// The declaration is the caller's, the value is the user's. `setInputDefault` is the one path that changes a
// value; `editPorts` rewrites everything else around it.

@MainActor
@Test func reDeclaringAPortKeepsTheValueTheUserSet() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "amount", type: .float,
                                                  ui: SZPortUI(kind: .slider, min: 0, max: 1))])
    #expect(store.setInputDefault(node: id, port: "amount", value: .float(0.75)) == true)

    // The agent re-sends the port carrying the default it authored. The user's value outranks it.
    let result = store.editPorts(node: id, .init(upsertInputs: [
        SZPort(name: "amount", type: .float, ui: SZPortUI(kind: .slider, min: 0, max: 1), def: .float(0.2))]))

    #expect(store.project!.graph.node(id: id)!.contract!.inputs.first!.def == .float(0.75))
    #expect(result.droppedValues.isEmpty)
    #expect(result.raisedRebuild == false)   // a value is not part of the port surface
}

/// The file-picker case from the repro: a `string` input whose value is a path the user chose, re-declared by
/// an agent that says nothing about values at all.
@MainActor
@Test func reDeclaringAPortKeepsItsControlHintAndItsPickedFile() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "modelPath", type: .string,
                                                  ui: SZPortUI(kind: .filePicker))])
    #expect(store.setInputDefault(node: id, port: "modelPath",
                                  value: .string("/Users/x/Downloads/Depth.mlpackage")) == true)

    store.editPorts(node: id, .init(upsertInputs: [SZPort(name: "modelPath", type: .string)]))

    let port = store.project!.graph.node(id: id)!.contract!.inputs.first!
    #expect(port.def == .string("/Users/x/Downloads/Depth.mlpackage"))
    #expect(port.ui?.kind == .filePicker)   // the control hint is kept too, not just the value
}

/// A facet the caller does state still lands: the fill is for omissions only, or `editPorts` would stop
/// being the editorial path.
@MainActor
@Test func aStatedControlHintReplacesTheOneAlreadyThere() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "amount", type: .float,
                                                  ui: SZPortUI(kind: .slider, min: 0, max: 1))])
    store.editPorts(node: id, .init(upsertInputs: [
        SZPort(name: "amount", type: .float, ui: SZPortUI(kind: .field))]))
    #expect(store.project!.graph.node(id: id)!.contract!.inputs.first!.ui?.kind == .field)
}

@MainActor
@Test func upsertingOntoAPortWithNoValueYetSeedsTheDeclaredOne() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "gain", type: .float)])
    store.editPorts(node: id, .init(upsertInputs: [
        SZPort(name: "gain", type: .float, ui: SZPortUI(kind: .slider, min: 0, max: 4), def: .float(2))]))
    #expect(store.project!.graph.node(id: id)!.contract!.inputs.first!.def == .float(2))
}

/// A kept value is bound to the declaration this edit leaves behind, the same way `setInputDefault` binds one
/// someone writes. Applied twice because `clampedDefault` must stay a fixed point on its own output.
@MainActor
@Test func aReDeclaredSliderRebindsTheKeptValueToItsNewRange() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "amount", type: .float,
                                                  ui: SZPortUI(kind: .slider, min: 0, max: 1))])
    #expect(store.setInputDefault(node: id, port: "amount", value: .float(0.9)) == true)

    let narrowed = SZPort(name: "amount", type: .float, ui: SZPortUI(kind: .slider, min: 0, max: 0.5, step: 0.1))
    let first = store.editPorts(node: id, .init(upsertInputs: [narrowed]))
    #expect(store.project!.graph.node(id: id)!.contract!.inputs.first!.def == .float(0.5))
    #expect(first.droppedValues.isEmpty)   // rebound, not dropped

    store.editPorts(node: id, .init(upsertInputs: [narrowed]))
    #expect(store.project!.graph.node(id: id)!.contract!.inputs.first!.def == .float(0.5))
}

@MainActor
@Test func retypingAPortDropsItsValueAndSaysSo() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "amount", type: .float, def: .float(0.5))])

    let result = store.editPorts(node: id, .init(upsertInputs: [SZPort(name: "amount", type: .texture)]))

    #expect(store.project!.graph.node(id: id)!.contract!.inputs.first!.def == nil)
    #expect(result.droppedValues == ["input 'amount': dropped its value (float does not fit the texture you declared)"])
    #expect(result.raisedRebuild)
}

/// A retype of a port holding nothing has nothing to report — the note must track a real loss, not the shape
/// of the edit.
@MainActor
@Test func retypingAPortThatHeldNoValueSaysNothing() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "amount", type: .float)])
    let result = store.editPorts(node: id, .init(upsertInputs: [SZPort(name: "amount", type: .texture)]))
    #expect(result.droppedValues.isEmpty)
}

@MainActor
@Test func anEnumValueTheNewOptionsWithdrawIsDropped() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [
        SZPort(name: "mode", type: .enumeration, ui: SZPortUI(kind: .dropdown), def: .enumeration("average"),
               options: [SZEnumOption(value: "luma"), SZEnumOption(value: "average")])])

    let result = store.editPorts(node: id, .init(upsertInputs: [
        SZPort(name: "mode", type: .enumeration, options: [SZEnumOption(value: "luma"),
                                                           SZEnumOption(value: "sepia")])]))

    #expect(store.project!.graph.node(id: id)!.contract!.inputs.first!.def == nil)
    #expect(result.droppedValues == ["input 'mode': dropped its value (not among the options you declared)"])
    #expect(result.raisedRebuild == false)   // options are not part of the port surface
}

@MainActor
@Test func anEnumValueTheNewOptionsStillOfferSurvives() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [
        SZPort(name: "mode", type: .enumeration, def: .enumeration("average"),
               options: [SZEnumOption(value: "luma"), SZEnumOption(value: "average")])])

    let result = store.editPorts(node: id, .init(upsertInputs: [
        SZPort(name: "mode", type: .enumeration, options: [SZEnumOption(value: "luma"),
                                                           SZEnumOption(value: "average"),
                                                           SZEnumOption(value: "sepia")])]))

    #expect(store.project!.graph.node(id: id)!.contract!.inputs.first!.def == .enumeration("average"))
    #expect(result.droppedValues.isEmpty)
}

/// A dynamic enum (`camera`) lists no options: the node supplies them at runtime, so the contract vouches for
/// nothing and a value it never declared must survive.
@MainActor
@Test func aDynamicEnumKeepsItsValueWhenTheDeclarationListsNoOptions() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [
        SZPort(name: "camera", type: .enumeration, def: .enumeration("FaceTime HD"))])

    let result = store.editPorts(node: id, .init(upsertInputs: [
        SZPort(name: "camera", type: .enumeration, ui: SZPortUI(kind: .dropdown))]))

    #expect(store.project!.graph.node(id: id)!.contract!.inputs.first!.def == .enumeration("FaceTime HD"))
    #expect(result.droppedValues.isEmpty)
}

/// One rule, both sides. Outputs carry no user knob today, but a branch here would exist only to format a
/// string, and the promote merge already treats the two alike.
@MainActor
@Test func anOutputPortKeepsItsValueOnTheSameTerms() {
    let store = loadedStore()
    let id = generatedNode(store, outputs: [SZPort(name: "level", type: .float, def: .float(1))])
    store.editPorts(node: id, .init(upsertOutputs: [
        SZPort(name: "level", type: .float, ui: SZPortUI(kind: .field))]))
    #expect(store.project!.graph.node(id: id)!.contract!.outputs.first!.def == .float(1))
}

/// A re-declared output keeps the `display` flag a draft wrote, so a later draft still reads the same
/// endpoint candidate.
@MainActor
@Test func aReDeclaredOutputKeepsItsDisplayFlag() {
    let store = loadedStore()
    let id = generatedNode(store, outputs: [SZPort(name: "output", type: .texture, display: true)])
    store.editPorts(node: id, .init(upsertOutputs: [SZPort(name: "output", type: .texture)]))
    #expect(store.project!.graph.node(id: id)!.contract!.outputs.first!.display == true)
}

/// The round trip the issue asks for: a value the user set survives a contract edit and the promote that
/// follows it, so the two contract-merge paths agree on who owns a value.
@MainActor
@Test func aValueSurvivesAReDeclareThenAPromote() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "amount", type: .float,
                                                  ui: SZPortUI(kind: .slider, min: 0, max: 1))])
    #expect(store.setInputDefault(node: id, port: "amount", value: .float(0.75)) == true)
    store.editPorts(node: id, .init(upsertInputs: [SZPort(name: "amount", type: .float)]))

    // What a Coding Agent would stage next: the same port, its own authored default.
    let authored = SZNodeContract(title: "T", sfSymbol: "star", summary: "s",
                                  inputs: [SZPort(name: "amount", type: .float, def: .float(0.2))])
    let merged = SZNodeContract.mergingAuthored(authored, intoNode: store.project!.graph.node(id: id)!)

    #expect(merged.contract.inputs.first!.def == .float(0.75))
    #expect(merged.conflicts.isEmpty)
}

/// A value the caller states is bound the same way a kept one is: nothing reaches a contract through
/// `editPorts` that the port's own control could not produce.
@MainActor
@Test func aDeclaredDefaultIsBoundToTheControlItIsDeclaredWith() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "gain", type: .float)])
    store.editPorts(node: id, .init(upsertInputs: [
        SZPort(name: "gain", type: .float, ui: SZPortUI(kind: .slider, min: 0, max: 1), def: .float(100))]))
    #expect(store.project!.graph.node(id: id)!.contract!.inputs.first!.def == .float(1))
}

/// A retype's facets described the old type. Carrying them forward would leave a stale option list, or a
/// slider's bounds, on a port that can no longer use them.
@MainActor
@Test func aRetypeDoesNotCarryTheOldTypesFacetsForward() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [
        SZPort(name: "mode", type: .enumeration, ui: SZPortUI(kind: .dropdown),
               options: [SZEnumOption(value: "luma")])])

    store.editPorts(node: id, .init(upsertInputs: [SZPort(name: "mode", type: .float)]))

    let port = store.project!.graph.node(id: id)!.contract!.inputs.first!
    #expect(port.options == nil)
    #expect(port.ui == nil)
}

// MARK: - What a port edit tells the host to push
//
// The contract is only where a value persists. The runtime holds the override the node reads, and a reload
// keeps it on purpose — so an edit that moves a value has to say which ones moved, or the card and the render
// disagree until the app relaunches.

@MainActor
@Test func aReboundValueIsReportedForThePush() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "amount", type: .float,
                                                  ui: SZPortUI(kind: .slider, min: 0, max: 1))])
    #expect(store.setInputDefault(node: id, port: "amount", value: .float(0.9)) == true)

    let result = store.editPorts(node: id, .init(upsertInputs: [
        SZPort(name: "amount", type: .float, ui: SZPortUI(kind: .slider, min: 0, max: 0.5, step: 0.1))]))

    #expect(result.changedValues == [.init(port: "amount", value: .float(0.5), note: nil)])
    #expect(result.droppedValues.isEmpty)   // rebound, so nothing to tell the agent
}

@MainActor
@Test func aClearedValueIsReportedAsNilSoTheOverrideGoes() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [
        SZPort(name: "mode", type: .enumeration, def: .enumeration("average"),
               options: [SZEnumOption(value: "luma"), SZEnumOption(value: "average")])])

    let result = store.editPorts(node: id, .init(upsertInputs: [
        SZPort(name: "mode", type: .enumeration, options: [SZEnumOption(value: "luma")])]))

    #expect(result.changedValues.count == 1)
    #expect(result.changedValues.first!.port == "mode")
    #expect(result.changedValues.first!.value == nil)
    #expect(result.changedValues.first!.note != nil)   // and the agent hears about this one
}

/// The preservation half: an edit that leaves a value alone must report nothing, or the host would push over
/// a card gesture or a controller binding driving that input live.
@MainActor
@Test func anEditThatLeavesAValueAloneReportsNoChange() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "amount", type: .float,
                                                  ui: SZPortUI(kind: .slider, min: 0, max: 1))])
    #expect(store.setInputDefault(node: id, port: "amount", value: .float(0.75)) == true)

    let result = store.editPorts(node: id, .init(upsertInputs: [
        SZPort(name: "amount", type: .float, def: .float(0.2))]))

    #expect(result.changedValues.isEmpty)
}

/// A value seeded onto a port that held none is a move too: the node has never been told it.
@MainActor
@Test func aSeededValueIsReportedForThePush() {
    let store = loadedStore()
    let id = generatedNode(store, inputs: [SZPort(name: "gain", type: .float)])
    let result = store.editPorts(node: id, .init(upsertInputs: [
        SZPort(name: "gain", type: .float, def: .float(2))]))
    #expect(result.changedValues == [.init(port: "gain", value: .float(2), note: nil)])
}

@MainActor
@Test func repeatingADataEdgeStillResolvesTheArrowBehindIt() {
    // Laying an edge clears the arrow behind it, including when the wiring is already there. Returning
    // the existing id bare left the arrow standing over a wired pair, which still reads as work owed.
    let store = SZStore()
    let a = SZNode(kind: .generated, title: "A", position: SZPoint(x: 0, y: 0))
    let b = SZNode(kind: .generated, title: "B", position: SZPoint(x: 1, y: 0))
    let from = SZPortRef(node: a.id, port: "output"), to = SZPortRef(node: b.id, port: "input")
    store.setProject(SZProject(name: "t", graph: SZGraph(
        nodes: [a, b],
        connections: [SZConnection(from: from, to: to, kind: .data),
                      SZConnection(from: SZPortRef(node: a.id, port: "flow"),
                                   to: SZPortRef(node: b.id, port: "flow"), kind: .flow)])))

    let result = store.tryConnect(from: from, to: to, kind: .data)
    if case .connected = result {} else { Issue.record("expected the existing edge's id") }
    #expect(store.project?.graph.connections.filter { $0.kind == .flow }.isEmpty == true)
    #expect(store.project?.graph.connections.filter { $0.kind == .data }.count == 1)
}
