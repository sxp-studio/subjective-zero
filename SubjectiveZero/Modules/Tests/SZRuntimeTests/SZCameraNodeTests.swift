// SPDX-License-Identifier: AGPL-3.0-only
// The hand-authored `camera.macos` library node is well-formed and headless-safe. Its
// contract decodes, its self-contained AVFoundation `Node.swift` compiles against the host ABI, loads,
// and runs the full setup/update/teardown lifecycle WITHOUT camera authorization — guarding to a black
// frame (no prompt, no crash). The live-camera render is asserted in the app (a real camera +
// granted permission can't be a deterministic unit test).
import Testing
import Foundation
import Metal
@testable import SZRuntime
@testable import SZCore

private var libraryCameraDir: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()   // SZRuntimeTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // SubjectiveZero (umbrella root)
        .appending(path: "NodeLibrary/camera.macos")
}

@Test func cameraLibraryContractDecodes() throws {
    let data = try Data(contentsOf: libraryCameraDir.appending(path: "node-contract.json"))
    let contract = try JSONDecoder().decode(SZNodeContract.self, from: data)
    #expect(contract.title == "MacBook Camera")
    #expect(contract.requiredPermissions == [.camera])
    #expect(contract.outputs.first?.type == .texture)
    #expect(contract.outputs.first?.display == true)
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func cameraNodeCompilesLoadsAndIsHeadlessSafe() throws {
    let runtime = try requireRuntime(renderSize: (width: 32, height: 32))

    // Assemble a 1-node project that copies the library camera node in (the "copy-as-is" act, by hand).
    let contract = try JSONDecoder().decode(
        SZNodeContract.self, from: Data(contentsOf: libraryCameraDir.appending(path: "node-contract.json")))
    let cameraID = SZNodeID()
    let project = SZProject(
        name: "camera-only",
        graph: SZGraph(
            nodes: [SZNode(id: cameraID, kind: .generated, title: "MacBook Camera",
                           sfSymbol: "camera", contract: contract, position: SZPoint(x: 0, y: 0))],
            connections: [],
            renderEndpoint: SZPortRef(node: cameraID, port: "texture")))

    let dir = FileManager.default.temporaryDirectory
        .appending(path: "SZCamera-\(UUID().uuidString)").appending(path: "camera.subz")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)
    try FileManager.default.copyItem(
        at: libraryCameraDir.appending(path: "Node.swift"),
        to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: cameraID))

    // Compiles + loads + runs the lifecycle. Unauthorized in a test → setup starts no session → black.
    try runtime.loadProject(at: dir)
    let frame = try #require(runtime.captureFrame())
    let center = try #require(frame.pixel(x: 16, y: 16))
    #expect(center.r == 0 && center.g == 0 && center.b == 0, "expected black without camera auth: \(center)")
    #expect(center.a == 255)
}
