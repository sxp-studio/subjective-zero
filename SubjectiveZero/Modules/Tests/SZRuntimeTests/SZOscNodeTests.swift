// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import Network
import Metal
@testable import SZRuntime
@testable import SZCore

/// The `osc-input` library node, compiled and driven headlessly: an in-process UDP sender fires OSC
/// messages (and a bundle) at the node's port on loopback; the node decodes them and emits
/// `lastEvent`/`lastKey` plus one pre-scaled float per `mappings` entry — the same binding
/// contract as `midi.macos`, read back through the same host-side channels. No network beyond
/// loopback, no permission.

private var oscLibraryRoot: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()   // SZRuntimeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // SubjectiveZero (umbrella root)
        .appending(path: "NodeLibrary")
}

private func oscContract() throws -> SZNodeContract {
    try JSONDecoder().decode(
        SZNodeContract.self,
        from: Data(contentsOf: oscLibraryRoot.appending(path: "osc-input/node-contract.json")))
}

@Test func oscContractDecodesWithTheBindingSourceShape() throws {
    let contract = try oscContract()
    #expect(contract.requiredPermissions.isEmpty)
    #expect(contract.inputs.map(\.name) == ["port", "mappings"])
    #expect(contract.inputs.first { $0.name == "port" }?.def?.floats == [8000])
    #expect(contract.outputs.map(\.name) == ["lastEvent", "lastKey"])
    #expect(contract.isBindingSource)
    #expect(contract.card?.plumbing == ["mappings"])
    #expect(FileManager.default.fileExists(atPath: oscLibraryRoot.appending(path: "osc-input/Card.swift").path))
    // The two controller nodes ship the SAME card file — one design, byte-identical.
    let midiCard = try Data(contentsOf: oscLibraryRoot.appending(path: "midi.macos/Card.swift"))
    let oscCard = try Data(contentsOf: oscLibraryRoot.appending(path: "osc-input/Card.swift"))
    #expect(midiCard == oscCard)
}

// MARK: - a tiny OSC 1.0 encoder (test-side)

private func oscPad(_ bytes: [UInt8]) -> [UInt8] { bytes.count % 4 == 0 ? bytes : bytes + [UInt8](repeating: 0, count: 4 - bytes.count % 4) }
private func oscString(_ s: String) -> [UInt8] { oscPad(Array(s.utf8) + [0]) }
private func oscMessage(_ address: String, floats: [Float] = [], ints: [Int32] = [], flag: Bool? = nil) -> [UInt8] {
    var tags = ","
    var body: [UInt8] = []
    for f in floats { tags += "f"; body += withUnsafeBytes(of: f.bitPattern.bigEndian, Array.init) }
    for i in ints { tags += "i"; body += withUnsafeBytes(of: i.bigEndian, Array.init) }
    if let flag { tags += flag ? "T" : "F" }
    return oscString(address) + oscString(tags) + body
}
private func oscBundle(_ messages: [[UInt8]]) -> [UInt8] {
    var out = oscString("#bundle") + [UInt8](repeating: 0, count: 7) + [1]   // timetag = immediately
    for m in messages { out += withUnsafeBytes(of: UInt32(m.count).bigEndian, Array.init) + m }
    return out
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func oscNodeDecodesMessagesAndBundlesIntoMappedOutputs() throws {
    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))
    let port: UInt16 = 18_432 + UInt16.random(in: 0..<2000)   // an unlikely-to-collide loopback port

    // Instance contract = seed + a port + one committed binding: /1/fader1 → "fader", scaled 0…10.
    var contract = try oscContract()
    if let i = contract.inputs.firstIndex(where: { $0.name == "port" }) { contract.inputs[i].def = .float(Double(port)) }
    if let i = contract.inputs.firstIndex(where: { $0.name == "mappings" }) {
        contract.inputs[i].def = .string(#"[{"key":"/1/fader1","port":"fader","min":0,"max":10}]"#)
    }
    contract.outputs.append(SZPort(name: "fader", type: .float))

    let osc = SZNodeID()
    let project = SZProject(
        name: "osc-test",
        graph: SZGraph(
            nodes: [SZNode(id: osc, kind: .generated, title: "OSC Input", sfSymbol: "wifi",
                           contract: contract, position: SZPoint(x: 0, y: 0))],
            connections: [], renderEndpoint: nil))
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "SZOscTest-\(UUID().uuidString)").appending(path: "osc.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)
    try FileManager.default.copyItem(
        at: oscLibraryRoot.appending(path: "osc-input/Node.swift"),
        to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: osc))
    try runtime.loadProject(at: dir)

    // The first frame opens the listener; before any packet the learn signal is the zero sentinel.
    runtime.renderFrame()
    #expect(runtime.readOutputFloats(node: osc, port: "lastEvent") == [0, 0])
    #expect(runtime.readOutputString(node: osc, port: "lastKey") == nil)
    #expect(runtime.readOutputFloats(node: osc, port: "fader") == nil)

    let sender = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .udp)
    sender.start(queue: DispatchQueue(label: "osc-test-sender"))
    defer { sender.cancel() }
    func send(_ packet: [UInt8]) { sender.send(content: Data(packet), completion: .contentProcessed { _ in }) }
    func poll(_ until: () -> Bool) {
        for _ in 0..<200 { runtime.renderFrame(); if until() { return }; usleep(20_000) }
    }

    // A plain message: /1/fader1 0.5 → seq 1, key, value01 0.5, and the binding scaled into 0…10.
    // (Sent a few times: the listener may still be binding when the first datagram leaves.)
    for _ in 0..<5 { send(oscMessage("/1/fader1", floats: [0.5])); usleep(50_000)
        if (runtime.readOutputFloats(node: osc, port: "lastEvent")?[0] ?? 0) > 0 { break } ; runtime.renderFrame() }
    poll { (runtime.readOutputFloats(node: osc, port: "lastEvent")?[0] ?? 0) > 0 }
    let first = try #require(runtime.readOutputFloats(node: osc, port: "lastEvent"))
    #expect(first[0] >= 1)
    #expect(first[1] == 0.5)
    #expect(runtime.readOutputString(node: osc, port: "lastKey") == "/1/fader1")
    #expect(runtime.readOutputFloats(node: osc, port: "fader") == [5])

    // A bundle: an xy pad (two floats → "/1/xy1" and "/1/xy1[1]") plus a toggle (T → 1) and an
    // int (clamped 0…1). The last event decoded is the int.
    let seqBefore = first[0]
    send(oscBundle([oscMessage("/1/xy1", floats: [0.25, 0.75]), oscMessage("/1/toggle1", flag: true),
                    oscMessage("/1/count", ints: [7])]))
    poll { (runtime.readOutputFloats(node: osc, port: "lastEvent")?[0] ?? 0) >= seqBefore + 4 }
    let after = try #require(runtime.readOutputFloats(node: osc, port: "lastEvent"))
    #expect(after[0] == seqBefore + 4)
    #expect(after[1] == 1)                                                    // 7 clamped to 1
    #expect(runtime.readOutputString(node: osc, port: "lastKey") == "/1/count")

    // Bind the second xy component live through the mappings input; its value was cached from the bundle.
    runtime.setInputString(node: osc, port: "mappings",
                           string: #"[{"key":"/1/fader1","port":"fader","min":0,"max":10},{"key":"/1/xy1[1]","port":"fader","min":0,"max":1}]"#)
    runtime.renderFrame()
    #expect(runtime.readOutputFloats(node: osc, port: "fader") == [0.75])   // last row wins the shared port
}
