// SPDX-License-Identifier: AGPL-3.0-only
// SZVideoWriter — bgra8 Metal textures → CVPixelBuffers → AVAssetWriter, the encode half of live
// recording. Frames stay on the GPU end to end: the recorder blits (or MPS-scales) the render
// endpoint straight into a pixel-buffer-backed texture from the adaptor's pool — no CPU readback.
// Takes are written as fragmented QuickTime (.mov) so a crash mid-take leaves a playable file;
// h264/hevc takes are rewrapped to .mp4 on stop (fragments are a QuickTime-only feature).
import AVFoundation
import CoreVideo
import Metal

/// Encodable codecs for a take. Every take records into .mov (fragment writing); h264/hevc
/// rewrap to .mp4 on stop, proRes422 stays .mov.
public enum SZVideoCodec: String, CaseIterable, Sendable {
    case h264
    case hevc
    case proRes422

    /// Extension of the finished take after any rewrap.
    public var finalFileExtension: String {
        switch self {
        case .h264, .hevc: "mp4"
        case .proRes422: "mov"
        }
    }

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .proRes422: .proRes422
        }
    }
}

/// Errors from the recording path (writer + runtime API).
public enum SZRecordError: Error, Equatable {
    /// A take is already rolling — the engine records one stream at a time.
    case alreadyRecording
    /// `stopRecording` with no take rolling.
    case notRecording
    /// Nothing to render (no schedule / no render endpoint).
    case nothingToRender
    /// AVAssetWriter setup, append, or finalize failed; carries the underlying description.
    case writerFailed(String)
}

/// One frame's render target: a pixel buffer from the adaptor's pool wrapped as a Metal texture.
/// `metalHold` keeps the CVMetalTexture alive until the GPU work that writes `texture` completes —
/// dropping it early un-anchors the IOSurface backing (a CoreVideo requirement).
/// `@unchecked Sendable`: the target crosses from the encode thread to a command buffer's completed
/// handler, but never concurrently — GPU completion happens-after every CPU-side encode touch.
struct SZVideoFrameTarget: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let texture: any MTLTexture
    private let metalHold: CVMetalTexture

    init(pixelBuffer: CVPixelBuffer, texture: any MTLTexture, metalHold: CVMetalTexture) {
        self.pixelBuffer = pixelBuffer
        self.texture = texture
        self.metalHold = metalHold
    }
}

/// AVAssetWriter wrapper for one take file. Not thread-safe — the recorder serializes all access
/// (encodes under the engine lock, appends on its own serial queue).
final class SZVideoWriter {
    struct Settings {
        var width: Int
        var height: Int
        /// Take frame rate (30/60): the h264/hevc encoder's expected source rate + keyframe interval.
        var fps: Int
        var codec: SZVideoCodec
        /// True for live recording (the encoder biases for latency over lookahead compression).
        var realtime: Bool
        /// Add an AAC audio track (the app-sound toggle). The track exists even if no samples ever
        /// arrive (permission denied mid-flow) — players ignore an empty track.
        var sound: Bool = false
    }

    /// A new fragment lands every second, so a crash loses at most that much.
    static let fragmentInterval = CMTime(value: 1, timescale: 1)

    let settings: Settings
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var textureCache: CVMetalTextureCache?

    /// The pool never queues more than this many in-flight buffers — the backpressure valve that
    /// lets `makeFrameTarget` fail fast (frame dropped) instead of the render thread ever waiting.
    private static let maxPooledBuffers = 6

    /// Test hook: the writer's configured fragment interval.
    var movieFragmentInterval: CMTime { writer.movieFragmentInterval }

    init(url: URL, settings: Settings, device: any MTLDevice) throws {
        self.settings = settings
        try? FileManager.default.removeItem(at: url)
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw SZRecordError.writerFailed("\(error)")
        }
        writer.movieFragmentInterval = Self.fragmentInterval

