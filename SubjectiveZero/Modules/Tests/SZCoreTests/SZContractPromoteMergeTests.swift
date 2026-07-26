// SPDX-License-Identifier: AGPL-3.0-only
// The promote-time boundary merge (SZContract+PromoteMerge.swift): a promote must keep BOTH the live typed
// boundary (types, wired ports, the user's current slider values) and whatever the agent authored on top of
// it (its new control knobs). Wholesale replacement in either direction loses one of them.
import Testing
@testable import SZCore

private func contract(_ title: String = "Node",
                      inputs: [SZPort] = [], outputs: [SZPort] = [],
                      permissions: [SZEntitlement]? = nil) -> SZNodeContract {
    SZNodeContract(title: title, sfSymbol: "circle", summary: "\(title) summary",
                   inputs: inputs, outputs: outputs, permissions: permissions)
}

// MARK: - what each side contributes

@Test func agentAddedPortsSurviveThePromote() {
    // The incident: an agent mints control knobs alongside the source that reads them. Dropping them here
    // makes the promoted source read ports the contract never declares.
    let boundary = contract(inputs: [SZPort(name: "src", type: .texture)],
                            outputs: [SZPort(name: "out", type: .texture)])
    let authored = contract("Wobble",
                            inputs: [SZPort(name: "src", type: .texture),
                                     SZPort(name: "amount", type: .float,
                                            ui: SZPortUI(kind: .slider, min: 0, max: 1),
                                            def: .float(0.25))],
                            outputs: [SZPort(name: "out", type: .texture),
                                      SZPort(name: "level", type: .float)])

    let merged = SZNodeContract.mergingAuthored(authored, intoBoundary: boundary)

    #expect(merged.conflicts.isEmpty)
    #expect(merged.contract.inputs.map(\.name) == ["src", "amount"])
    #expect(merged.contract.outputs.map(\.name) == ["out", "level"])
    #expect(merged.contract.inputs[1].def == .float(0.25))
    // Identity is the agent's.
    #expect(merged.contract.title == "Wobble")
}

@Test func boundaryDefaultWinsSoASliderSurvivesARebuild() {
    // `def` IS the user's current value (SZStore.setInputDefault writes the slider here) — the agent's
    // authoring-time default must not overwrite it.
    let boundary = contract(inputs: [SZPort(name: "amount", type: .float,
                                            ui: SZPortUI(kind: .slider, min: 0, max: 1),
                                            def: .float(0.82))])
    let authored = contract(inputs: [SZPort(name: "amount", type: .float,
                                            ui: SZPortUI(kind: .slider, min: 0, max: 1),
                                            def: .float(0.5))])

    let merged = SZNodeContract.mergingAuthored(authored, intoBoundary: boundary)

    #expect(merged.contract.inputs[0].def == .float(0.82))
}

@Test func authoredFacetsFillNilBoundaryFacets() {
    // A boundary drafted from flow carries a bare typed port; the agent's ui/options/default are the only
    // ones there are, so they must land rather than be erased.
    let boundary = contract(inputs: [SZPort(name: "mode", type: .enumeration),
                                     SZPort(name: "amount", type: .float)],
                            outputs: [SZPort(name: "out", type: .texture)])
    let authored = contract(inputs: [SZPort(name: "mode", type: .enumeration,
                                            ui: SZPortUI(kind: .dropdown),
                                            def: .enumeration("add"),
                                            options: [SZEnumOption(value: "add"), SZEnumOption(value: "mul")]),
                                     SZPort(name: "amount", type: .float,
                                            ui: SZPortUI(kind: .slider, min: 0, max: 4),
                                            def: .float(1.5))],
                            outputs: [SZPort(name: "out", type: .texture, display: true)])

    let merged = SZNodeContract.mergingAuthored(authored, intoBoundary: boundary)

    #expect(merged.contract.inputs[0].ui?.kind == .dropdown)
    #expect(merged.contract.inputs[0].options?.map(\.value) == ["add", "mul"])
    #expect(merged.contract.inputs[0].def == .enumeration("add"))
    #expect(merged.contract.inputs[1].ui?.max == 4)
    #expect(merged.contract.inputs[1].def == .float(1.5))
    #expect(merged.contract.outputs[0].display == true)
}

// MARK: - the boundary holds

