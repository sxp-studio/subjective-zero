// SPDX-License-Identifier: AGPL-3.0-only
// The live-record tap. Two feeds, one frame policy: the Metal runtime calls `encodeCapture` under the
// engine lock on the frame's own command buffer (a non-blocking pool dequeue, a crop blit or MPS
// crop-scale, a completed-handler registration; appends happen on `queue` after the GPU signals, so
// the render thread never waits on the encoder), and the web page's frames arrive as CPU bytes through
// `appendFrame`, copied into a pool buffer on `queue`. PTS is the engine's frame time either way, so a
// paused span is simply absent from the file and playback is seamless (the OBS / TouchDesigner behavior).
import AVFoundation
import Metal
import MetalPerformanceShaders
import QuartzCore
import SZCore
import Synchronization

/// `@unchecked Sendable`: the time/pts fields are touched by one feed per take, serialized by its
/// caller (the engine lock for `encodeCapture`, `queue` for `appendFrame`); counters and writer only
/// on `queue` — except finish/cancel, which the owner calls only after the feed stopped (no more
/// encodes) and which drain `queue` first.
public final class SZLiveVideoRecorder: @unchecked Sendable {
    public let url: URL
    public let codec: SZRecordFraming.Codec
    /// Which audio the take carries (off / app / system) — fixed at start like the crop.
    let soundSource: SZRecordFraming.SoundSource
    private let writer: SZVideoWriter
    private let scaler: MPSImageBilinearScale
    private let queue = DispatchQueue(label: "SZLiveVideoRecorder.append")
    /// Picture-normalized crop, fixed for the take; pixel rects derive from each frame's own
    /// endpoint dimensions, so a mid-take resize distorts rather than kills the take.
    private let crop: SZRect
    /// Seconds per output frame (1/fps) — the decimation step for the 30 fps setting.
    private let frameStep: Double

    // Engine-lock-confined timing state.
    /// Last engine time seen (kept or not) — an exact repeat is a frozen duplicate and drops.
    private var lastSeenTime: Double?
    /// Engine time of the last kept frame — decimation + delta base.
    private var lastKeptTime: Double?
    /// Presentation time of the last kept frame; grows by engine-time deltas (one `frameStep` on a
    /// clock reset mid-take, so the take keeps rolling instead of stalling).
    private var filePTS: Double = 0

    /// Captures whose command buffer hasn't completed yet, and CPU bodies not yet copied — finish
    /// waits for zero so a straggler can never append to an already-finished writer.
    private let inFlight = Atomic<Int>(0)
    /// CPU bodies waiting on `queue`; past `maxPendingBodies` a frame drops instead of queueing memory.
    private let pendingBodies = Atomic<Int>(0)
    private static let maxPendingBodies = 3
    // Queue-confined state.
    private var framesAppended = 0
    private var framesDropped = 0
    private var accepting = true
    // Queue-confined audio state: the sound capture (owned so wind-down can stop it), the wall
    // time of the first video frame (the shared t0), and the paused spans spliced out (audio
    // follows the video's pause-edited timeline; both clocks advance at 1x while playing).
    private var audioCapture: SZAppAudioCapture?
    private var audioStart: Double?
    private var audioPausedAccum: Double = 0
    private var audioPauseBegan: Double?

    public init(url: URL, settings: SZRecordSettings, device: any MTLDevice) throws {
        self.url = url
        self.codec = settings.codec
        self.soundSource = settings.sound
        self.crop = settings.crop
        self.frameStep = 1.0 / Double(max(settings.fps, 1))
        self.writer = try SZVideoWriter(
            url: url,
            settings: .init(width: settings.width, height: settings.height, fps: settings.fps,
                            codec: settings.codec, realtime: true, sound: settings.sound != .off),
            device: device)
        self.scaler = MPSImageBilinearScale(device: device)
    }

