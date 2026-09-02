// SPDX-License-Identifier: AGPL-3.0-only
// The checked-in sample project loads FROM DISK through SZProjectIO — not an in-code graph. Proves
// the on-disk `.subz` layout + the project.json/node-contract.json split exist and round-trip.
// (The sample's actual rendering is covered by SZGraphRenderTests.)
import Foundation
import Testing
@testable import SZCore

/// The checked-in fixture projects, located relative to this test source (robust to the test's working
/// directory). `#filePath` = …/Modules/Tests/SZCoreTests/SZSampleLoadTests.swift → up 2 → Tests → Fixtures/Projects.
private let fixtureProjects = URL(filePath: #filePath)
    .deletingLastPathComponent()   // SZCoreTests
    .deletingLastPathComponent()   // Tests
    .appending(path: "Fixtures/Projects")
private var sampleURL: URL { fixtureProjects.appending(path: "grayscale-camera.subz") }

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
private var promptSampleURL: URL { fixtureProjects.appending(path: "grayscale-prompt.subz") }

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

/// The music-reactive sample: system audio → fft → onset → two impulses → cube over a gradient.
private var audioCubeURL: URL { fixtureProjects.appending(path: "audio-cube.subz") }

@Test func audioCubeSampleLoadsFromDisk() throws {
    let project = try SZProjectIO.load(from: audioCubeURL)
    #expect(project.name == "Audio Cube")
    #expect(project.graph.nodes.count == 8)
    #expect(project.graph.connections.count == 8)

    // The capture node's contract folded back in with its permission; the endpoint is the composite.
    let capture = try #require(project.graph.nodes.first { $0.title == "Music In" })
    #expect(capture.contract?.requiredPermissions == [.screenRecording])
    let composite = try #require(project.graph.nodes.first { $0.title == "Composite" })
    #expect(project.graph.renderEndpoint == SZPortRef(node: composite.id, port: "output"))

    // Every node ships its Node.swift, byte-identical to its library source (the fixed UUIDs make the
    // mapping a constant) — so sample/library drift fails here instead of shipping silently. The cube
    // has no library entry: the sample IS its home.
    let libraryIDs = [
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa": "system-audio.macos",
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb": "audio-fft",
        "cccccccc-cccc-4ccc-8ccc-cccccccccccc": "audio-onset",
        "dddddddd-dddd-4ddd-8ddd-dddddddddddd": "impulse-envelope",
        "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee": "impulse-envelope",
        "11111111-1111-4111-8111-111111111111": "gradient",
        "22222222-2222-4222-8222-222222222222": "blend",
    ]
    let libraryRoot = fixtureProjects
        .deletingLastPathComponent()   // Fixtures
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Modules
        .deletingLastPathComponent()   // SubjectiveZero (umbrella root)
        .appending(path: "NodeLibrary")
    for node in project.graph.nodes {
        let src = SZProjectIO.nodeSourceURL(projectURL: audioCubeURL, nodeID: node.id)
        #expect(FileManager.default.fileExists(atPath: src.path), "missing Node.swift for \(node.title)")
        guard let libID = libraryIDs[node.id.uuidString.lowercased()] else { continue }
        let library = libraryRoot.appending(path: libID).appending(path: "Node.swift")
        #expect(try Data(contentsOf: src) == Data(contentsOf: library),
                "\(node.title) drifted from NodeLibrary/\(libID)")
    }
}

@Test func sampleRoundTripsThroughDisk() throws {
    let project = try SZProjectIO.load(from: sampleURL)
    let copy = FileManager.default.temporaryDirectory
        .appending(path: "SZSample-\(UUID().uuidString)").appending(path: "copy.subz")
    defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: copy)
    // `save` writes project.json + contracts, never Node.swift — carry the sources over too, so the copy's
    // load-time source audit (`sourceMismatch` is derived from the source on disk, never persisted) sees
    // the same files.
    for node in project.graph.nodes {
        let src = SZProjectIO.nodeSourceURL(projectURL: sampleURL, nodeID: node.id)
        guard FileManager.default.fileExists(atPath: src.path) else { continue }
        try FileManager.default.copyItem(at: src, to: SZProjectIO.nodeSourceURL(projectURL: copy, nodeID: node.id))
    }
    #expect(try SZProjectIO.load(from: copy) == project)
}
