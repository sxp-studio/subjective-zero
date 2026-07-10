// SPDX-License-Identifier: AGPL-3.0-only
// The checked-in sample project loads FROM DISK through SZProjectIO — not an in-code graph. Proves
// the on-disk `.subz` layout + the project.json/node-contract.json split exist and round-trip.
// (The sample's actual rendering is covered by SZGraphRenderTests.)
import Foundation
import Testing
@testable import SZCore

/// The checked-in sample, located relative to this test source (robust to the test's working directory).
/// `#filePath` = …/SubjectiveZero/Modules/Tests/SZCoreTests/SZSampleLoadTests.swift → up 4 → umbrella root → Samples/….
private var sampleURL: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()   // SZCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // SubjectiveZero (umbrella root)
        .appending(path: "Samples/grayscale-camera.subz")
}

@Test func sampleLoadsFromDisk() throws {
    let project = try SZProjectIO.load(from: sampleURL)
    #expect(project.name == "Grayscale Camera")
    #expect(project.graph.nodes.count == 2)
    #expect(project.graph.connections.count == 1)

    // Contracts were folded back from each node's folder.
    let camera = try #require(project.graph.nodes.first { $0.sfSymbol == "camera" })
    let gray = try #require(project.graph.nodes.first { $0.title == "Make Grayscale" })
    #expect(camera.contract?.outputs.first?.type == .texture)
    #expect(camera.contract?.outputs.first?.display == true)
    #expect(gray.contract?.inputs.first?.name == "input")
    #expect(gray.contract?.outputs.first?.display == true)

    // The data edge runs camera.texture → grayscale.input; render endpoint = grayscale output.
    let conn = try #require(project.graph.connections.first)
    #expect(conn.kind == .data)
    #expect(conn.from == SZPortRef(node: camera.id, port: "texture"))
    #expect(conn.to == SZPortRef(node: gray.id, port: "input"))
    #expect(project.graph.renderEndpoint == SZPortRef(node: gray.id, port: "output"))

    // Each node's Node.swift source exists on disk (compiled by the runtime from step 3 on).
    for node in project.graph.nodes {
        let src = SZProjectIO.nodeSourceURL(projectURL: sampleURL, nodeID: node.id)
        #expect(FileManager.default.fileExists(atPath: src.path), "missing Node.swift for \(node.title)")
    }
}

/// The agent demo fixture ships NO node source — both nodes are dirty (`.prompt`), so the
/// orchestrator dispatches a coding agent for each. The camera node keeps its `node-contract.json` (so
/// the `camera` permission is still declared + granted at load), but it has no `Node.swift` — the
/// camera is produced by an agent reusing `NodeLibrary/camera.macos`, not copied into the fixture.
private var promptSampleURL: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Samples/grayscale-prompt.subz")
}

@Test func promptFixtureShipsNoNodeSource() throws {
    let project = try SZProjectIO.load(from: promptSampleURL)

    // Both nodes are dirty → the orchestrator (dirty-first) spawns an agent for each.
    #expect(project.graph.nodes.count == 2)
    #expect(project.graph.nodes.allSatisfy { $0.kind == .prompt }, "both nodes must be .prompt")

    // The camera node keeps its contract: camera permission + a texture output (granted at load).
    let camera = try #require(project.graph.nodes.first { $0.sfSymbol == "camera" })
    #expect(camera.contract?.requiredPermissions == [.camera])
    #expect(camera.contract?.outputs.first?.type == .texture)

    // No Node.swift is shipped for either node — agents produce them.
    for node in project.graph.nodes {
        let src = SZProjectIO.nodeSourceURL(projectURL: promptSampleURL, nodeID: node.id)
        #expect(!FileManager.default.fileExists(atPath: src.path), "fixture must ship no Node.swift for \(node.title)")
    }
}

@Test func sampleRoundTripsThroughDisk() throws {
    let project = try SZProjectIO.load(from: sampleURL)
    let copy = FileManager.default.temporaryDirectory
        .appending(path: "SZSample-\(UUID().uuidString)").appending(path: "copy.subz")
    defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: copy)
    #expect(try SZProjectIO.load(from: copy) == project)
}
