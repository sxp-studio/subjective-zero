// SPDX-License-Identifier: AGPL-3.0-only
// SZPortBindingAudit — the contract↔Node.swift port-name cross-check. A referenced-but-undeclared port is
// a hard error; a declared-but-unread port is a warning; a name built by interpolation is invisible.
import Testing
@testable import SZCore

private func contract(inputs: [SZPort] = [], outputs: [SZPort] = []) -> SZNodeContract {
    SZNodeContract(title: "T", sfSymbol: "circle", summary: "s", inputs: inputs, outputs: outputs)
}
private func input(_ name: String, _ type: SZPortType = .float) -> SZPort { SZPort(name: name, type: type) }
private func output(_ name: String, _ type: SZPortType = .texture) -> SZPort { SZPort(name: name, type: type) }

@Test func flagsInputReadThatContractNeverDeclares() {
    let c = contract(inputs: [input("mirror", .bool)], outputs: [output("texture")])
    let src = """
    func update(_ ctx: SZFrameContext) {
        let m = ctx.inputFloat("mirror") ?? 1
        let s = ctx.inputFloat("speed") ?? 0   // "speed" is never declared
        _ = (m, s, ctx.outputTexture("texture"))
    }
    """
    let r = SZPortBindingAudit.audit(contract: c, source: src)
    #expect(r.errors.count == 1)
    #expect(r.errors[0].contains("\"speed\""))
    #expect(r.warnings.isEmpty)
}

@Test func flagsOutputWriteThatContractNeverDeclares() {
    let c = contract(inputs: [input("magnitudes", .floatArray)], outputs: [output("hz32", .float)])
    let src = """
    _ = ctx.inputFloatArray("magnitudes")
    ctx.setOutputFloat("hz32", 0.5)
    ctx.setOutputFloat("hz64", 0.5)   // undeclared output
    """
    let r = SZPortBindingAudit.audit(contract: c, source: src)
    #expect(r.errors.count == 1)
    #expect(r.errors[0].contains("\"hz64\""))
}

@Test func warnsOnDeclaredButUnreadInput() {
    let c = contract(inputs: [input("gain"), input("device", .enumeration)], outputs: [output("samples", .floatArray)])
    let src = """
    let g = ctx.inputFloat("gain") ?? 1     // reads gain, ignores device
    ctx.setOutputFloats("samples", [g])
    """
    let r = SZPortBindingAudit.audit(contract: c, source: src)
    #expect(r.errors.isEmpty)                       // unread declaration is not fatal
    #expect(r.warnings.count == 1)
    #expect(r.warnings[0].contains("\"device\""))
}

@Test func ignoresPortNamesInComments() {
    let c = contract(inputs: [input("gain")], outputs: [output("samples", .floatArray)])
    let src = """
    // TODO: wire ctx.inputFloat("brightness") once we add the knob
    /* legacy:
       ctx.inputTexture("bg") was read here */
    let g = ctx.inputFloat("gain") ?? 1
    ctx.setOutputFloats("samples", [g])
    """
    let r = SZPortBindingAudit.audit(contract: c, source: src)
    #expect(r.errors.isEmpty)     // commented refs to undeclared ports must NOT block promotion
    #expect(r.warnings.isEmpty)
}

@Test func cleanWhenEveryPortMatches_andPrefixAccessorsDisambiguate() {
    // Exercises the prefix hazard: inputFloat / inputFloats / inputFloatArray must not cross-match.
    let c = contract(
        inputs: [input("samples", .floatArray), input("window", .enumeration), input("smoothing")],
        outputs: [output("magnitudes", .floatArray)])
    let src = """
    let s = ctx.inputFloatArray("samples") ?? []
    let w = ctx.inputString("window") ?? "hann"
    let k = ctx.inputFloat("smoothing") ?? 0
    _ = (s, w, k)
    ctx.setOutputFloats("magnitudes", s)
    """
    let r = SZPortBindingAudit.audit(contract: c, source: src)
    #expect(r.errors.isEmpty)
    #expect(r.warnings.isEmpty)
}

// MARK: - Live resources must stop when the runtime pauses (ABI v7)

@Test func flagsALiveResourceThatIgnoresPause() {
    let c = contract(inputs: [input("path", .string)], outputs: [output("output")])
    let src = """
    func update(_ ctx: SZFrameContext) {
        player = AVPlayer(playerItem: item)   // nothing stops it — keeps playing while paused
        player?.play()
        _ = ctx.outputTexture("output")
    }
    """
    let r = SZPortBindingAudit.audit(contract: c, source: src)
    #expect(r.errors.count == 1)
    #expect(r.errors[0].contains("AVPlayer"))
    #expect(r.errors[0].contains("setPaused"))
}

