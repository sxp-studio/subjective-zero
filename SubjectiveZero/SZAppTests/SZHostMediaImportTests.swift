// SPDX-License-Identifier: AGPL-3.0-only
// A file a user picks or drops belongs to the PROJECT, not to wherever they happened to keep it.
// These pin the copy and the reference it leaves behind: what lands on disk, what the port ends up
// holding, and the cases that must NOT copy (a file already inside, a value already relative).
//
// The import is asynchronous by design — a 4 GB copy on the main actor would freeze the render loop
// — so each test drives `SZHost.copyIntoBundle` (the byte copy) or awaits the port settling.
import Testing
import Foundation
import SZCore
@testable import SubjectiveZero

@MainActor
struct SZHostMediaImportTests {

    private static func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sz-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A `.subz` whose one node has a `filePicker` input holding `path`.
    private static func bundle(in dir: URL, node id: SZNodeID, path: String) throws -> URL {
        let url = dir.appending(path: "Patch.subz")
        var project = SZProject(name: "Patch")
        project.graph.nodes = [SZNode(
            id: id, kind: .generated, title: "Video File",
            contract: SZNodeContract(title: "Video File", sfSymbol: "film", summary: "",
                                     inputs: [SZPort(name: "path", type: .string,
                                                     ui: SZPortUI(kind: .filePicker), def: .string(path))]),
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

    private static func file(_ url: URL, bytes: String = "clip") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: url)
    }

    /// Wait for the import task to land the port on its bundle-relative value.
    private static func settledPath(_ host: SZHost, node: SZNodeID) async -> String? {
        for _ in 0..<200 {
            if case .string(let value)? = host.store.project?.graph.node(id: node)?
                .contract?.inputs.first(where: { $0.name == "path" })?.def,
               value.hasPrefix("\(SZProjectMedia.directoryName)/") { return value }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    // MARK: - The copy

    @Test func theByteCopyLandsTheFileWhereTheReferenceSaysItIs() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "Downloads/IMG_2479.MOV")
        try Self.file(source)

        let project = dir.appending(path: "Patch.subz")
        let (relative, destination) = SZProjectMedia.destination(for: "IMG_2479.MOV", in: project)
        try SZHost.copyIntoBundle(source, to: destination)

        #expect(FileManager.default.contentsEqual(atPath: source.path, andPath: destination.path))
        #expect(project.appending(path: relative).path == destination.path)
    }

    /// A folder-shaped file (a package) is one file to everyone using it, and must arrive whole.
    @Test func aFolderShapedFileIsCopiedWithItsContents() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let package = dir.appending(path: "Depth.mlpackage")
        try Self.file(package.appending(path: "Manifest.json"), bytes: "{}")

        let destination = dir.appending(path: "Patch.subz/media/ABC/Depth.mlpackage")
        try SZHost.copyIntoBundle(package, to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "Manifest.json").path))
    }

    /// A symlink is followed, or the project would hold a pointer back out to a file that can go away
    /// — the exact failure this whole change exists to end.
    @Test func aSymlinkIsResolvedRatherThanCopiedAsALink() throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appending(path: "real/IMG.MOV")
        try Self.file(real, bytes: "frames")
        let link = dir.appending(path: "link.MOV")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let destination = dir.appending(path: "Patch.subz/media/ABC/link.MOV")
        try SZHost.copyIntoBundle(link, to: destination)
        let copied = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect(copied[.type] as? FileAttributeType == .typeRegular)
        #expect(try Data(contentsOf: destination) == Data("frames".utf8))
    }

    // MARK: - What the port ends up holding

    @Test func pickingAFileOutsideTheProjectRepointsThePortAtTheProjectsOwnCopy() async throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "Downloads/IMG_2479.MOV")
        try Self.file(source)
        let id = SZNodeID()
        let host = try Self.host(at: try Self.bundle(in: dir, node: id, path: ""))

        host.setInputDefault(node: id, port: "path", value: .string(source.path))
        let settled = try #require(await Self.settledPath(host, node: id))
        #expect(settled.hasSuffix("/IMG_2479.MOV"))
        // The bytes are really there, under the path the port now names.
        let projectURL = try #require(host.loadedProjectURL)
        let landed = projectURL.appending(path: settled)
        #expect(FileManager.default.contentsEqual(atPath: source.path, andPath: landed.path))
        // …and it survives a reload, which is the whole point.
        let reloaded = try SZProjectIO.load(from: projectURL)
        if case .string(let onDisk)? = reloaded.graph.node(id: id)?.contract?.inputs.first?.def {
            #expect(onDisk == settled)
        } else { Issue.record("the reloaded contract lost its path") }
    }

    /// Idempotence, and the guard that gives it: the value the import writes back can never satisfy
    /// `needsImport` a second time, so re-committing it copies nothing.
    @Test func aValueAlreadyInsideTheProjectIsNeverCopiedAgain() async throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = SZNodeID()
        let url = try Self.bundle(in: dir, node: id, path: "")
        let host = try Self.host(at: url)
        let existing = "media/ABCD/already.MOV"
        try Self.file(url.appending(path: existing))

        host.setInputDefault(node: id, port: "path", value: .string(existing))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(SZProjectMedia.directoryName == "media")
        let media = url.appending(path: "media")
        let dirs = try FileManager.default.contentsOfDirectory(atPath: media.path)
        #expect(dirs == ["ABCD"], "a value already inside the project must not be copied, got \(dirs)")
    }

    /// An ABSOLUTE path that already points inside the bundle is a reference, not a new copy: it
    /// becomes the relative form with no second set of bytes.
    @Test func anAbsolutePathInsideTheProjectBecomesRelativeWithoutCopying() {
        let project = URL(fileURLWithPath: "/tmp/Patch.subz")
        let inside = project.appending(path: "media/ABCD/already.MOV")
        #expect(!SZProjectMedia.needsImport(inside.path, in: project))
        #expect(SZProjectMedia.relativePath(for: inside, in: project) == "media/ABCD/already.MOV")
    }

    /// A live slider tick is not a decision, so it must never start a copy. Only committed writes do.
    @Test func anUncommittedWriteDoesNotCopyAnything() async throws {
        let dir = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "Downloads/IMG.MOV")
        try Self.file(source)
        let id = SZNodeID()
        let url = try Self.bundle(in: dir, node: id, path: "")
        let host = try Self.host(at: url)

        host.setInputDefault(node: id, port: "path", value: .string(source.path), persist: false)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!FileManager.default.fileExists(atPath: url.appending(path: "media").path))
    }
}