@Test func typeConflictKeepsTheBoundaryPortAndReportsIt() {
    // Edges, the render endpoint and the runtime's override arity were all validated against the LIVE type.
    // A retype has to go through `ui_edit_ports` (which prunes what it invalidates); a promote may not.
    let boundary = contract(inputs: [SZPort(name: "amount", type: .float,
                                            ui: SZPortUI(kind: .slider, min: 0, max: 1),
                                            def: .float(0.3))])
    let authored = contract(inputs: [SZPort(name: "amount", type: .texture)])

    let merged = SZNodeContract.mergingAuthored(authored, intoBoundary: boundary)

    #expect(merged.contract.inputs == boundary.inputs)
    #expect(merged.conflicts == ["input 'amount': kept declared type float (you staged texture)"])
}

@Test func outputTypeConflictIsReportedOnTheOutputSide() {
    let boundary = contract(outputs: [SZPort(name: "level", type: .float)])
    let authored = contract(outputs: [SZPort(name: "level", type: .texture)])

    let merged = SZNodeContract.mergingAuthored(authored, intoBoundary: boundary)

    #expect(merged.contract.outputs == boundary.outputs)
    #expect(merged.conflicts == ["output 'level': kept declared type float (you staged texture)"])
}

@Test func portTheAgentDroppedIsKept() {
    // It may be wired. An unread declared port is a warning, not an error — removal is `ui_edit_ports`' job.
    let boundary = contract(inputs: [SZPort(name: "src", type: .texture),
                                     SZPort(name: "mask", type: .texture)],
                            outputs: [SZPort(name: "out", type: .texture)])
    let authored = contract(inputs: [SZPort(name: "src", type: .texture)], outputs: [])

    let merged = SZNodeContract.mergingAuthored(authored, intoBoundary: boundary)

    #expect(merged.contract.inputs.map(\.name) == ["src", "mask"])
    #expect(merged.contract.outputs.map(\.name) == ["out"])
}

@Test func namedEndpointOutputSurvivesEvenWhenTheAgentRenamesEverything() {
    // The render endpoint names a node's texture output. Outputs come out a SUPERSET of the boundary's, so
    // the endpoint can never dangle across a promote.
    let boundary = contract(outputs: [SZPort(name: "color", type: .texture, display: true)])
    let authored = contract(outputs: [SZPort(name: "result", type: .texture)])

    let merged = SZNodeContract.mergingAuthored(authored, intoBoundary: boundary)

    #expect(merged.contract.outputs.map(\.name) == ["color", "result"])
    #expect(merged.contract.outputs[0].display == true)
}

// MARK: - permissions + stability

@Test func permissionsAreTheUnionAndAnEmptyBoundaryLetsTheAgentsStand() {
    // A contract-first drawn node's drafted boundary declares none — the host can't infer them from flow —
    // so the camera node keeps the `.camera` its agent authored.
    let agentOnly = SZNodeContract.mergingAuthored(contract(permissions: [.camera]),
                                                   intoBoundary: contract())
    #expect(agentOnly.contract.permissions == [.camera])

    let union = SZNodeContract.mergingAuthored(contract(permissions: [.microphone, .camera]),
                                               intoBoundary: contract(permissions: [.camera]))
    #expect(union.contract.permissions == [.camera, .microphone])

    let none = SZNodeContract.mergingAuthored(contract(), intoBoundary: contract())
    #expect(none.contract.permissions == nil)
}

@Test func mergeIsIdempotentAcrossReconcileRounds() {
    // A reconcile round re-promotes; the second merge must be a fixed point (same ports, same order),
    // or the card's rows would shuffle every round.
    let boundary = contract(inputs: [SZPort(name: "src", type: .texture),
                                     SZPort(name: "amount", type: .float, def: .float(0.9))],
                            outputs: [SZPort(name: "out", type: .texture)],
                            permissions: [.camera])
    let authored = contract("Wobble",
                            inputs: [SZPort(name: "amount", type: .float, def: .float(0.1)),
                                     SZPort(name: "speed", type: .float, def: .float(2))],
                            outputs: [SZPort(name: "level", type: .float)],
                            permissions: [.microphone])

    let once = SZNodeContract.mergingAuthored(authored, intoBoundary: boundary)
    // Re-promoting the same authored contract against the unchanged boundary…
    #expect(SZNodeContract.mergingAuthored(authored, intoBoundary: boundary) == once)
    // …and re-merging against the boundary the first merge produced both land on the same contract.
    #expect(SZNodeContract.mergingAuthored(once.contract, intoBoundary: once.contract).contract == once.contract)
    #expect(once.contract.inputs.map(\.name) == ["src", "amount", "speed"])
    #expect(once.contract.outputs.map(\.name) == ["out", "level"])
}
