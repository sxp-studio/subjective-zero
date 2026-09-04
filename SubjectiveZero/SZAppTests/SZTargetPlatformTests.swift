// SPDX-License-Identifier: AGPL-3.0-only
// The Target Platform pane's values: each row's build count is read from disk per platform, and the
// conversion report follows the conversion state plus each node's flag and status line.
import Testing
import Foundation
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZTargetPlatformTests {

    private static func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sz-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A host on a web project with two built nodes: `a` has its browser source, `b` only a Mac one.
    private static func hostOnWebProject(at dir: URL) throws -> (SZHost, SZNodeID, SZNodeID) {
        let a = SZNode(kind: .generated, title: "Gradient", position: SZPoint(x: 0, y: 0))
        let b = SZNode(kind: .generated, title: "System Audio", position: SZPoint(x: 1, y: 0))
        let url = dir.appending(path: "W.subz")
        let project = SZProject(name: "W", graph: SZGraph(nodes: [a, b]), target: .web)
        try SZProjectIO.save(project, to: url)
        let fm = FileManager.default
        let aWeb = SZProjectIO.nodeSourceURL(projectURL: url, nodeID: a.id, target: .web)
        let bMac = SZProjectIO.nodeSourceURL(projectURL: url, nodeID: b.id, target: .native)
        for file in [aWeb, bMac] {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "// source".write(to: file, atomically: true, encoding: .utf8)
        }
        let host = SZHost()
        host.providerSetupAutoPresented = true
        host.loadedProjectURL = URL(fileURLWithPath: url.path, isDirectory: true)
        host.store.setProject(try SZProjectIO.load(from: url))
        host.refreshTargetBuilds()
        return (host, a.id, b.id)
    }

    @Test func rowsCountBuildsPerPlatformFromDisk() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (host, _, _) = try Self.hostOnWebProject(at: dir)

        let rows = host.targetPlatformRows
        #expect(rows.map(\.id) == [.native, .web])

        let web = try #require(rows.first { $0.id == .web })
        #expect(web.active)
        #expect(web.builtCount == 1)
        #expect(web.nodeCount == 2)
        #expect(!web.converting)
        #expect(web.ready == false, "one of two generated nodes has no browser source")
        #expect(web.help == "three.js \(SZProjectWeb.currentThreeVersion)")

        let native = try #require(rows.first { $0.id == .native })
        #expect(!native.active)
        #expect(native.builtCount == 1)
        #expect(native.nodeCount == 2)
        #expect(native.ready == false)
        #expect(native.help == nil)
    }

    /// The rows read the built set cached on each node; a refresh (what opening the pane does) picks up
    /// a source written behind the host's back, and once every generated node has one the row is ready.
    @Test func aRowIsReadyOnceEveryGeneratedNodeHasItsSource() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (host, _, b) = try Self.hostOnWebProject(at: dir)
        let projectURL = try #require(host.loadedProjectURL)

        let bWeb = SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: b, target: .web)
        try "// source".write(to: bWeb, atomically: true, encoding: .utf8)
        host.refreshTargetBuilds()

        let web = try #require(host.targetPlatformRows.first { $0.id == .web })
        #expect(web.ready == true)
        #expect(web.builtCount == 2)
        #expect(host.targetPlatformNote.isEmpty, "at rest the rows carry the status, not the note")
    }

    /// The footer's preview names what a switch converts; a library node whose source was edited is
    /// converted by the agent, not overwritten with the library's twin.
    @Test func thePreviewSendsEditedLibraryNodesToTheAgent() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (host, _, b) = try Self.hostOnWebProject(at: dir)
        #expect(host.switchPreview(to: .native) == "Switching converts Gradient with an agent. Follow the conversion in the chat.")
        #expect(host.switchPreview(to: .web) == "Switching converts System Audio with an agent. Follow the conversion in the chat.")

        // b was placed from the library but its Mac source no longer matches the library's file
        host.store.mutate { project in
            if let i = project.graph.nodes.firstIndex(where: { $0.id == b }) { project.graph.nodes[i].libraryID = "brightness" }
        }
        #expect(host.conversionPlan(for: .web).queued.map(\.id) == [b])
        #expect(host.conversionPlan(for: .web).copied.isEmpty)

        // with the library's own Mac source in place, the browser twin is copied without an agent
        let projectURL = try #require(host.loadedProjectURL)
        let shipped = SZHost.libraryURL.appending(path: "brightness").appending(path: "Node.swift")
        let bMac = SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: b, target: .native)
        try FileManager.default.removeItem(at: bMac)
        try FileManager.default.copyItem(at: shipped, to: bMac)
        #expect(host.conversionPlan(for: .web).copied.map(\.id) == [b])
        #expect(host.switchPreview(to: .web) == "Switching takes System Audio from the library. Follow the conversion in the chat.")
    }

    /// A rebuild on one platform moves that platform's stamp only; the other platform's file is then
    /// behind the contract, so its row says NEEDS BUILD and a switch converts it.
    @Test func aContractChangeOnOnePlatformMakesTheOthersBuildStale() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (host, a, _) = try Self.hostOnWebProject(at: dir)
        let projectURL = try #require(host.loadedProjectURL)
        let aMac = SZProjectIO.nodeSourceURL(projectURL: projectURL, nodeID: a, target: .native)
        try "// mac source".write(to: aMac, atomically: true, encoding: .utf8)
        host.refreshTargetBuilds()
        let contract = SZNodeContract(title: "Gradient", sfSymbol: "circle", summary: "",
                                      inputs: [SZPort(name: "mode", type: .string)],
                                      outputs: [SZPort(name: "output", type: .texture)])
        // both platforms built against the old (empty) surface
        host.store.mutate { project in
            guard let i = project.graph.nodes.firstIndex(where: { $0.id == a }) else { return }
            project.graph.nodes[i].buildStamps = [.web: .trusting(contract: nil, prompt: nil),
                                                  .native: .trusting(contract: nil, prompt: nil)]
        }
        #expect(host.builtNodeCount(for: .native) == 2)
        // the contract moves and the web build (the active one) is redone: its stamp follows, the Mac one stays
        host.store.mutate { project in
            guard let i = project.graph.nodes.firstIndex(where: { $0.id == a }) else { return }
            project.graph.nodes[i].contract = contract
            project.graph.nodes[i].buildStamp = .trusting(contract: contract, prompt: nil)
        }
        let node = try #require(host.store.project?.graph.node(id: a))
        #expect(node.rebuildReason == nil)
        #expect(node.isStale(for: .native))
        #expect(host.builtNodeCount(for: .native) == 1)
        #expect(host.targetPlatformRows.first { $0.id == .native }?.ready == false)
        #expect(host.conversionPlan(for: .native).queued.map(\.id) == [a])
        // the stamps survive the round trip through project.json, per platform
        try SZProjectIO.save(try #require(host.store.project), to: projectURL)
        let reloaded = try #require(try SZProjectIO.load(from: projectURL).graph.node(id: a))
        #expect(reloaded.buildStamps.count == 2)
        #expect(reloaded.isStale(for: .native))
    }

    /// No generated nodes, no pill: there is nothing to be ready for.
    @Test func anEmptyProjectHasNoReadyPill() {
        let host = SZHost()
        host.providerSetupAutoPresented = true
        host.store.setProject(SZProject(name: "Empty"))

        for row in host.targetPlatformRows { #expect(row.ready == nil) }
    }

    @Test func theReportFollowsTheConversionStateAndEachNodesStatus() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (host, a, b) = try Self.hostOnWebProject(at: dir)
        #expect(host.conversionReport == nil, "no conversion, no report")

        host.conversion = SZConversionState(target: .web, copied: [a], queued: [b], taskID: nil)

        let report = try #require(host.conversionReport)
        #expect(report.target == .web)
        #expect(!report.running, "no task minted means nothing is running")
        #expect(report.total == 2)
        #expect(report.rows.map(\.id) == [a, b])
        let copied = report.rows[0]
        #expect(copied.outcome == .ready)
        #expect(copied.reason == "from the library")
        #expect(report.rows[1].outcome == .queued)
        #expect(report.rows[1].reason == nil)

        host.nodeAgentState[b] = SZNodeAgentState(phase: .needsInput, message: "browsers cannot capture the system mix")

        let flagged = try #require(host.conversionReport?.rows[1])
        #expect(flagged.outcome == .unavailable)
        #expect(flagged.reason == "browsers cannot capture the system mix")
        #expect(host.conversionReport?.summary == "2 nodes, 1 not available")
    }
}
