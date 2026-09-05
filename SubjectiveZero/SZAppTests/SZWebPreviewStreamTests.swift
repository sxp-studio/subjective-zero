// SPDX-License-Identifier: AGPL-3.0-only
// Web thumbnails end to end: the gradient fixture on the page, one node watched through the backend
// seam, and the published surface must be a real picture of that node (320 on the long edge, dark to
// bright top to bottom, which also pins the row order). Shows a small window, like the parity check.
import AppKit
import Foundation
import IOSurface
import SZCore
import Synchronization
import Testing
@testable import SubjectiveZero

@MainActor
@Suite("Web preview stream", .tags(.parity))
struct SZWebPreviewStreamTests {
    private static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let fixture = root.appending(path: "Modules/Tests/Fixtures/Projects/web-gradient.subz")
    private static let library = root.appending(path: "NodeLibrary")

    nonisolated private static var threeIsCached: Bool { SZWebLibraryStore.isReady(SZProjectWeb.currentThreeVersion) }

    @Test(.enabled(if: threeIsCached, "three.js \(SZProjectWeb.currentThreeVersion) is not cached; open a web project in the app once, a test never downloads"),
          .timeLimit(.minutes(3)))
    func aWatchedNodePublishesItsPicture() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sz-web-previews-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let projectURL = try Self.makeProject(in: dir)
        let project = try SZProjectIO.load(from: projectURL)
        let brightness = try #require(project.graph.nodes.first { $0.title == "Brightness" })
        let gradient = try #require(project.graph.nodes.first { $0.title == "Gradient" })

        let (runtime, window) = try await SZWebPageTestSupport.readyPage(project: projectURL)
        defer { runtime.unmount(); window.orderOut(nil) }

        let backend: any SZRenderBackend = runtime
        #expect(backend.capabilities.streamsPreviews)
        let frames = await withCheckedContinuation { (continuation: CheckedContinuation<[SZNodePreviewSurface]?, Never>) in
            let done = Mutex(false)
            backend.setPreviewFrameCallback { frames in
                // the first publish can predate the node's first frame; wait for one of this node
                guard frames.contains(where: { $0.node == brightness.id }) else { return }
                if done.withLock({ let was = $0; $0 = true; return was }) { return }
                continuation.resume(returning: frames)
            }
            Task { @MainActor in
                try runtime.loadProject(project, at: projectURL)
                // a vertical gradient pins the row order too: top must come out dark, bottom bright
                backend.setInputValue(node: gradient.id, port: "angle", floats: [90])
                backend.setWatchedPreviews([(brightness.id, "output")], maxDimension: 320)
                try? await Task.sleep(for: .seconds(15))
                if done.withLock({ let was = $0; $0 = true; return was }) { return }
                continuation.resume(returning: nil)
            }
        }
        let published = try #require(frames, "no thumbnail arrived in 15 s")
        let frame = try #require(published.first { $0.node == brightness.id })
        #expect(frame.port == "output")
        #expect(max(frame.surface.width, frame.surface.height) == 320, "long edge \(frame.surface.width)x\(frame.surface.height)")

        let surface = frame.surface
        _ = surface.lock(options: [.readOnly], seed: nil)
        defer { _ = surface.unlock(options: [.readOnly], seed: nil) }
        let x = surface.width / 2
        let top = Self.luma(surface, x: x, y: surface.height / 8)
        let bottom = Self.luma(surface, x: x, y: surface.height * 7 / 8)
        #expect(bottom > top + 40, "the gradient thumb is not dark to bright, top to bottom (\(top) vs \(bottom))")
        #expect(Self.alpha(surface, x: x, y: surface.height / 2) == 255)
    }

    private static func luma(_ surface: IOSurface, x: Int, y: Int) -> Int {
        let p = surface.baseAddress.advanced(by: y * surface.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        return (Int(p[0]) + Int(p[1]) + Int(p[2])) / 3   // BGRA
    }

    private static func alpha(_ surface: IOSurface, x: Int, y: Int) -> Int {
        Int(surface.baseAddress.advanced(by: y * surface.bytesPerRow + x * 4 + 3).assumingMemoryBound(to: UInt8.self).pointee)
    }

    /// The fixture's graph as a temp web project with the library's Node.js for each node.
    private static func makeProject(in dir: URL) throws -> URL {
        var project = try SZProjectIO.load(from: fixture)
        project.target = .web
        project.web = project.web ?? SZProjectWeb()
        let url = dir.appending(path: "previews.subz")
        try SZProjectIO.save(project, to: url)
        for node in project.graph.nodes {
            try FileManager.default.copyItem(
                at: library.appending(path: node.title.lowercased()).appending(path: "Node.js"),
                to: SZProjectIO.nodeSourceURL(projectURL: url, nodeID: node.id, target: .web))
        }
        return url
    }
}
