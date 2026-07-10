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
