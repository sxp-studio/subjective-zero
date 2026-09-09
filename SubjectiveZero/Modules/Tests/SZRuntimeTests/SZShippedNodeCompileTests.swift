// SPDX-License-Identifier: AGPL-3.0-only
// Every shipped `NodeLibrary/<id>/Node.swift` compiles against the CURRENT node kit.
//
// Library sources never pass through `swift build`: a node is compiled at placement, from source,
// against whatever `SZNodeKit` the app carries. So an ABI change that renames an accessor or moves a
// context member breaks every shipped node that used it, and nothing notices until somebody places
// one. The per-node tests cover the handful with a GPU check; this covers the rest, which is most of
// them. Same job `SZCardProbeTests` does for every shipped `Card.swift`.
import Foundation
import Testing
@testable import SZRuntime

private let libraryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()   // SZRuntimeTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // Modules
    .deletingLastPathComponent()   // SubjectiveZero
    .appending(path: "NodeLibrary")

private var toolchainIsReady: Bool { SZToolchain.availability() != .missing }

@Test(.enabled(if: toolchainIsReady, "no developer tools; a node compile needs swiftc"),
      .timeLimit(.minutes(5)))
func everyShippedNodeCompilesAgainstTheCurrentKit() throws {
    let fm = FileManager.default
    let sources = try fm.contentsOfDirectory(at: libraryRoot, includingPropertiesForKeys: nil)
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .map { $0.appending(path: "Node.swift") }
        .filter { fm.fileExists(atPath: $0.path) }
        .sorted { $0.path < $1.path }
    // camera.web ships only a Node.js, so the count is one short of the folder count.
    try #require(sources.count > 20, "the shipped library moved? found \(sources.count)")

    let work = fm.temporaryDirectory.appending(path: "sz-node-compile-\(UUID().uuidString)")
    try fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }
    let toolchain = SZToolchain()

    for source in sources {
        let id = source.deletingLastPathComponent().lastPathComponent
        // A build dir per node: the module name is a fresh UUID per dir, so two nodes with identical
        // source never collide, and the node tier's content-addressed cache still does its job.
        let buildDir = work.appending(path: id)
        #expect(throws: Never.self, "\(id)/Node.swift does not compile against this node kit") {
            _ = try toolchain.compile(nodeSource: source, into: buildDir)
        }
    }
}