        // BT.709 tagging on the track settings (and per-buffer attachments below) keeps takes from
        // reading washed out as untagged content. The engine renders bgra8Unorm with an sRGB
        // assumption; the sRGB-vs-709 transfer-curve nit ships as the same SDR assumption the rest
        // of the app makes (color pipeline overhaul is deferred).
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: settings.codec.avCodec,
            AVVideoWidthKey: settings.width,
            AVVideoHeightKey: settings.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if settings.codec == .h264 || settings.codec == .hevc {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                // ~8 bits/pixel/frame average — visually lossless territory for generative content.
                AVVideoAverageBitRateKey: settings.width * settings.height * 8,
                AVVideoExpectedSourceFrameRateKey: settings.fps,
                AVVideoMaxKeyFrameIntervalKey: settings.fps,
            ]
        }

        input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = settings.realtime

        if settings.sound {
            // AAC whatever the video codec: portable, and the writer converts SCK's PCM itself.
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            audio.expectsMediaDataInRealTime = settings.realtime
            guard writer.canAdd(audio) else { throw SZRecordError.writerFailed("cannot add audio input") }
            writer.add(audio)
            audioInput = audio
        } else {
            audioInput = nil
        }

        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: settings.width,
                kCVPixelBufferHeightKey as String: settings.height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
        guard writer.canAdd(input) else { throw SZRecordError.writerFailed("cannot add video input") }
        writer.add(input)

        // Start eagerly: the adaptor's pixelBufferPool is nil until startWriting().
        guard writer.startWriting() else {
            throw SZRecordError.writerFailed("startWriting: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        // Wrapped textures must allow shaderWrite: MPSImageBilinearScale (the crop/resize path)
        // writes them as a compute destination; blit-only paths don't care.
        let textureAttributes = [
            kCVMetalTextureUsage as String: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue
        ] as CFDictionary
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, textureAttributes, &textureCache)
        guard textureCache != nil else { throw SZRecordError.writerFailed("CVMetalTextureCache creation failed") }
    }

    /// Dequeue a pool buffer and wrap it as a Metal render target. Non-blocking by construction:
    /// past `maxPooledBuffers` in flight the pool refuses (nil) instead of allocating — the caller
    /// drops the frame. Safe to call under the engine lock.
    func makeFrameTarget() -> SZVideoFrameTarget? {
        guard let pool = adaptor.pixelBufferPool, let textureCache else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: Self.maxPooledBuffers] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }

        // Per-buffer color attachments mirror the track's 709 tagging (both are needed — the
        // encoder reads the buffer's, players read the track's).
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        var metalTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm,
                settings.width, settings.height, 0, &metalTexture) == kCVReturnSuccess,
              let metalTexture, let texture = CVMetalTextureGetTexture(metalTexture) else { return nil }
        return SZVideoFrameTarget(pixelBuffer: pixelBuffer, texture: texture, metalHold: metalTexture)
    }

    /// Whether the input can take another sample right now (the recorder's drop decision).
    var isReadyForMore: Bool { input.isReadyForMoreMediaData }

    @discardableResult
    func append(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool {
        adaptor.append(pixelBuffer, withPresentationTime: time)
    }

    /// Whether the audio input can take another sample right now; false when soundless.
    var isReadyForMoreAudio: Bool { audioInput?.isReadyForMoreMediaData ?? false }

    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        audioInput?.append(sampleBuffer) ?? false
    }

    func finish() async throws {
        input.markAsFinished()
        audioInput?.markAsFinished()
        // the completion-handler form, not the compiler-bridged async finishWriting(): the bridge
        // double-resumes its continuation for a realtime writer (SIGTRAP in continuation resume)
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        if let error = writer.error { throw SZRecordError.writerFailed("\(error)") }
    }

    /// Bounded finalize for synchronous wind-down (quit). On timeout the fragmented file on disk
    /// is still playable up to the last fragment. Returns whether finishWriting completed.
    @discardableResult
    func finishBlocking(timeout: TimeInterval) -> Bool {
        input.markAsFinished()
        audioInput?.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Abandon the file (caller removes it from disk).
    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
    }
}
