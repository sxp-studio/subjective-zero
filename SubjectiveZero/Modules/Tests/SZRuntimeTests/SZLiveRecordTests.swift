// SPDX-License-Identifier: AGPL-3.0-only
// Live recording tests: the writer alone (roundtrip through AVAssetReader), and — as later phases
// land — the recorder tap driven headlessly through renderFrame().
import AVFoundation
import Foundation
import Metal
import Testing
@testable import SZCore
@testable import SZRuntime

// MARK: - Harness

private func scratchMovieURL(_ name: String, _ ext: String = "mov") -> URL {
    FileManager.default.temporaryDirectory.appending(path: "szrecord-\(name)-\(UUID().uuidString).\(ext)")
}

/// Decode every video frame of `url` as BGRA and return the (b, g, r, a) of pixel (x, y) per frame.
private func decodedPixels(url: URL, x: Int, y: Int) async throws -> [(b: UInt8, g: UInt8, r: UInt8, a: UInt8)] {
    let asset = AVURLAsset(url: url)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    reader.add(output)
    #expect(reader.startReading())
    var pixels: [(b: UInt8, g: UInt8, r: UInt8, a: UInt8)] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        pixels.append((base[offset], base[offset + 1], base[offset + 2], base[offset + 3]))
    }
    return pixels
}

/// Codec roundtrips (rgb → ycbcr 709 → rgb) cost a little precision.
private func isNear(_ value: UInt8, _ target: Int, tolerance: Int = 4) -> Bool {
    abs(Int(value) - target) <= tolerance
}

/// A 1-node `.subz` whose only texture output "color" is the render endpoint, with the given node
/// source. Caller removes the returned directory's parent.
@MainActor
private func makeOneNodeProject(source: String) throws -> URL {
    let nodeID = SZNodeID()
    let project = SZProject(
        name: "record-test",
        graph: SZGraph(
            nodes: [SZNode(id: nodeID, kind: .generated, title: "solid",
                           contract: SZNodeContract(title: "solid", sfSymbol: "", summary: "",
                                                    outputs: [SZPort(name: "color", type: .texture, display: true)]),
                           position: SZPoint(x: 0, y: 0))],
            connections: [],
            renderEndpoint: SZPortRef(node: nodeID, port: "color")))
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "szrecord-\(UUID().uuidString)").appending(path: "record-test.subz")
    try SZProjectIO.save(project, to: dir)
    try source.write(to: SZProjectIO.nodeSourceURL(projectURL: dir, nodeID: nodeID),
                     atomically: true, encoding: .utf8)
    return dir
}

/// Node source that clears the output to (red: clamp(time), green: 0.5, blue: 0.25) — red IS the
/// clock, which lets decoded frames prove what the tap saw.
private let timeVaryingSource = """
import Metal
final class Node: SZNode {
    func update(_ ctx: SZFrameContext) {
        guard let out = ctx.outputTexture("color") else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: min(1.0, max(0.0, ctx.time)), green: 0.5, blue: 0.25, alpha: 1.0)
        pass.colorAttachments[0].storeAction = .store
        ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }
}
enum SZNodeMain { static func make() -> SZNode { Node() } }
"""

// MARK: - Writer roundtrip

@Test(.enabled(if: SZGPU.isAvailable)) func writerRoundTripsSolidFrames() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let url = scratchMovieURL("writer")
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try SZVideoWriter(
        url: url, settings: .init(width: 64, height: 48, fps: 30, codec: .h264, realtime: false),
        device: device)
    for i in 0..<10 {
        var target = writer.makeFrameTarget()
        while target == nil {   // pool starved → writer is consuming; brief spin is fine in a test
            try await Task.sleep(for: .milliseconds(2))
            target = writer.makeFrameTarget()
        }
        let buffer = try #require(target).pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 128,
               CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !writer.isReadyForMore { try await Task.sleep(for: .milliseconds(2)) }
        #expect(writer.append(try #require(target).pixelBuffer, at: CMTime(value: CMTimeValue(i), timescale: 30)))
    }
    try await writer.finish()

    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    #expect(abs(duration.seconds - 10.0 / 30.0) < 0.001)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let size = try await track.load(.naturalSize)
    #expect(Int(size.width) == 64 && Int(size.height) == 48)
    let formats = try await track.load(.formatDescriptions)
    #expect(formats.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 })
}