/// What the RUNTIME is handed for a string value. Both push sites go through this one rule —
/// `setInputDefault` for a single knob, `applyPortValueChanges` for the values a port edit moved —
/// so a file port can never reach a node as the bundle-relative form it is stored as. A node opens
/// what it is handed, and a relative path is relative to nothing inside the render loop.
@MainActor
struct SZHostRuntimeStringTests {

    private static func host(project url: URL) -> SZHost {
        let host = SZHost()
        host.loadedProjectURL = url
        return host
    }

    private static func filePort(_ value: String) -> SZPort {
        SZPort(name: "path", type: .string, ui: SZPortUI(kind: .filePicker), def: .string(value))
    }

    @Test func aFilePortIsResolvedAgainstTheBundle() {
        let host = Self.host(project: URL(fileURLWithPath: "/tmp/Patch.subz"))
        #expect(host.runtimeString("media/ABC/clip.mov", port: Self.filePort(""))
                == "/tmp/Patch.subz/media/ABC/clip.mov")
    }

    @Test func anAbsoluteFilePortIsHandedOverUnchanged() {
        let host = Self.host(project: URL(fileURLWithPath: "/tmp/Patch.subz"))
        #expect(host.runtimeString("/Users/c/Downloads/IMG.MOV", port: Self.filePort(""))
                == "/Users/c/Downloads/IMG.MOV")
    }

    /// A plain string port carrying path-shaped text is NOT a path, and must not be rewritten.
    @Test func aNonFilePortIsNeverRewritten() {
        let host = Self.host(project: URL(fileURLWithPath: "/tmp/Patch.subz"))
        let text = SZPort(name: "label", type: .string, ui: SZPortUI(kind: .field), def: .string(""))
        #expect(host.runtimeString("media/ABC/clip.mov", port: text) == "media/ABC/clip.mov")
        #expect(host.runtimeString("media/ABC/clip.mov", port: nil) == "media/ABC/clip.mov")
    }
}
