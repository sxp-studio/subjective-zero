// SPDX-License-Identifier: AGPL-3.0-only
// A project's target (this Mac or a browser) rides project.json, picks the node source file name, and
// an old file without the key still means this Mac.
import Foundation
import Testing
@testable import SZCore

private let fixtureProjects = URL(filePath: #filePath)
    .deletingLastPathComponent()   // SZCoreTests
    .deletingLastPathComponent()   // Tests
    .appending(path: "Fixtures/Projects")

private func scratchProject() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "SZTarget-\(UUID().uuidString)").appending(path: "p.subz")
}

@Test func webProjectRoundTripsWithTargetAndWeb() throws {
    let project = SZProject(name: "Web", target: .web, web: SZProjectWeb(threeVersion: "0.100.0"))
    let dir = scratchProject()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try SZProjectIO.save(project, to: dir)
    let loaded = try SZProjectIO.load(from: dir)
    #expect(loaded.target == .web)
    #expect(loaded.web == SZProjectWeb(threeVersion: "0.100.0"))
    #expect(loaded == project)
}

@Test func projectWithoutTargetKeyIsNative() throws {
    let json = """
    { "project": { "name": "Old", "author": "",
      "viewport": { "zoom": 1, "translation": { "x": 0, "y": 0 }, "fps": 60,
                    "resolution": { "width": 1280, "height": 720 }, "pixelFormat": "bgra8Unorm" },
      "graph": { "nodes": [], "connections": [] } } }
    """
    let dir = scratchProject()
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try json.write(to: dir.appending(path: "project.json"), atomically: true, encoding: .utf8)
    let loaded = try SZProjectIO.load(from: dir)
    #expect(loaded.target == .native)
    #expect(loaded.web == nil)
}

@Test func newWebProjectPinsTheCurrentThreeVersion() {
    #expect(SZProject(name: "x", target: .web).web?.threeVersion == SZProjectWeb.currentThreeVersion)
    #expect(SZProject(name: "x").web == nil)
}

@Test func nodeSourceFileNameFollowsTheTarget() {
    let dir = URL(filePath: "/tmp/p.subz")
    let id = SZNodeID()
    #expect(SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: id, target: .web).lastPathComponent == "Node.js")
    #expect(SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: id, target: .native).lastPathComponent == "Node.swift")
}

@Test func renderableDropsPromptNodesAndTheirConnections() {
    let built = SZNodeID(), pending = SZNodeID()
    let graph = SZGraph(
        nodes: [SZNode(id: built, kind: .generated, title: "Built", position: SZPoint(x: 0, y: 0)),
                SZNode(id: pending, kind: .prompt, title: "Pending", position: SZPoint(x: 1, y: 0))],
        connections: [SZConnection(from: SZPortRef(node: built, port: "output"),
                                   to: SZPortRef(node: pending, port: "input"), kind: .data)],
        renderEndpoint: SZPortRef(node: pending, port: "output"))
    let renderable = graph.renderable
    #expect(renderable.nodes.map(\.id) == [built])
    #expect(renderable.connections.isEmpty)
    #expect(renderable.renderEndpoint == nil)
}

/// The web fixture ships Node.js, not Node.swift: a clean `sourceMismatch` on both nodes proves the
/// load-time audit read the right file.
@Test func webGradientFixtureLoadsAndAuditsNodeJS() throws {
    let url = fixtureProjects.appending(path: "web-gradient.subz")
    let project = try SZProjectIO.load(from: url)
    #expect(project.target == .web)
    #expect(project.web?.threeVersion == "0.185.1")
    #expect(project.graph.nodes.count == 2)
    for node in project.graph.nodes {
        #expect(node.kind == .generated)
        #expect(node.contract != nil, "\(node.title) has no contract")
        #expect(node.sourceMismatch == false, "\(node.title) audited dirty")
        let src = SZProjectIO.nodeSourceURL(projectURL: url, nodeID: node.id, target: .web)
        #expect(FileManager.default.fileExists(atPath: src.path), "missing Node.js for \(node.title)")
    }
    let gradient = try #require(project.graph.nodes.first { $0.title == "Gradient" })
    let brightness = try #require(project.graph.nodes.first { $0.title == "Brightness" })
    #expect(project.graph.connections.first?.from == SZPortRef(node: gradient.id, port: "output"))
    #expect(project.graph.connections.first?.to == SZPortRef(node: brightness.id, port: "input"))
    #expect(project.graph.renderEndpoint == SZPortRef(node: brightness.id, port: "output"))
}
