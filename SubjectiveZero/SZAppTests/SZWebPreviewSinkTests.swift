// SPDX-License-Identifier: AGPL-3.0-only
// The app half of web thumbnails without a page: a layout message plus a synthetic atlas body must come
// out as one surface per watched key holding that key's tile, bytes in BGRA row order; a body for a
// layout the sink does not hold, or of the wrong size, publishes nothing. Plus the scheme handler's
// POST door, which hands the body over and answers with no content.
import Foundation
import IOSurface
import SZCore
import Synchronization
import Testing
import WebKit
@testable import SubjectiveZero

@Suite("Web preview sink")
struct SZWebPreviewSinkTests {
    private static let width = 8, height = 4
    private static let a = SZNodeID(), b = SZNodeID()

    /// Two 4x2 tiles side by side in an 8x4 atlas; the layout the page would post for them.
    private static var layout: [String: Any] {
        ["layout": 3, "width": width, "height": height,
         "keys": ["\(a.uuidString):output", "\(b.uuidString):glow"],
         "cells": [["x": 0, "y": 0, "w": 4, "h": 2], ["x": 4, "y": 2, "w": 4, "h": 2]]]
    }

    /// An atlas where every pixel encodes its own position: B = x, G = y, R = 200, A = 255.
    private static var body: Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(x); bytes[i + 1] = UInt8(y); bytes[i + 2] = 200; bytes[i + 3] = 255
            }
        }
        return Data(bytes)
    }

    private static func pixel(_ surface: IOSurface, x: Int, y: Int) -> [UInt8] {
        _ = surface.lock(options: [.readOnly], seed: nil)
        defer { _ = surface.unlock(options: [.readOnly], seed: nil) }
        let p = surface.baseAddress.advanced(by: y * surface.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
        return [p[0], p[1], p[2], p[3]]
    }

    private static func publish(_ sink: SZWebPreviewSink, layoutID: Int, body: Data) async -> [SZNodePreviewSurface]? {
        await withCheckedContinuation { continuation in
            let done = Mutex(false)
            sink.onFrames = { frames in
                if done.withLock({ let was = $0; $0 = true; return was }) { return }
                continuation.resume(returning: frames)
            }
            sink.receive(body, url: URL(string: "subz://app/previews?layout=\(layoutID)&seq=1")!)
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                if done.withLock({ let was = $0; $0 = true; return was }) { return }
                continuation.resume(returning: nil)
            }
        }
    }

    @Test func tilesLandInTheirOwnSurfacesInRowOrder() async throws {
        let sink = SZWebPreviewSink()
        sink.setLayout(from: Self.layout)
        let frames = try #require(await Self.publish(sink, layoutID: 3, body: Self.body))
        #expect(frames.count == 2)
        let first = try #require(frames.first { $0.node == Self.a })
        #expect(first.port == "output")
        #expect(first.surface.width == 4 && first.surface.height == 2)
        #expect(Self.pixel(first.surface, x: 0, y: 0) == [0, 0, 200, 255])
        #expect(Self.pixel(first.surface, x: 3, y: 1) == [3, 1, 200, 255])
        let second = try #require(frames.first { $0.node == Self.b })
        #expect(second.port == "glow")
        #expect(Self.pixel(second.surface, x: 0, y: 0) == [4, 2, 200, 255])
        #expect(Self.pixel(second.surface, x: 3, y: 1) == [7, 3, 200, 255])
    }

    @Test func consecutiveBodiesAlternateSurfaces() async throws {
        let sink = SZWebPreviewSink()
        sink.setLayout(from: Self.layout)
        let one = try #require(await Self.publish(sink, layoutID: 3, body: Self.body))
        let two = try #require(await Self.publish(sink, layoutID: 3, body: Self.body))
        let s1 = try #require(one.first { $0.node == Self.a }).surface
        let s2 = try #require(two.first { $0.node == Self.a }).surface
        #expect(s1 !== s2, "a new frame must be a new surface identity, or the layer never recomposites")
    }

    @Test func aBodyForAnotherLayoutOrOfTheWrongSizeIsDropped() async {
        let sink = SZWebPreviewSink()
        sink.setLayout(from: Self.layout)
        #expect(await Self.publish(sink, layoutID: 2, body: Self.body) == nil)
        #expect(await Self.publish(sink, layoutID: 3, body: Data(count: 16)) == nil)
    }

    @Test @MainActor func aPostIsAnsweredWithNoContentAndHandedOver() throws {
        let handler = SZWebSchemeHandler(runtimeDirectory: SZWebRuntime.runtimeDirectory, libraryDirectory: URL(filePath: "/nonexistent"),
                                         projectURL: URL(filePath: "/nonexistent"), threeVersion: "0")
        var received: (Data, URL)?
        handler.onPreviewBody = { received = ($0, $1) }
        var request = URLRequest(url: URL(string: "subz://app/previews?layout=1&seq=9")!)
        request.httpMethod = "POST"
        request.httpBody = Data([1, 2, 3])
        let task = FakeSchemeTask(request: request)
        handler.webView(WKWebView(frame: .zero), start: task)
        #expect(received?.0 == Data([1, 2, 3]))
        #expect(received?.1.query() == "layout=1&seq=9")
        #expect((task.response as? HTTPURLResponse)?.statusCode == 204)
        #expect(task.finished && task.error == nil)
    }

    final class FakeSchemeTask: NSObject, WKURLSchemeTask {
        let request: URLRequest
        var response: URLResponse?
        var finished = false
        var error: (any Error)?
        init(request: URLRequest) { self.request = request }
        func didReceive(_ response: URLResponse) { self.response = response }
        func didReceive(_ data: Data) {}
        func didFinish() { finished = true }
        func didFailWithError(_ error: any Error) { self.error = error }
    }
}
