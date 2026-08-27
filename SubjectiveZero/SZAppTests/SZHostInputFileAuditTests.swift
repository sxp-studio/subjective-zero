// SPDX-License-Identifier: AGPL-3.0-only
// A node whose file input can't be read must SAY so, on the node, with no agent turn — the gap that
// had a Director guessing at causes and a user reading a status string aloud. The verdict is written
// by the host onto `SZNode.unreadableInputs`.
//
// Where it lives is the load-bearing choice: NOT on the transient status state, which every agent
// report clears (`writeNodeStatus` / `retireHostFailure` / `clearTransientAgentStateAfterPromote` all
// wipe `errorDetail` unconditionally). The last test here is that property.
import Testing
import Foundation
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostInputFileAuditTests {

    private static func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sz-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func bundle(in dir: URL, node id: SZNodeID, path: String,
                               fileTypes: [String]? = nil) throws -> URL {
        let url = dir.appending(path: "Patch.subz")
        var project = SZProject(name: "Patch")
        project.graph.nodes = [SZNode(
            id: id, kind: .generated, title: "Depth Map",
            contract: SZNodeContract(title: "Depth Map", sfSymbol: "cube", summary: "",
                                     inputs: [SZPort(name: "modelPath", type: .string,
                                                     ui: SZPortUI(kind: .filePicker, fileTypes: fileTypes),
                                                     def: .string(path))]),
            position: SZPoint(x: 0, y: 0))]
        try SZProjectIO.save(project, to: url)
        return url
    }

    private static func host(at url: URL) throws -> SZHost {
        let host = SZHost()
        host.store.setProject(try SZProjectIO.load(from: url))
        host.loadedProjectURL = url
        return host
    }

    private static func faults(_ host: SZHost, _ id: SZNodeID) -> [String: String] {
        host.store.project?.graph.node(id: id)?.unreadableInputs ?? [:]
    }

    @Test func aMissingFileIsRecordedOnTheNodeWithItsReason() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = SZNodeID()
        let host = try Self.host(at: try Self.bundle(in: dir, node: id, path: "media/ABC/gone.mlpackage"))

        host.classifyInputFiles(node: id)
        #expect(Self.faults(host, id)["modelPath"]?.hasPrefix("no file at ") == true)
    }

    @Test func aFileThatArrivesClearsTheFault() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = SZNodeID()
        let url = try Self.bundle(in: dir, node: id, path: "media/ABC/model.mlpackage")
        let host = try Self.host(at: url)
        host.classifyInputFiles(node: id)
        #expect(!Self.faults(host, id).isEmpty)

        try FileManager.default.createDirectory(at: url.appending(path: "media/ABC/model.mlpackage"),
                                                withIntermediateDirectories: true)
        host.classifyInputFiles(node: id)
        #expect(Self.faults(host, id).isEmpty)
    }

    /// An empty file port is a node WAITING, not a node broken — the distinction that keeps a freshly
    /// dropped node from wearing a red pill before anyone has chosen anything.
    @Test func anUnsetFilePortIsNotAFault() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = SZNodeID()
        let host = try Self.host(at: try Self.bundle(in: dir, node: id, path: ""))
        host.classifyInputFiles(node: id)
        #expect(Self.faults(host, id).isEmpty)
    }

    /// The verdict that would have ended the session behind this feature: the file was THERE.
    @Test func aPresentFileOfTheWrongKindIsStillAFault() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = SZNodeID()
        let url = try Self.bundle(in: dir, node: id, path: "media/ABC/Depth.mlmodel",
                                  fileTypes: ["mlpackage", "mlmodelc"])
        try FileManager.default.createDirectory(at: url.appending(path: "media/ABC"),
                                                withIntermediateDirectories: true)
        try Data("m".utf8).write(to: url.appending(path: "media/ABC/Depth.mlmodel"))

        let host = try Self.host(at: url)
        host.classifyInputFiles(node: id)
        #expect(Self.faults(host, id)["modelPath"] == "Depth.mlmodel is a .mlmodel, and this port takes .mlpackage or .mlmodelc")
    }

    /// Committing a bad path must report it there and then, not several turns later as a black node.
    @Test func settingAPortToAnUnreadableFileReportsItImmediately() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = SZNodeID()
        let host = try Self.host(at: try Self.bundle(in: dir, node: id, path: ""))

        host.setInputDefault(node: id, port: "modelPath", value: .string("/nowhere/at/all.mlpackage"))
        #expect(Self.faults(host, id)["modelPath"]?.hasPrefix("no file at ") == true)
    }

    /// THE reason the verdict lives on the node. An agent reporting anything about the node clears the
    /// transient status detail; a file fault must outlive that, because nothing re-runs it afterwards.
    @Test func anAgentReportDoesNotEraseTheFileFault() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = SZNodeID()
        let host = try Self.host(at: try Self.bundle(in: dir, node: id, path: "media/ABC/gone.mlpackage"))
        host.classifyInputFiles(node: id)

        host.recordNodeStatus(node: id, phase: .ok, message: "built")
        host.retireHostFailure(id)
        host.clearTransientAgentStateAfterPromote(id)
        #expect(!Self.faults(host, id).isEmpty, "a file fault must survive every status writer")
    }

    /// A port fed by a wire ignores its stored default, so judging that default would be a lie.
    @Test func aConnectedFilePortIsNotJudgedOnItsStoredDefault() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = SZNodeID(), upstream = SZNodeID()
        let url = try Self.bundle(in: dir, node: id, path: "media/ABC/gone.mlpackage")
        let host = try Self.host(at: url)
        host.store.mutate { project in
            project.graph.connections = [SZConnection(from: SZPortRef(node: upstream, port: "output"),
                                                      to: SZPortRef(node: id, port: "modelPath"), kind: .data)]
        }
        host.classifyInputFiles(node: id)
        #expect(Self.faults(host, id).isEmpty)
    }

    /// The audit is never persisted: a file missing on THIS machine is not a fact about the project.
    @Test func theVerdictNeverReachesDisk() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = SZNodeID()
        let url = try Self.bundle(in: dir, node: id, path: "media/ABC/gone.mlpackage")
        let host = try Self.host(at: url)
        host.classifyInputFiles(node: id)
        #expect(!Self.faults(host, id).isEmpty)

        try SZProjectIO.save(try #require(host.store.project), to: url)
        let text = try String(contentsOf: url.appending(path: "nodes/\(id.uuidString)/node-contract.json"),
                              encoding: .utf8)
        #expect(!text.contains("unreadableInputs"))
        let reloaded = try SZProjectIO.load(from: url)
        #expect(reloaded.graph.node(id: id)?.unreadableInputs.isEmpty == true)
    }
}