@Test func aLiveResourceHandledInSetPausedIsClean() {
    let c = contract(inputs: [input("path", .string)], outputs: [output("output")])
    let src = """
    func update(_ ctx: SZFrameContext) {
        player = AVPlayer(playerItem: item)
        player?.play()
        _ = ctx.outputTexture("output")
    }
    func setPaused(_ paused: Bool) {
        if paused { player?.pause() } else { player?.rate = 1 }
    }
    """
    #expect(SZPortBindingAudit.audit(contract: c, source: src).errors.isEmpty)
}

/// The near-miss the check has to survive: a node that CALLS `.pause()` on its own player but never
/// implements `func setPaused` is still leaking. Matching the bare word would wave it through.
@Test func callingPauseOnTheResourceIsNotImplementingIt() {
    let c = contract(inputs: [input("path", .string)], outputs: [output("output")])
    let src = """
    func update(_ ctx: SZFrameContext) {
        player = AVPlayer(playerItem: item)
        if somethingElse { player?.pause() }   // its own object — not the ABI callback
        _ = ctx.outputTexture("output")
    }
    """
    let r = SZPortBindingAudit.audit(contract: c, source: src)
    #expect(r.errors.count == 1)
    #expect(r.errors[0].contains("AVPlayer"))
}

/// A node that owns nothing running on its own clock is never touched by this check.
@Test func nodesWithoutLiveResourcesAreUnaffected() {
    let c = contract(inputs: [input("amount")], outputs: [output("output")])
    let src = """
    func update(_ ctx: SZFrameContext) {
        let a = ctx.inputFloat("amount") ?? 1
        _ = (a, ctx.outputTexture("output"))
    }
    """
    #expect(SZPortBindingAudit.audit(contract: c, source: src).errors.isEmpty)
}

// MARK: - the promote gate (auditForPromote)

private func node(_ contract: SZNodeContract?, title: String = "T", symbol: String = "circle") -> SZNode {
    SZNode(kind: .generated, title: title, sfSymbol: symbol, contract: contract, position: SZPoint(x: 0, y: 0))
}

@Test func sourceOnlyRestageIsAuditedAgainstTheLiveContract() {
    // No staged contract, but the node HAS a live one: the source must agree with the LIVE contract —
    // a read of an undeclared port is refused, never promoted unaudited. Nothing is merged, so the
    // promote has no contract to write: the live one stands.
    let live = contract(inputs: [input("gain")], outputs: [output("texture")])
    let src = """
    let g = ctx.inputFloat("gain") ?? 1
    let s = ctx.inputFloat("speed") ?? 0   // not in the live contract
    _ = (g, s, ctx.outputTexture("texture"))
    """
    let a = SZPortBindingAudit.auditForPromote(source: src, authored: nil, node: node(live))
    #expect(a.contract == nil)
    #expect(a.result.errors.count == 1)
    #expect(a.result.errors[0].contains("\"speed\""))
    #expect(a.mergeConflicts.isEmpty)
}

@Test func stagedContractIsAuditedAsMergedIntoTheNode() {
    // The authored contract adds "speed"; merged into the node the source audits clean, and a retype the
    // boundary refuses comes back as a merge conflict (a warning, not an error).
    let live = contract(inputs: [input("gain")], outputs: [output("texture")])
    let authored = contract(inputs: [input("gain", .texture), input("speed")], outputs: [output("texture")])
    let src = """
    let g = ctx.inputFloat("gain") ?? 1
    let s = ctx.inputFloat("speed") ?? 0
    _ = (g, s, ctx.outputTexture("texture"))
    """
    let a = SZPortBindingAudit.auditForPromote(source: src, authored: authored, node: node(live))
    #expect(a.result.errors.isEmpty)
    #expect(a.contract?.inputs.map(\.name) == ["gain", "speed"])
    #expect(a.contract?.inputs[0].type == .float)      // boundary held
    #expect(a.mergeConflicts.count == 1)
}

@Test func theAuditedContractCarriesTheNodesIdentity() {
    // The gate merges exactly once, and what it returns is what the promote writes — so the identity
    // rule (`mergingAuthored(_:intoNode:)`) is applied HERE: the node's chosen title stands over the
    // agent's, and a placeholder symbol the node never had chosen is filled from the authored contract.
    let live = contract(outputs: [output("texture")])
    var authored = contract(outputs: [output("texture")])
    authored.title = "Agent Title"
    authored.sfSymbol = "wand.and.stars"
    let named = node(live, title: "Grayscale", symbol: SZNode.placeholderSymbol)
    let a = SZPortBindingAudit.auditForPromote(source: "_ = ctx.outputTexture(\"texture\")",
                                               authored: authored, node: named)
    #expect(a.contract?.title == "Grayscale")
    #expect(a.contract?.sfSymbol == "wand.and.stars")
}

@Test func uncontractedNodeHasNothingToAuditAgainst() {
    let a = SZPortBindingAudit.auditForPromote(source: "_ = ctx.inputFloat(\"x\")",
                                               authored: nil, node: node(nil))
    #expect(a.contract == nil)
    #expect(a.result == SZPortBindingAudit.Result(errors: [], warnings: []))
}