/// Pins the finish() workaround: a realtime writer's compiler-bridged async finishWriting()
/// double-resumes (SIGTRAP); the completion-handler form must stay.
@Test(.enabled(if: SZGPU.isAvailable)) func realtimeWriterAsyncFinish() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let url = scratchMovieURL("rt-finish")
    defer { try? FileManager.default.removeItem(at: url) }
    let writer = try SZVideoWriter(
        url: url, settings: .init(width: 32, height: 32, fps: 30, codec: .h264, realtime: true),
        device: device)
    let target = try #require(writer.makeFrameTarget())
    #expect(writer.append(target.pixelBuffer, at: .zero))
    try await writer.finish()
}

@Test(.enabled(if: SZGPU.isAvailable)) func writerUsesFragmentWriting() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let url = scratchMovieURL("fragments")
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try SZVideoWriter(
        url: url, settings: .init(width: 32, height: 32, fps: 60, codec: .h264, realtime: true),
        device: device)
    defer { writer.cancel() }
    #expect(writer.movieFragmentInterval == SZVideoWriter.fragmentInterval)
}

@Test(.enabled(if: SZGPU.isAvailable)) func blockingFinishLeavesReadableFile() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let url = scratchMovieURL("blocking")
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try SZVideoWriter(
        url: url, settings: .init(width: 32, height: 32, fps: 30, codec: .h264, realtime: true),
        device: device)
    for i in 0..<5 {
        var target = writer.makeFrameTarget()
        while target == nil {
            try await Task.sleep(for: .milliseconds(2))
            target = writer.makeFrameTarget()
        }
        while !writer.isReadyForMore { try await Task.sleep(for: .milliseconds(2)) }
        #expect(writer.append(try #require(target).pixelBuffer, at: CMTime(value: CMTimeValue(i), timescale: 30)))
    }
    #expect(writer.finishBlocking(timeout: 10))

    let duration = try await AVURLAsset(url: url).load(.duration)
    #expect(abs(duration.seconds - 5.0 / 30.0) < 0.001)
}

// MARK: - Headless live record through the engine

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func recordsHeadlessRenderFramesAndRewrapsToMP4() async throws {
    let runtime = try requireRuntime(renderSize: (width: 64, height: 64))
    let dir = try makeOneNodeProject(source: timeVaryingSource)
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try runtime.loadProject(at: dir)

    let movURL = scratchMovieURL("record")
    defer { try? FileManager.default.removeItem(at: movURL) }

    #expect(!runtime.isRecording)
    try runtime.startRecording(to: movURL, settings: SZRecordSettings(
        width: 64, height: 64, fps: 60, codec: .h264, renderSize: (64, 64)))
    #expect(runtime.isRecording)
    for _ in 0..<8 {
        runtime.renderFrame()
        // real spacing so engine-time PTS advance past the decimation step
        try await Task.sleep(for: .milliseconds(20))
    }
    let result = try await runtime.stopRecording()
    defer { try? FileManager.default.removeItem(at: result.url) }
    #expect(!runtime.isRecording)
    #expect(result.url.pathExtension == "mp4")
    #expect(!FileManager.default.fileExists(atPath: movURL.path))
    #expect(result.frames >= 1)
    #expect(result.frames + result.dropped <= 8)

    let asset = AVURLAsset(url: result.url)
    #expect(try await asset.load(.duration).seconds > 0)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let size = try await track.load(.naturalSize)
    #expect(Int(size.width) == 64 && Int(size.height) == 64)
}