/// `agent_check_path` — the read-only answer an agent could not get any other way. Its working
/// directory is a scratch dir and its tool allowlist has no shell, so before this it could only
/// guess, which is exactly what the Director did.
@MainActor
struct SZAgentCheckPathTests {

    private static func check(_ path: String, accepting: [String] = []) throws -> [String: Any] {
        var args: [String: Any] = ["path": path]
        if !accepting.isEmpty { args["accepting"] = accepting }
        let json = try SZHostBridge.agentCheckPath(args)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sz-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aMissingPathAnswersNoAndSaysWhereItLooked() throws {
        let out = try Self.check("/nowhere/at/all.mov")
        #expect(out["exists"] as? Bool == false)
        #expect(out["readable"] as? Bool == false)
        #expect(out["reason"] as? String == "no file at /nowhere/at/all.mov")
    }

    @Test func aRealFileAnswersYesWithItsSizeAndKind() throws {
        let dir = try Self.scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "clip.mov")
        try Data("frames".utf8).write(to: file)

        let out = try Self.check(file.path)
        #expect(out["exists"] as? Bool == true)
        #expect(out["readable"] as? Bool == true)
        #expect(out["kind"] as? String == "file")
        #expect(out["extension"] as? String == "mov")
        #expect(out["bytes"] as? Int == 6)
        #expect(out["reason"] == nil)
    }

