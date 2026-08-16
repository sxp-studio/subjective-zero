// SPDX-License-Identifier: AGPL-3.0-only
import Testing
import Foundation
import CoreMIDI
import Metal
@testable import SZRuntime
@testable import SZCore

/// The `midi.macos` library node, compiled and driven headlessly: a virtual MIDI source (created by
/// this test process, listed by CoreMIDI like any hardware port) sends channel-voice CC events; the
/// node ingests them and emits `lastEvent`/`lastKey` plus one pre-scaled float per `mappings` entry —
/// read back through `readOutputFloats`/`readOutputString`, the same host-side channels the learn
/// tooling uses. No hardware, no permission (CoreMIDI is not TCC-gated).

private var midiLibraryRoot: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()   // SZRuntimeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // SubjectiveZero (umbrella root)
        .appending(path: "NodeLibrary")
}

private func midiContract() throws -> SZNodeContract {
    try JSONDecoder().decode(
        SZNodeContract.self,
        from: Data(contentsOf: midiLibraryRoot.appending(path: "midi.macos/node-contract.json")))
}

@Test func midiContractDecodesWithExpectedShape() throws {
    let contract = try midiContract()
    #expect(contract.requiredPermissions.isEmpty)   // CoreMIDI needs no entitlement/TCC
    #expect(contract.inputs.map(\.name) == ["source", "mappings"])
    #expect(contract.inputs.first { $0.name == "mappings" }?.def?.string == "[]")
    // Seed contract carries ONLY the learn signal; per-binding outputs are per-instance, added on commit.
    #expect(contract.outputs.map(\.name) == ["lastEvent", "lastKey"])
    #expect(contract.outputs.map(\.type) == [.float2, .string])
    #expect(contract.isBindingSource)
    #expect(contract.card != nil)   // the controller card mounts by default
    #expect(FileManager.default.fileExists(atPath: midiLibraryRoot.appending(path: "midi.macos/Card.swift").path))
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func midiNodeIngestsVirtualCCAndEmitsMappedOutput() throws {
    // The virtual source exists BEFORE the node loads, so setup's initial connect ("all") finds it —
    // the test doesn't depend on the hot-plug notification path.
    var virtualClient = MIDIClientRef()
    var virtualSource = MIDIEndpointRef()
    try #require(MIDIClientCreate("sz-midi-test" as CFString, nil, nil, &virtualClient) == noErr)
    try #require(MIDISourceCreateWithProtocol(
        virtualClient, "SZ Test Source" as CFString, ._1_0, &virtualSource) == noErr)
    defer {
        MIDIEndpointDispose(virtualSource)
        MIDIClientDispose(virtualClient)
    }

    let runtime = try requireRuntime(renderSize: (width: 16, height: 16))

    // Instance contract = seed + one committed binding: CC 21 → output "knob", scaled 0…20.
    var contract = try midiContract()
    if let i = contract.inputs.firstIndex(where: { $0.name == "mappings" }) {
        contract.inputs[i].def = .string(#"[{"key":"ch1/cc21","port":"knob","min":0,"max":20}]"#)
    }
    contract.outputs.append(SZPort(name: "knob", type: .float))

    let midi = SZNodeID()
    let project = SZProject(
        name: "midi-test",
        graph: SZGraph(
            nodes: [SZNode(id: midi, kind: .generated, title: "MIDI Input", sfSymbol: "pianokeys",
                           contract: contract, position: SZPoint(x: 0, y: 0))],
            connections: [],
            renderEndpoint: nil))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "SZMidiTest-\(UUID().uuidString)").appending(path: "midi.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)
    try FileManager.default.copyItem(
        at: midiLibraryRoot.appending(path: "midi.macos/Node.swift"),
        to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: midi))
    try runtime.loadProject(at: dir)

    // Before any event: lastEvent is the zero sentinel, no key yet, and the bound output is NOT
    // emitted (a connected target must keep its own default until the hardware speaks).
    runtime.renderFrame()
    #expect(runtime.readOutputFloats(node: midi, port: "lastEvent") == [0, 0])
    #expect(runtime.readOutputString(node: midi, port: "lastKey") == nil)
    #expect(runtime.readOutputFloats(node: midi, port: "knob") == nil)

    // One UMP MIDI-1.0 channel-voice word: CC 21 = 127 on channel 0.
    func send(cc: Int, value: Int) {
        var word = UInt32(0x2 << 28 | 0xB << 20 | cc << 8 | value)
        var list = MIDIEventList()
        withUnsafeMutablePointer(to: &list) { listPointer in
            let packet = MIDIEventListInit(listPointer, ._1_0)
            _ = MIDIEventListAdd(listPointer, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
            MIDIReceivedEventList(virtualSource, listPointer)
        }
    }
    send(cc: 21, value: 127)

    // Delivery through the MIDI server is async — poll frames until the event lands.
    var lastEvent: [Float]?
    for _ in 0..<150 {
        runtime.renderFrame()
        lastEvent = runtime.readOutputFloats(node: midi, port: "lastEvent")
        if let lastEvent, lastEvent[0] > 0 { break }
        usleep(20_000)
    }
    let event = try #require(lastEvent)
    #expect(event[0] >= 1)          // seq advanced — the learn signal
    #expect(event[1] == 1)          // 127/127
    // "which knob is the hand on" — the key the binding layer commits.
    #expect(runtime.readOutputString(node: midi, port: "lastKey") == "ch1/cc21")
    // The binding emitted: value01 1.0 scaled into 0…20.
    #expect(runtime.readOutputFloats(node: midi, port: "knob") == [20])

    // A second event re-scales live: CC 21 = 0 → knob 0.
    send(cc: 21, value: 0)
    var knob: [Float]?
    for _ in 0..<150 {
        runtime.renderFrame()
        knob = runtime.readOutputFloats(node: midi, port: "knob")
        if knob == [0] { break }
        usleep(20_000)
    }
    #expect(knob == [0])
}