/// Frame-index ramp for the pause test: red rises a step per ENCODED frame and never saturates,
/// however long the suite ran before this test (wall-clock time would clamp at red 255).
private let frameRampSource = """
import Metal
final class Node: SZNode {
    func update(_ ctx: SZFrameContext) {
        guard let out = ctx.outputTexture("color") else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: min(1.0, Double(ctx.frameIndex) / 16.0), green: 0.5, blue: 0.25, alpha: 1.0)
        pass.colorAttachments[0].storeAction = .store
        ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }
}
enum SZNodeMain { static func make() -> SZNode { Node() } }
"""

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func pausedSpanIsAbsentFromTheTake() async throws {
    let runtime = try requireRuntime(renderSize: (width: 32, height: 32))
    let dir = try makeOneNodeProject(source: frameRampSource)
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try runtime.loadProject(at: dir)

    let movURL = scratchMovieURL("pause")
    defer { try? FileManager.default.removeItem(at: movURL) }
    try runtime.startRecording(to: movURL, settings: SZRecordSettings(
        width: 32, height: 32, fps: 60, codec: .h264, renderSize: (32, 32)))

    let wallStart = Date()
    for _ in 0..<4 {
        runtime.renderFrame()
        try await Task.sleep(for: .milliseconds(40))
    }
    runtime.setPaused(true)
    // frozen-clock duplicates (the resetTimeline-shaped producer): the tap must drop these
    runtime.renderFrame()
    runtime.renderFrame()
    try await Task.sleep(for: .milliseconds(300))
    runtime.setPaused(false)
    // space the first resumed frame past the decimation step (engine time restarts at the frozen value)
    try await Task.sleep(for: .milliseconds(40))
    for _ in 0..<4 {
        runtime.renderFrame()
        try await Task.sleep(for: .milliseconds(40))
    }
    let wallElapsed = Date().timeIntervalSince(wallStart)

    let result = try await runtime.stopRecording()
    defer { try? FileManager.default.removeItem(at: result.url) }
    #expect(result.frames == 8)

    let pixels = try await decodedPixels(url: result.url, x: 16, y: 16)
    #expect(pixels.count == 8)
    // red rises one ramp step per encoded frame (16/frame, codec tolerance ±4): strictly rising
    // across the pause proves no frozen duplicate landed in the file.
    for i in 1..<pixels.count {
        #expect(pixels[i].r > pixels[i - 1].r, "red must rise: frame \(i)")
    }
    // the paused 300 ms must be absent from the file's timeline
    let duration = try await AVURLAsset(url: result.url).load(.duration).seconds
    #expect(duration < wallElapsed - 0.2)
}

// MARK: - Crop

@Test(.enabled(if: SZGPU.isAvailable)) func cropCapturesTheRequestedRegion() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    guard let queue = device.makeCommandQueue() else { Issue.record("no command queue"); return }

    // a 128x128 endpoint whose top-left quadrant is solid green, the rest solid blue
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: 128, height: 128, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead]
    let endpoint = try #require(device.makeTexture(descriptor: descriptor))
    var bytes = [UInt8](repeating: 0, count: 128 * 128 * 4)
    for y in 0..<128 {
        for x in 0..<128 {
            let o = (y * 128 + x) * 4
            let topLeft = x < 64 && y < 64
            bytes[o] = topLeft ? 0 : 255      // b
            bytes[o + 1] = topLeft ? 255 : 0  // g
            bytes[o + 2] = 0                  // r
            bytes[o + 3] = 255
        }
    }
    bytes.withUnsafeBytes { raw in
        endpoint.replace(region: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0,
                         withBytes: raw.baseAddress!, bytesPerRow: 128 * 4)
    }

    // blit fast path (crop pixels == output pixels) and MPS scale path (halved output)
    for (output, name) in [(64, "fast"), (32, "scaled")] {
        let url = scratchMovieURL("crop-\(name)")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try SZLiveVideoRecorder(
            url: url,
            settings: SZRecordSettings(width: output, height: output, fps: 60, codec: .h264,
                                       crop: SZRect(x: 0, y: 0, width: 0.5, height: 0.5),
                                       renderSize: (128, 128)),
            device: device)
        for i in 0..<4 {
            let commandBuffer = try #require(queue.makeCommandBuffer())
            recorder.encodeCapture(on: commandBuffer, endpoint: endpoint,
                                   engineTime: Double(i) / 30.0)
            commandBuffer.commit()
        }
        // finish() drains the in-flight captures itself
        let result = try await recorder.finish()
        #expect(result.frames == 4)

        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == output && Int(size.height) == output, "\(name) path dims")
        // every pixel of the take comes from the green quadrant; blue never leaks in
        let pixel = try #require(try await decodedPixels(url: url, x: output / 2, y: output / 2).first)
        #expect(isNear(pixel.g, 255) && isNear(pixel.b, 0), "\(name) path content")
    }
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func takeUsesTheRecordingRenderSize() async throws {
    let runtime = try requireRuntime(renderSize: (width: 32, height: 32))
    let dir = try makeOneNodeProject(source: timeVaryingSource)
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try runtime.loadProject(at: dir)

    let movURL = scratchMovieURL("size")
    defer { try? FileManager.default.removeItem(at: movURL) }
    try runtime.startRecording(to: movURL, settings: SZRecordSettings(
        width: 96, height: 64, fps: 60, codec: .h264, renderSize: (96, 64)))
    #expect(runtime.renderSize == (96, 64))
    for _ in 0..<3 {
        runtime.renderFrame()
        try await Task.sleep(for: .milliseconds(20))
    }
    let result = try await runtime.stopRecording()
    defer { try? FileManager.default.removeItem(at: result.url) }

    let track = try #require(try await AVURLAsset(url: result.url).loadTracks(withMediaType: .video).first)
    let size = try await track.load(.naturalSize)
    #expect(Int(size.width) == 96 && Int(size.height) == 64)
}