    /// The distinction agents most need: told "directory", an agent goes hunting inside for the real
    /// file, and for a package there isn't one — the package IS the file.
    @Test func aPackageIsReportedAsAPackageNotADirectory() throws {
        let dir = try Self.scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appending(path: "Some.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(try Self.check(app.path)["kind"] as? String == "package")

        let plain = dir.appending(path: "Clips")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(try Self.check(plain.path)["kind"] as? String == "directory")
    }

    /// `reason` is the SAME sentence the node's pill shows, so the agent and the user never describe
    /// one fault in two vocabularies.
    @Test func aWrongKindOfFileComesBackWithTheSameSentenceTheUserSees() throws {
        let dir = try Self.scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appending(path: "Depth.mlmodel")
        try Data("m".utf8).write(to: model)

        let out = try Self.check(model.path, accepting: ["mlpackage"])
        #expect(out["exists"] as? Bool == true)          // it IS there…
        #expect(out["reason"] as? String == "Depth.mlmodel is a .mlmodel, and this port takes .mlpackage")
        let sameAsThePill = SZFileInputAudit.fault(path: model.path, accepting: ["mlpackage"], in: dir)
        #expect(out["reason"] as? String == sameAsThePill)
    }

    @Test func aTildePathIsExpandedRatherThanTreatedAsRelative() throws {
        let out = try Self.check("~/definitely-not-here-\(UUID().uuidString).mov")
        #expect((out["path"] as? String)?.hasPrefix("/") == true)
    }

    @Test func anEmptyPathIsRefusedRatherThanAnswered() {
        #expect(throws: (any Error).self) { try SZHostBridge.agentCheckPath(["path": ""]) }
    }
}

@MainActor
extension SZAgentCheckPathTests {
    /// A relative path has nothing to be relative TO here: nodes run inside the render loop and this
    /// tool reads no project state. Say so rather than answering about a path the caller didn't mean.
    @Test func aRelativePathIsRefusedWithTheReasonWhy() throws {
        let out = try Self.check("models/depth.mlpackage")
        #expect(out["exists"] as? Bool == false)
        #expect((out["reason"] as? String)?.hasPrefix("not an absolute path") == true)
    }
}

/// The other half of the same question: a file the host CAN read, that the node still cannot use. The
/// host has no way to see that from outside — only the code that called `MTKTextureLoader` / `AVPlayer`
/// knows — so the node reports it (`ctx.reportError`, ABI v9) and the host writes it onto the node here.
/// Same home as `unreadableInputs`, for the same reason: every status writer clears the transient state.
@MainActor
struct SZHostNodeErrorTests {

    private static func host(node id: SZNodeID) -> SZHost {
        let host = SZHost()
        var project = SZProject(name: "Patch")
        project.graph.nodes = [SZNode(id: id, kind: .generated, title: "Image File",
                                      contract: SZNodeContract(title: "Image File", sfSymbol: "photo",
                                                               summary: ""),
                                      position: SZPoint(x: 0, y: 0))]
        host.store.setProject(project)
        return host
    }

    private static func reported(_ host: SZHost, _ id: SZNodeID) -> String? {
        host.nodeRuntimeErrors[id]
    }

    @Test func whatTheNodeReportedIsWrittenOntoIt() {
        let id = SZNodeID()
        let host = Self.host(node: id)
        host.applyNodeErrors([id: "could not decode cat.tiff: unsupported format"])
        #expect(Self.reported(host, id) == "could not decode cat.tiff: unsupported format")
    }

    /// The runtime publishes the whole live set, so a node's ABSENCE from it is the clear. Nothing has
    /// to remember to erase a node whose input was replaced with one that works.
    @Test func aNodeMissingFromThePublishIsCleared() {
        let id = SZNodeID()
        let host = Self.host(node: id)
        host.applyNodeErrors([id: "could not decode cat.tiff: unsupported format"])
        host.applyNodeErrors([:])
        #expect(Self.reported(host, id) == nil)
    }

    /// The reason a run must not wipe it: the fleet reporting on this node says nothing about whether
    /// its file decodes, and a cleared reason would put the node back to claiming Ready.
    @Test func itSurvivesEveryStatusWriter() {
        let id = SZNodeID()
        let host = Self.host(node: id)
        host.applyNodeErrors([id: "could not decode cat.tiff: unsupported format"])
        host.recordNodeStatus(node: id, phase: .ok, message: "built")
        host.retireHostFailure(id)
        host.clearTransientAgentStateAfterPromote(id)
        #expect(Self.reported(host, id) != nil)
    }

    /// A publish races project switches and deletes, so it names nodes that may be gone. That must not
    /// touch the store at all — a mutation per stray frame would churn every observer on the canvas.
    @Test func aPublishForNodesThatAreGoneChangesNothing() throws {
        let id = SZNodeID()
        let host = Self.host(node: id)
        let before = try #require(host.store.project?.graph.nodes)
        host.applyNodeErrors([SZNodeID(): "from a project that already closed"])
        #expect(host.store.project?.graph.nodes == before)
    }

    /// A report must never touch the document: it is rewritten at frame rate, and a per-frame write to
    /// `project` would re-arm the preview watch debounce before it could ever fire. Living beside
    /// `nodeAgentState` rather than on `SZNode` is what makes that structural, so this asserts the store
    /// is untouched rather than merely that the field is not encoded.
    @Test func aReportNeverTouchesTheDocument() throws {
        let id = SZNodeID()
        let host = Self.host(node: id)
        let before = try #require(host.store.project)
        host.applyNodeErrors([id: "could not decode cat.tiff: unsupported format"])
        #expect(Self.reported(host, id) != nil)
        #expect(host.store.project == before, "the project must be byte-identical after a report")
    }
}
