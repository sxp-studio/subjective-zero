// SPDX-License-Identifier: AGPL-3.0-only
// Live recording, the runtime API half: start/stop/cancel one take. The tap itself rides
// encodeAndCommitFrame (SZLiveVideoRecorder); exactly one recorder exists at a time. Takes record
// as fragmented .mov; h264/hevc rewrap to .mp4 on stop (passthrough, no re-encode) — a failed or
// out-of-budget rewrap keeps the playable .mov instead of failing the stop.
import AVFoundation
import Foundation
import SZCore

/// Settings for one take, fixed at start.
public struct SZRecordSettings: Sendable {
    /// Output file dimensions.
    public var width: Int
    public var height: Int
    /// Output frame rate (30/60); engine frames beyond it are decimated.
    public var fps: Int
    public var codec: SZVideoCodec
    /// Picture-normalized crop of the full frame.
    public var crop: SZRect
    /// Full-frame render size while the take rolls (output size / crop fraction, capped) —
    /// overrides the driver drawable size.
    public var renderSize: (width: Int, height: Int)
    /// Sound source (off / app / system). The audio track exists for any non-off source; the
    /// capture attaches separately via `startRecordingSound`, so a denied permission degrades to
    /// video-only.
    public var sound: SZRecordFraming.SoundSource

    public init(width: Int, height: Int, fps: Int, codec: SZVideoCodec,
                crop: SZRect = .unit, renderSize: (width: Int, height: Int),
                sound: SZRecordFraming.SoundSource = .off) {
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.crop = crop
        self.renderSize = renderSize
        self.sound = sound
    }
}

/// Carries one value into a sendable closure the compiler cannot check (see use site).
private struct SZUncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

public extension SZRuntime {
    /// Start a take to `url` (a .mov path — see the header). Throws `.alreadyRecording`,
    /// `.nothingToRender`, or `.writerFailed`.
    func startRecording(to url: URL, settings: SZRecordSettings) throws {
        guard !isRecording else { throw SZRecordError.alreadyRecording }
        let recorder = try SZLiveVideoRecorder(url: url, settings: settings, device: device)
        do {
            try installRecorder(recorder, renderSize: settings.renderSize)
        } catch {
            recorder.cancel()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Attach the app-sound capture to the rolling take. Separate from `startRecording` because
    /// ScreenCaptureKit's permission check is async — a throw here (no Screen Recording
    /// permission) leaves the take rolling video-only.
    func startRecordingSound() async throws {
        guard let recorder = currentRecorder else { throw SZRecordError.notRecording }
        try await recorder.startAudioCapture()
    }

    /// Stop and finalize the take: drain the tap, finish the writer, rewrap h264/hevc to .mp4.
    func stopRecording() async throws -> (url: URL, frames: Int, dropped: Int, duration: Double) {
        guard let recorder = removeRecorder() else { throw SZRecordError.notRecording }
        await recorder.stopAudioCapture()
        let result = try await recorder.finish()
        guard recorder.codec.finalFileExtension == "mp4" else { return result }
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

    /// Bounded synchronous finalize — the quit path (applicationWillTerminate cannot await).
    /// Finishes the .mov, then rewraps only inside the remaining budget; on timeout the playable
    /// .mov stays. Returns the finished file's URL, nil when no take was rolling.
    @discardableResult
    func stopRecordingBlocking(timeout: TimeInterval) -> URL? {
        guard let recorder = removeRecorder() else { return nil }
        let deadline = Date(timeIntervalSinceNow: timeout)
        Task.detached { await recorder.stopAudioCapture() }   // best-effort; appends already stopped
        recorder.finishBlocking(timeout: timeout)
        guard recorder.codec.finalFileExtension == "mp4" else { return recorder.url }
        let movURL = recorder.url
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
        done.wait(timeout: .now() + 1)
        try? FileManager.default.removeItem(at: mp4URL)
        return movURL
    }

    /// Abandon the rolling take and delete its file. No-op when idle.
    func cancelRecording() {
        guard let recorder = removeRecorder() else { return }
        Task.detached { await recorder.stopAudioCapture() }
        recorder.cancel()
        try? FileManager.default.removeItem(at: recorder.url)
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