    /// Capture one frame: encode the crop copy/scale of `endpoint` onto the frame's own command
    /// buffer, stamp the engine frame time as PTS, and hand the buffer to the append queue on GPU
    /// completion. Called under the engine lock, immediately before the schedule buffer's commit.
    func encodeCapture(on commandBuffer: any MTLCommandBuffer, endpoint: any MTLTexture,
                       engineTime: Double) {
        guard let pts = admit(engineTime: engineTime) else { return }

        // Crop in this frame's endpoint pixels, clamped to its bounds.
        let cropX = min(max(Int((crop.x * Double(endpoint.width)).rounded()), 0), endpoint.width - 1)
        let cropY = min(max(Int((crop.y * Double(endpoint.height)).rounded()), 0), endpoint.height - 1)
        let cropW = min(max(Int((crop.width * Double(endpoint.width)).rounded()), 1), endpoint.width - cropX)
        let cropH = min(max(Int((crop.height * Double(endpoint.height)).rounded()), 1), endpoint.height - cropY)

        guard let target = writer.makeFrameTarget() else {
            queue.async { self.framesDropped += 1 }
            return
        }
        let time = keep(engineTime: engineTime, pts: pts)

        if cropW == target.texture.width && cropH == target.texture.height {
            SZRuntime.encodeCopy(endpoint, into: target.texture, width: cropW, height: cropH,
                                 sourceOrigin: MTLOrigin(x: cropX, y: cropY, z: 0), on: commandBuffer)
        } else {
            // Scale the crop region into the fixed output frame. Translation is relative to the
            // clip origin, and the default clip is the whole destination, so the negative offset
            // maps the crop's corner onto (0,0) (see encodeAspectFitScale's clipRect note).
            let scaleX = Double(target.texture.width) / Double(cropW)
            let scaleY = Double(target.texture.height) / Double(cropH)
            var transform = MPSScaleTransform(
                scaleX: scaleX, scaleY: scaleY,
                translateX: -Double(cropX) * scaleX, translateY: -Double(cropY) * scaleY)
            withUnsafePointer(to: &transform) { pointer in
                scaler.scaleTransform = pointer
                scaler.encode(commandBuffer: commandBuffer, sourceTexture: endpoint,
                              destinationTexture: target.texture)
            }
        }

        // `target` rides in the closure, keeping the pixel buffer + CVMetalTexture alive through
        // GPU completion. Completion handlers fire in commit order and the queue is serial, so
        // appended PTS stay monotonic.
        inFlight.wrappingAdd(1, ordering: .sequentiallyConsistent)
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                defer { self.inFlight.wrappingSubtract(1, ordering: .sequentiallyConsistent) }
                guard self.accepting, self.writer.isReadyForMore,
                      self.writer.append(target.pixelBuffer, at: time) else {
                    self.framesDropped += 1
                    return
                }
                self.framesAppended += 1
            }
        }
    }

    // MARK: - The frame policy (both feeds)

    /// Whether this engine frame goes in, and at what PTS: nil for a frozen duplicate (renderFrame
    /// while paused) or a decimated frame (a 30 fps take on a 60 Hz engine); a clock reset mid-take
    /// keeps rolling one step on. Marks the frame seen; `keep` commits it once a buffer is in hand.
    private func admit(engineTime: Double) -> Double? {
        if engineTime == lastSeenTime { return nil }
        lastSeenTime = engineTime
        guard let lastKept = lastKeptTime else { return 0 }
        let delta = engineTime - lastKept
        if delta <= 0 { return filePTS + frameStep }
        if delta < frameStep * 0.75 { return nil }
        return filePTS + delta
    }

    /// Commit an admitted frame: the timing base moves, and the first frame anchors the audio
    /// timeline (same host-time clock as SCK PTS). Returns the PTS to stamp.
    private func keep(engineTime: Double, pts: Double) -> CMTime {
        if lastKeptTime == nil {
            let wall = CACurrentMediaTime()
            queue.async { self.audioStart = self.audioStart ?? wall }
        }
        lastKeptTime = engineTime
        filePTS = pts
        return CMTime(seconds: pts, preferredTimescale: 60000)
    }

    // MARK: - The CPU feed

    /// One frame as bytes: `width * height * 4` BGRA, rows top-down, tightly packed, at the take's
    /// output size (the page crops and scales before it reads back). Cheap on the caller's thread;
    /// the copy into a pool buffer, the frame policy and the append run on `queue`. Past
    /// `maxPendingBodies` waiting, or at the wrong size, the frame is a counted drop.
    public func appendFrame(bgra: Data, width: Int, height: Int, engineTime: Double) {
        guard width == writer.settings.width, height == writer.settings.height,
              bgra.count == width * height * 4 else {
            queue.async { self.framesDropped += 1 }
            return
        }
        if pendingBodies.wrappingAdd(1, ordering: .sequentiallyConsistent).oldValue >= Self.maxPendingBodies {
            pendingBodies.wrappingSubtract(1, ordering: .sequentiallyConsistent)
            queue.async { self.framesDropped += 1 }
            return
        }
        inFlight.wrappingAdd(1, ordering: .sequentiallyConsistent)
        queue.async {
            defer {
                self.pendingBodies.wrappingSubtract(1, ordering: .sequentiallyConsistent)
                self.inFlight.wrappingSubtract(1, ordering: .sequentiallyConsistent)
            }
            guard self.accepting else { self.framesDropped += 1; return }
            guard let pts = self.admit(engineTime: engineTime) else { return }   // duplicate or decimated, not a drop
            guard self.writer.isReadyForMore, let buffer = self.writer.makePixelBuffer() else {
                self.framesDropped += 1
                return
            }
            let time = self.keep(engineTime: engineTime, pts: pts)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = width * 4
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                bgra.withUnsafeBytes { raw in
                    guard let src = raw.baseAddress else { return }
                    if stride == rowBytes {
                        memcpy(base, src, rowBytes * height)
                    } else {
                        for row in 0..<height { memcpy(base + row * stride, src + row * rowBytes, rowBytes) }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard self.writer.append(buffer, at: time) else { self.framesDropped += 1; return }
            self.framesAppended += 1
        }
    }

    // MARK: - Sound

    /// Start the app-audio capture feeding this take. Throws without the Screen Recording
    /// permission; the take then stays video-only. Called once, right after the tap installs.
    /// Registered before the (slow) start so a stop racing the attach still finds the stream, and
    /// re-checked after so a take stopped mid-attach never leaks a running capture.
    public func startAudioCapture() async throws {
        let capture = SZAppAudioCapture(source: soundSource) { [weak self] buffer in
            self?.appendAudio(buffer)
        }
        let proceed = await withCheckedContinuation { continuation in
            queue.async {
                if self.accepting { self.audioCapture = capture }
                continuation.resume(returning: self.accepting)
            }
        }
        guard proceed else { return }
        do {
            try await capture.start()
        } catch {
            queue.async { if self.audioCapture === capture { self.audioCapture = nil } }
            throw error
        }
        let stillWanted = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.audioCapture === capture) }
        }
        if !stillWanted { await capture.stop() }
    }

    /// Pause/resume the audio leg with the clock: paused buffers drop, and the paused wall span is
    /// spliced out of the PTS, mirroring the video's pause-edited timeline.
    public func setPaused(_ paused: Bool, now: Double) {
        queue.async {
            if paused {
                self.audioPauseBegan = self.audioPauseBegan ?? now
            } else if let began = self.audioPauseBegan {
                self.audioPausedAccum += now - began
                self.audioPauseBegan = nil
            }
        }
    }

    private func appendAudio(_ buffer: CMSampleBuffer) {
        queue.async {
            guard self.accepting, self.audioPauseBegan == nil, self.writer.isReadyForMoreAudio else { return }
            // the base is the first video frame's wall time (set by encodeCapture), so sound sits
            // on the same timeline as the picture instead of leading it by the attach latency;
            // audio arriving before any video drops
            guard let start = self.audioStart else { return }
            let pts = buffer.presentationTimeStamp.seconds
            let adjusted = pts - start - self.audioPausedAccum
            guard adjusted >= 0 else { return }
            let timing = CMSampleTimingInfo(
                duration: buffer.duration,
                presentationTimeStamp: CMTime(seconds: adjusted, preferredTimescale: 60000),
                decodeTimeStamp: .invalid)
            guard let retimed = try? CMSampleBuffer(copying: buffer, withNewTiming: [timing]) else { return }
            self.writer.appendAudio(retimed)
        }
    }

    /// Stop the sound capture (idempotent; nil when soundless or permission was denied).
    public func stopAudioCapture() async {
        let capture = await withCheckedContinuation { continuation in
            queue.async {
                defer { self.audioCapture = nil }
                continuation.resume(returning: self.audioCapture)
            }
        }
        await capture?.stop()
    }

    /// Wait out in-flight captures, drain pending appends, then finalize the file. Call only after
    /// the recorder has left the engine (no further `encodeCapture`).
    public func finish() async throws -> (url: URL, frames: Int, dropped: Int, duration: Double) {
        while inFlight.load(ordering: .sequentiallyConsistent) > 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let (frames, dropped) = await withCheckedContinuation { continuation in
            queue.async {
                self.accepting = false
                continuation.resume(returning: (self.framesAppended, self.framesDropped))
            }
        }
        try await writer.finish()
        return (url, frames, dropped, filePTS + frameStep)
    }

    /// Bounded synchronous finalize — the quit path. On timeout the fragmented file on disk is
    /// still playable up to the last fragment. Same removal precondition as `finish`.
    @discardableResult
    public func finishBlocking(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while inFlight.load(ordering: .sequentiallyConsistent) > 0, Date() < deadline {
            usleep(5000)
        }
        queue.sync { accepting = false }
        return writer.finishBlocking(timeout: max(deadline.timeIntervalSinceNow, 0.1))
    }

    /// Abandon the take (caller removes the file). Safe against in-flight captures: `accepting`
    /// flips first, so straggling completed-handlers drop instead of appending to a cancelled writer.
    public func cancel() {
        queue.sync {
            accepting = false
            writer.cancel()
        }
    }

    // MARK: - The take's end (both backends)

    /// Stop the take: sound off, finish the file, rewrap h264/hevc to .mp4 (passthrough, no
    /// re-encode; a failed rewrap keeps the playable .mov). Call only once the feed stopped.
    public func stop() async throws -> (url: URL, frames: Int, dropped: Int, duration: Double) {
        await stopAudioCapture()
        let result = try await finish()
        guard codec.finalFileExtension == "mp4" else { return result }
        let mp4URL = result.url.deletingPathExtension().appendingPathExtension("mp4")
        do {
            try await Self.rewrap(result.url, to: mp4URL)
            try? FileManager.default.removeItem(at: result.url)
            return (mp4URL, result.frames, result.dropped, result.duration)
        } catch {
            try? FileManager.default.removeItem(at: mp4URL)
            return result
        }
    }

    /// Bounded synchronous stop, the quit path (applicationWillTerminate cannot await). Finishes the
    /// .mov, then rewraps only inside the remaining budget; on timeout the playable .mov stays.
    public func stopBlocking(timeout: TimeInterval) -> URL {
        let deadline = Date(timeIntervalSinceNow: timeout)
        Task.detached { await self.stopAudioCapture() }   // best-effort; appends already stopped
        finishBlocking(timeout: timeout)
        guard codec.finalFileExtension == "mp4" else { return url }
        let movURL = url
        let mp4URL = movURL.deletingPathExtension().appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: mp4URL)
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: movURL),
                                                 presetName: AVAssetExportPresetPassthrough) else {
            return movURL
        }
        // the session is only touched by the export call and, after the timeout below, cancel —
        // AVAssetExportSession is documented thread-safe for exactly that pair
        let boxed = SZUncheckedSendableBox(session)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            try? await boxed.value.export(to: mp4URL, as: .mp4)
            done.signal()
        }
        if done.wait(timeout: .now() + max(deadline.timeIntervalSinceNow, 0.1)) == .success,
           FileManager.default.fileExists(atPath: mp4URL.path) {
            try? FileManager.default.removeItem(at: movURL)
            return mp4URL
        }
        session.cancelExport()
        _ = done.wait(timeout: .now() + 1)
        try? FileManager.default.removeItem(at: mp4URL)
        return movURL
    }

    /// Abandon the take and delete its file.
    public func cancelAndDelete() {
        Task.detached { await self.stopAudioCapture() }
        cancel()
        try? FileManager.default.removeItem(at: url)
    }

    /// Passthrough container rewrap (.mov → .mp4): same samples, portable file.
    private static func rewrap(_ source: URL, to destination: URL) async throws {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source),
                                                 presetName: AVAssetExportPresetPassthrough) else {
            throw SZRecordError.writerFailed("passthrough export unavailable")
        }
        try? FileManager.default.removeItem(at: destination)
        try await session.export(to: destination, as: .mp4)
    }
}

/// Carries one value into a sendable closure the compiler cannot check (see use site).
private struct SZUncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
