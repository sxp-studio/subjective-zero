// SPDX-License-Identifier: AGPL-3.0-only
// The check behind RUNTIME.md "Two backends, one contract": the same gradient graph, rendered by the
// Metal runtime and by the web page, must come out the same picture. Both frames are pooled down to a
// small grid and compared channel by channel, plus the one fact a wrong edge or seed would flip: the
// gradient runs dark to bright, left to right, on both.
import AppKit
import Foundation
import Metal
import SZCore
import SZRuntime
import Testing
import WebKit
@testable import SubjectiveZero

extension Tag {
    @Tag static var parity: Self
}

@MainActor
@Suite("Backend parity", .tags(.parity))
struct SZBackendParityTests {
    private static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let fixture = root.appending(path: "Modules/Tests/Fixtures/Projects/web-gradient.subz")
    private static let library = root.appending(path: "NodeLibrary")
    /// The pooled grid both frames are reduced to.
    private static let grid = (width: 32, height: 18)
    private static let tolerance: Float = 12

    nonisolated private static var threeIsCached: Bool { SZWebLibraryStore.isReady(SZProjectWeb.currentThreeVersion) }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device"),
          .enabled(if: threeIsCached, "three.js \(SZProjectWeb.currentThreeVersion) is not cached; open a web project in the app once, a test never downloads"),
          .timeLimit(.minutes(3)))
    func gradientRendersTheSameOnBothBackends() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sz-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let native = try Self.pooled(try Self.renderNative(project: try Self.makeProject(target: .native, in: dir)))
        let web = try Self.pooled(try await Self.renderWeb(project: try Self.makeProject(target: .web, in: dir)))

        let webMean = web.reduce(0, +) / Float(web.count)
        let nativeMean = native.reduce(0, +) / Float(native.count)
        try #require(webMean >= 2, "the offscreen page did not render (web mean \(webMean), native mean \(nativeMean))")

        let difference = zip(native, web).map { abs($0 - $1) }.reduce(0, +) / Float(native.count)
        print("[parity] native mean \(nativeMean), web mean \(webMean), mean channel difference \(difference)/255")
        #expect(difference < Self.tolerance,
                "backends disagree: mean channel difference \(difference)/255 (native mean \(nativeMean), web mean \(webMean))")
        #expect(Self.leftColumn(native) < Self.rightColumn(native), "native gradient is not dark to bright, left to right")
        #expect(Self.leftColumn(web) < Self.rightColumn(web), "web gradient is not dark to bright, left to right")
    }

    // MARK: - The two projects

    /// The fixture's graph as a temp project for `target`, each node given the library's source for
    /// that target (the fixture's own Node.js files are stubs).
    private static func makeProject(target: SZProjectTarget, in dir: URL) throws -> URL {
        var project = try SZProjectIO.load(from: fixture)
        project.target = target
        project.web = target == .web ? (project.web ?? SZProjectWeb()) : nil
        let url = dir.appending(path: "\(target.rawValue).subz")
        try SZProjectIO.save(project, to: url)
        for node in project.graph.nodes {
            let source = library.appending(path: node.title.lowercased()).appending(path: target.sourceFileName)
            try FileManager.default.copyItem(
                at: source, to: SZProjectIO.nodeSourceURL(projectURL: url, nodeID: node.id, target: target))
        }
        return url
    }

    // MARK: - The two renders

    private static func renderNative(project: URL) throws -> SZImageBytes {
        let runtime = try #require(SZRuntime(renderSize: (width: 640, height: 360)), "SZRuntime.init returned nil")
        try runtime.loadProject(at: project)
        return try #require(runtime.captureFrame(), "the Metal runtime captured nothing")
    }

    /// A WKWebView only renders inside a window: a plain one, shown, sized to the fixture's aspect.
    private static func renderWeb(project: URL) async throws -> CGImage {
        let runtime = SZWebRuntime(projectURL: project, threeVersion: SZProjectWeb.currentThreeVersion)
        await runtime.start()
        let webView = try #require(runtime.webView, "the web runtime made no page: \(runtime.phase)")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()
        defer { runtime.unmount(); window.orderOut(nil) }

        for _ in 0..<200 where runtime.phase != .ready {
            if case .failed = runtime.phase { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(runtime.phase == .ready, "the web page never became ready: \(runtime.phase)")
        try runtime.loadProject(try SZProjectIO.load(from: project), at: project)
        try await Task.sleep(for: .seconds(1))
        let snapshot = await runtime.captureViewport(maxDimension: 320)
        let png = try #require(snapshot, "the page gave no snapshot")
        let rep = try #require(NSBitmapImageRep(data: png), "the snapshot is not a PNG")
        return try #require(rep.cgImage, "the snapshot has no image")
    }

    // MARK: - Pooling and comparison

    /// RGB, 0...255, average-pooled onto `grid`, row-major, three floats per cell.
    private static func pooled(_ frame: SZImageBytes) throws -> [Float] {
        pool(width: frame.width, height: frame.height, bytesPerRow: frame.width * 4, bytes: frame.bgra, rgb: [2, 1, 0])
    }

    private static func pooled(_ image: CGImage) throws -> [Float] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn, "could not decode the snapshot to RGBA")
        return pool(width: width, height: height, bytesPerRow: width * 4, bytes: bytes, rgb: [0, 1, 2])
    }

    private static func pool(width: Int, height: Int, bytesPerRow: Int, bytes: [UInt8], rgb: [Int]) -> [Float] {
        var out = [Float](repeating: 0, count: grid.width * grid.height * 3)
        for gy in 0..<grid.height {
            let y0 = gy * height / grid.height, y1 = max(y0 + 1, (gy + 1) * height / grid.height)
            for gx in 0..<grid.width {
                let x0 = gx * width / grid.width, x1 = max(x0 + 1, (gx + 1) * width / grid.width)
                var sum: [Float] = [0, 0, 0]
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let i = y * bytesPerRow + x * 4
                        for c in 0..<3 { sum[c] += Float(bytes[i + rgb[c]]) }
                    }
                }
                let count = Float((y1 - y0) * (x1 - x0))
                let cell = (gy * grid.width + gx) * 3
                for c in 0..<3 { out[cell + c] = sum[c] / count }
            }
        }
        return out
    }

    private static func column(_ pooled: [Float], _ gx: Int) -> Float {
        var sum: Float = 0
        for gy in 0..<grid.height {
            let cell = (gy * grid.width + gx) * 3
            sum += pooled[cell] + pooled[cell + 1] + pooled[cell + 2]
        }
        return sum / Float(grid.height * 3)
    }

    private static func leftColumn(_ pooled: [Float]) -> Float { column(pooled, 0) }
    private static func rightColumn(_ pooled: [Float]) -> Float { column(pooled, grid.width - 1) }
}
