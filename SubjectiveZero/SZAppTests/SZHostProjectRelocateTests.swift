// SPDX-License-Identifier: AGPL-3.0-only
// Saving while agents work. Two properties, and the whole change is between them:
//  - Save As is available while an agent owns the project: it writes and tears nothing down;
//  - a project SWITCH still is not, because it does.
// The relocation is what buys the first: same live document, new path. These tests pin what must
// survive it (runs, claims, queued messages) and what must land at the new path (the recovery set a
// crash reads back). `recordInHistory: false` throughout — a unit test must not rewrite the user's
// recents or reopen target.
import Testing
import Foundation
import SZAI
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostProjectRelocateTests {

    /// A `.subz` on disk with one node and the scratch a live run would have left in it.
    private static func makeBundle(_ name: String, in dir: URL, node: SZNodeID? = nil) throws -> URL {
        let url = dir.appending(path: "\(name).subz")
        var project = SZProject(name: name)
        if let node {
            project.graph.nodes = [SZNode(id: node, kind: .prompt, title: "A", prompt: "do A",
                                          position: SZPoint(x: 0, y: 0))]
        }
        try SZProjectIO.save(project, to: url)
        return url
    }

    private static func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "sz-relocate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A host bound to a real bundle on disk, with no runtime (nothing here compiles).
    private static func host(at url: URL) throws -> SZHost {
        let host = SZHost()
        host.store.setProject(try SZProjectIO.load(from: url))
        host.loadedProjectURL = url
        return host
    }

    // MARK: - The complaint, as assertions

    /// THE regression test. A run owning the project must not take Save with it.
    @Test func saveIsAvailableWhileAgentsOwnTheProject() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(at: try Self.makeBundle("A", in: dir))

        let run = SZRunState(taskID: UUID(), claim: SZClaimToken(label: "run"),
                             instruction: "build", ownsGraphOp: false, workSet: [])
        host.activeRuns[run.taskID] = run

        #expect(host.agentsOwnProject, "the run owns the project")
        #expect(!host.isOpeningProject, "but nothing is replacing the document, so a save is fine")
        #expect(host.isBusyForProjectSwitch, "while a switch stays refused")
    }

    /// An open in flight is the one thing that DOES refuse a Save As: the target is about to be
    /// replaced. The guard sits ahead of the panel, so a refused call returns without showing one.
    @Test func saveAsIsRefusedWhileAnotherOpenIsInFlight() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try Self.host(at: try Self.makeBundle("A", in: dir))
        host.openingProject = "Something"

        #expect(host.saveProjectAsInteractively() == false)
    }

    /// A placed project keeps being written as it changes, which is why it has no Save item at all:
    /// an agent's edit during a run is on disk without anyone asking.
    @Test func aPlacedProjectIsPersistedByEditsDuringARun() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.makeBundle("A", in: dir)
        let host = try Self.host(at: url)
        let run = SZRunState(taskID: UUID(), claim: SZClaimToken(label: "run"),
                             instruction: "build", ownsGraphOp: false, workSet: [])
        host.activeRuns[run.taskID] = run

        host.store.mutate { $0.name = "Renamed" }
        host.persistProject()

        #expect(try SZProjectIO.load(from: url).name == "Renamed")
    }

    // MARK: - What a relocation must preserve

    /// The property `switchProject` cannot satisfy, and the reason Save As stops using it.
    @Test func relocationKeepsLiveRunStateIntact() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nodeID = SZNodeID()
        let source = try Self.makeBundle("A", in: dir, node: nodeID)
        let host = try Self.host(at: source)

        let claim = SZClaimToken(label: "run")
        #expect(host.ledger.tryAcquire([.node(nodeID)], as: claim))
        let run = SZRunState(taskID: UUID(), claim: claim, instruction: "build",
                             ownsGraphOp: false, workSet: [nodeID])
        host.activeRuns[run.taskID] = run

        let dest = dir.appending(path: "B.subz")
        try FileManager.default.copyItem(at: source, to: dest)
        try host.relocateProject(to: dest, recordInHistory: false)

        #expect(host.loadedProjectURL == dest)
        #expect(host.activeRuns[run.taskID] === run, "the run survives the move")
        #expect(host.ledger.holder(of: .node(nodeID)) == claim, "and so does its claim")
        #expect(host.agentsOwnProject, "nothing was torn down")
    }

    /// The crash requirement: everything a relaunch reads back has to exist at the NEW path. The
    /// queues are seeded and flushed at the SOURCE first, so their skip-an-unchanged-write
    /// signatures are warm — without clearing those, the first write at the new path is skipped and
    /// a crash a second later finds nothing there.
    @Test func relocationLandsTheRecoverySetAtTheNewPath() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.makeBundle("A", in: dir)
        let host = try Self.host(at: source)

        host.store.appendChatMessage(SZChatMessage(role: .user, text: "hello"), to: .director)
        host.mailbox.enqueue(SZMessageEnvelope(recipient: SZChatScope.directorKey, intent: .chat,
                                               message: SZChatMessage(role: .user, text: "later")))
        host.pendingTasks = [SZTask(title: "Queued", instruction: "build something")]
        host.agentGraphRuns = [SZAgentGraphRun(id: UUID(), agent: "director")]
        host.flushEverything()
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: source.appending(path: ".staging/message-queue.json").path),
                "the signatures must be warm for this test to mean anything")

        let dest = dir.appending(path: "B.subz")
        try fm.copyItem(at: source, to: dest)
        try fm.removeItem(at: dest.appending(path: ".staging"))   // as if nothing had been copied
        try host.relocateProject(to: dest, recordInHistory: false)

        #expect(fm.fileExists(atPath: dest.appending(path: "project.json").path))
        #expect(fm.fileExists(atPath: dest.appending(path: "runs.json").path))
        #expect(fm.fileExists(atPath: dest.appending(path: ".staging/message-queue.json").path),
                "a cleared queue signature must let the first write at the new path through")
        #expect(fm.fileExists(atPath: dest.appending(path: ".staging/tasks.json").path))
        #expect(!SZChatTranscriptIO.loadAll(projectURL: dest).isEmpty)
        // And it is the CONTENT that arrived, not an empty husk.
        #expect(SZMessageQueueIO.load(projectURL: dest).count == 1)
        #expect(SZTaskQueueIO.load(projectURL: dest).tasks.count == 1)
        #expect(SZAgentGraphRunIO.load(projectURL: dest)?.count == 1)
    }

    /// A queued attachment must not point into a bundle that is about to be deleted.
    @Test func relocationRebasesAttachmentURLs() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.makeBundle("A", in: dir)
        let host = try Self.host(at: source)
        let relative = "attachments/\(UUID().uuidString)/pic.png"
        host.store.appendChatMessage(
            SZChatMessage(role: .user, text: "look",
                          attachments: [SZChatAttachment(filename: "pic.png",
                                                         url: source.appending(path: relative),
                                                         bundlePath: relative,
                                                         byteCount: 3, isImage: true)]),
            to: .director)

        let dest = dir.appending(path: "B.subz")
        try FileManager.default.copyItem(at: source, to: dest)
        try host.relocateProject(to: dest, recordInHistory: false)

        let moved = host.store.messages(for: .director).first?.attachments.first
        #expect(moved?.url == dest.appending(path: relative))
    }

    /// A run must not keep handing agents the path it started at. `startRun` used to capture
    /// `loadedProjectURL` once and thread it into every turn's grant, so after an untitled rescue
    /// every agent for the rest of the traversal was pointed at a directory that had been deleted.
    @Test func agentGrantsFollowTheProjectAfterARelocation() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.makeBundle("A", in: dir)
        let host = try Self.host(at: source)
        let run = SZRunState(taskID: UUID(), claim: SZClaimToken(label: "run"),
                             instruction: "build", ownsGraphOp: false, workSet: [])
        host.activeRuns[run.taskID] = run

        let dest = dir.appending(path: "B.subz")
        try FileManager.default.copyItem(at: source, to: dest)
        try host.relocateProject(to: dest, recordInHistory: false)

        // What the spawn sites read. A captured value would still name the source here.
        #expect(host.loadedProjectURL == dest)
        let order = SZTurnOrder(agent: "coding", brief: "b", session: .spawn, tools: nil,
                                choice: SZModelChoice(providerID: "claude"))
        let request = SZAgentRunRequest(order, workingDirectory: dir,
                                        packageDirectory: host.loadedProjectURL,
                                        cacheDirectory: dir, mcpPort: 1, defaultTools: [])
        #expect(request.packageDirectory == dest)
    }

    // MARK: - Refusals

    /// Relocating onto our own path is a no-op, not a self-conflict on our own lock file. Covers the
    /// /tmp vs /private/tmp symlink form, which is what a save panel actually hands back.
    @Test func relocatingToTheSamePathIsANoOp() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.makeBundle("A", in: dir)
        let host = try Self.host(at: source)

        #expect(try host.relocateProject(to: source, recordInHistory: false) == false)
        let viaSymlink = URL(filePath: "/tmp").appending(
            path: source.path.replacingOccurrences(of: "/private/tmp/", with: ""))
        if source.path.hasPrefix("/private/tmp/") {
            #expect(try host.relocateProject(to: viaSymlink, recordInHistory: false) == false)
        }
        #expect(host.loadedProjectURL == source)
    }

    /// A destination another instance holds must leave the live project exactly where it was.
    @Test func relocationRefusesADestinationLockedByAnotherInstance() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try Self.makeBundle("A", in: dir)
        let host = try Self.host(at: source)
        let dest = dir.appending(path: "B.subz")
        try FileManager.default.copyItem(at: source, to: dest)

        let otherInstance = try SZProjectDirectoryLock.acquire(forProjectAt: dest)
        defer { otherInstance.release() }

        #expect(throws: SZProjectLifecycleError.self) {
            try host.relocateProject(to: dest, recordInHistory: false)
        }
        #expect(host.loadedProjectURL == source, "the live project must not have moved")
    }
}