// MARK: - Exclusivity, errors, blocking stop

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func oneTakeAtATime() async throws {
    let runtime = try requireRuntime(renderSize: (width: 32, height: 32))
    let dir = try makeOneNodeProject(source: timeVaryingSource)
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try runtime.loadProject(at: dir)

    let movURL = scratchMovieURL("exclusive")
    defer { try? FileManager.default.removeItem(at: movURL) }
    let settings = SZRecordSettings(width: 32, height: 32, fps: 60, codec: .h264, renderSize: (32, 32))
    try runtime.startRecording(to: movURL, settings: settings)
    #expect(throws: SZRecordError.alreadyRecording) {
        try runtime.startRecording(to: scratchMovieURL("second"), settings: settings)
    }
    runtime.renderFrame()
    let result = try await runtime.stopRecording()
    try? FileManager.default.removeItem(at: result.url)
    await #expect(throws: SZRecordError.notRecording) { _ = try await runtime.stopRecording() }
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func recordingRefusesWithNothingToRender() throws {
    let runtime = try requireRuntime(renderSize: (width: 32, height: 32))
    #expect(throws: SZRecordError.nothingToRender) {
        try runtime.startRecording(to: scratchMovieURL("empty"), settings: SZRecordSettings(
            width: 32, height: 32, fps: 60, codec: .h264, renderSize: (32, 32)))
    }
}

@MainActor
@Test(.enabled(if: SZGPU.isAvailable)) func blockingStopLeavesAPlayableFile() async throws {
    let runtime = try requireRuntime(renderSize: (width: 32, height: 32))
    let dir = try makeOneNodeProject(source: timeVaryingSource)
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try runtime.loadProject(at: dir)

    let movURL = scratchMovieURL("blocking-stop")
    defer { try? FileManager.default.removeItem(at: movURL) }
    try runtime.startRecording(to: movURL, settings: SZRecordSettings(
        width: 32, height: 32, fps: 60, codec: .h264, renderSize: (32, 32)))
    for _ in 0..<4 {
        runtime.renderFrame()
        try await Task.sleep(for: .milliseconds(20))
    }
    let url = try #require(runtime.stopRecordingBlocking(timeout: 10))
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(!runtime.isRecording)
    #expect(try await AVURLAsset(url: url).load(.duration).seconds > 0)
}

// MARK: - Sound

/// One video frame's worth of silent stereo float PCM, timed at `seconds`.
private func makeSilence(seconds: Double, duration: Double) throws -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                   magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                   formatDescriptionOut: &format)
    let frames = Int(48000 * duration)
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frames * 8,
                                       blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                       dataLength: frames * 8, flags: 0, blockBufferOut: &block)
    CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0,
                               dataLength: frames * 8)
    var sample: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
        presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48000),
        packetDescriptions: nil, sampleBufferOut: &sample)
    return try #require(sample)
}

@Test(.enabled(if: SZGPU.isAvailable)) func writerWritesAnAudioTrack() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let url = scratchMovieURL("audio")
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try SZVideoWriter(
        url: url,
        settings: .init(width: 32, height: 32, fps: 30, codec: .h264, realtime: false, sound: true),
        device: device)
    for i in 0..<10 {
        var target = writer.makeFrameTarget()
        while target == nil {
            try await Task.sleep(for: .milliseconds(2))
            target = writer.makeFrameTarget()
        }
        while !writer.isReadyForMore { try await Task.sleep(for: .milliseconds(2)) }
        #expect(writer.append(try #require(target).pixelBuffer, at: CMTime(value: CMTimeValue(i), timescale: 30)))
        while !writer.isReadyForMoreAudio { try await Task.sleep(for: .milliseconds(2)) }
        #expect(writer.appendAudio(try makeSilence(seconds: Double(i) / 30.0, duration: 1.0 / 30.0)))
    }
    try await writer.finish()

    let asset = AVURLAsset(url: url)
    #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let formats = try await audio.load(.formatDescriptions)
    #expect(formats.contains { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC })
}
