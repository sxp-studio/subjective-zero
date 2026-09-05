// SPDX-License-Identifier: AGPL-3.0-only
// A web project's take end to end through the backend seam: the gradient fixture on the page, a take
// at a size the tile does not have, a pause in the middle, stop. The file must be the kind a Mac take
// produces (mp4, the requested size, plausible frame count, the paused span absent) and a real picture
// of the graph (dark top, bright bottom, which also pins the row order). Shows a small window, like
// the parity check.
import AVFoundation
import AppKit
import Foundation
import QuartzCore
import SZCore
import Testing
@testable import SubjectiveZero

@MainActor
@Suite("Web recording", .tags(.parity))
struct SZWebRecordTests {
    private static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let fixture = root.appending(path: "Modules/Tests/Fixtures/Projects/web-gradient.subz")
    private static let library = root.appending(path: "NodeLibrary")

    nonisolated private static var threeIsCached: Bool { SZWebLibraryStore.isReady(SZProjectWeb.currentThreeVersion) }

    @Test(.enabled(if: threeIsCached, "three.js \(SZProjectWeb.currentThreeVersion) is not cached; open a web project in the app once, a test never downloads"),
          .timeLimit(.minutes(3)))
    func aTakeIsTheSameKindOfFileAsAMacTake() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sz-web-record-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let projectURL = try Self.makeProject(in: dir)
        let project = try SZProjectIO.load(from: projectURL)
        let gradient = try #require(project.graph.nodes.first { $0.title == "Gradient" })

        let (runtime, window) = try await SZWebPageTestSupport.readyPage(project: projectURL)
        defer { runtime.unmount(); window.orderOut(nil) }
        let backend: any SZRenderBackend = runtime
        #expect(backend.capabilities.canRecord)
        try backend.loadProject(project, at: projectURL)
        backend.setInputValue(node: gradient.id, port: "angle", floats: [90])   // dark top, bright bottom
        try await Task.sleep(for: .seconds(1))
        let pageSize = backend.renderSize
        #expect(pageSize.width > 0 && pageSize.height > 0)

        let take = dir.appending(path: "take.mov")
        let settings = SZRecordSettings(width: 320, height: 180, fps: 30, codec: .h264,
                                        crop: .unit, renderSize: (960, 540), sound: .off)
        let began = CACurrentMediaTime()
        try backend.startRecording(to: take, settings: settings)
        #expect(backend.isRecording)
        #expect(backend.renderSize == (960, 540), "a rolling take owns the picture size")
        #expect(throws: (any Error).self) { try backend.startRecording(to: take, settings: settings) }   // one at a time
        try await Task.sleep(for: .seconds(1.5))
        backend.setPaused(true)
        try await Task.sleep(for: .milliseconds(600))
        backend.setPaused(false)
        try await Task.sleep(for: .seconds(1))
        let result = try await backend.stopRecording()
        let wall = CACurrentMediaTime() - began
        #expect(!backend.isRecording)
        #expect(backend.renderSize == pageSize, "the picture follows the tile again after the take")

        #expect(result.url.pathExtension == "mp4")
        #expect(result.frames >= 40, "\(result.frames) frames in a ~2.5 s take at 30 fps")
        #expect(result.dropped <= result.frames / 10, "\(result.dropped) dropped of \(result.frames)")
        #expect(result.duration < wall - 0.3, "the paused span must be absent (duration \(result.duration), wall \(wall))")

        let asset = AVURLAsset(url: result.url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 320 && Int(size.height) == 180)
        let last = try #require(try Self.lastFrame(of: asset, track: track))
        let top = Self.luma(last, x: 160, y: 20), bottom = Self.luma(last, x: 160, y: 160)
        #expect(bottom > top + 40, "the take is not dark to bright, top to bottom (\(top) vs \(bottom))")
    }

    /// The last decoded frame as BGRA bytes with its row stride.
    private static func lastFrame(of asset: AVURLAsset, track: AVAssetTrack) throws -> (bytes: [UInt8], stride: Int)? {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        guard reader.startReading() else { return nil }
        var last: (bytes: [UInt8], stride: Int)?
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let count = stride * CVPixelBufferGetHeight(buffer)
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            last = (Array(UnsafeBufferPointer(start: base, count: count)), stride)
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        return last
    }

    private static func luma(_ frame: (bytes: [UInt8], stride: Int), x: Int, y: Int) -> Int {
        let i = y * frame.stride + x * 4
        return (Int(frame.bytes[i]) + Int(frame.bytes[i + 1]) + Int(frame.bytes[i + 2])) / 3
    }

    /// The fixture's graph as a temp web project with the library's Node.js for each node.
    private static func makeProject(in dir: URL) throws -> URL {
        var project = try SZProjectIO.load(from: fixture)
        project.target = .web
        project.web = project.web ?? SZProjectWeb()
        let url = dir.appending(path: "record.subz")
        try SZProjectIO.save(project, to: url)
        for node in project.graph.nodes {
            try FileManager.default.copyItem(
                at: library.appending(path: node.title.lowercased()).appending(path: "Node.js"),
                to: SZProjectIO.nodeSourceURL(projectURL: url, nodeID: node.id, target: .web))
        }
        return url
    }
}
