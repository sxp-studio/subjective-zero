// SPDX-License-Identifier: AGPL-3.0-only
// The hand-authored `video-file` library node is well-formed and headless-safe. Its contract decodes
// (including the `mute` switch that silences the clip's audio track — OFF by default, so a freshly
// dropped clip still plays sound as it always has), and its self-contained AVFoundation `Node.swift`
// compiles against the host ABI, loads, and runs the full setup/update/teardown lifecycle with an EMPTY
// `path` — no player, no decoded frame, a black output rather than a crash. Actual playback (and that
// muting silences it) needs a real clip on a real output device, so it's asserted in the app.
import Testing
import Foundation
import Metal
@testable import SZRuntime
@testable import SZCore

private var libraryVideoDir: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()   // SZRuntimeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // SubjectiveZero (umbrella root)
        .appending(path: "NodeLibrary/video-file")
}

private func libraryVideoContract() throws -> SZNodeContract {
    try JSONDecoder().decode(
        SZNodeContract.self, from: Data(contentsOf: libraryVideoDir.appending(path: "node-contract.json")))
}

@Test func videoLibraryContractDecodes() throws {
    let contract = try libraryVideoContract()
    #expect(contract.title == "Video File")
    #expect(contract.requiredPermissions.isEmpty)      // not sandboxed: a path is read directly
    #expect(contract.outputs.first?.type == .texture)
    #expect(contract.outputs.first?.display == true)
}

/// The `mute` control IS its contract entry — a `bool` port renders as the card's mini switch with no
/// view-side special-casing (SZPortControl), so the port's shape is the whole UI contract for it.
@Test func videoMuteIsAToggleThatDefaultsOff() throws {
    let mute = try #require(libraryVideoContract().inputs.first { $0.name == "mute" })
    #expect(mute.type == .bool)
    #expect(mute.ui?.kind == .toggle)
    #expect(mute.def == .bool(false), "mute must default OFF — audio plays until the user silences it")
}

/// Contract and source agree on every port name. A *generated* node gets this from `agent_compile_node`,
/// but a hand-edited library node bypasses that tool (docs/NODE_LIBRARY.md) — so a control added to the
/// contract and never wired in `Node.swift` (a dead knob: the switch moves, the audio doesn't) would ship
/// unnoticed. This is the check that catches it.
@Test func videoContractAndSourceDeclareTheSamePorts() throws {
    let source = try String(contentsOf: libraryVideoDir.appending(path: "Node.swift"), encoding: .utf8)
    let audit = SZPortBindingAudit.audit(contract: try libraryVideoContract(), source: source)
    #expect(audit.errors.isEmpty, "\(audit.errors)")
    #expect(audit.warnings.isEmpty, "\(audit.warnings)")
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func videoNodeCompilesLoadsAndIsHeadlessSafe() throws {
    let runtime = try requireRuntime(renderSize: (width: 32, height: 32))

    // Assemble a 1-node project that copies the library video node in (the instantiation act, by hand).
    let contract = try libraryVideoContract()
    let videoID = SZNodeID()
    let project = SZProject(
        name: "video-only",
        graph: SZGraph(
            nodes: [SZNode(id: videoID, kind: .generated, title: "Video File",
                           sfSymbol: "film", contract: contract, position: SZPoint(x: 0, y: 0))],
            connections: [],
            renderEndpoint: SZPortRef(node: videoID, port: "output")))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "SZVideo-\(UUID().uuidString)").appending(path: "video.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)
    try FileManager.default.copyItem(
        at: libraryVideoDir.appending(path: "Node.swift"),
        to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: videoID, target: .native))

    // Compiles + loads + runs the lifecycle. Empty `path` → no player is built → black.
    try runtime.loadProject(at: dir)
    let frame = try #require(runtime.captureFrame())
    let center = try #require(frame.pixel(x: 16, y: 16))
    #expect(center.r == 0 && center.g == 0 && center.b == 0, "expected black with no path: \(center)")
    #expect(center.a == 255)
}
