// SPDX-License-Identifier: AGPL-3.0-only
// Live recording, the Metal runtime's half of `SZRenderBackend`: start/stop/cancel one take. The tap
// itself rides encodeAndCommitFrame (SZLiveVideoRecorder); exactly one recorder exists at a time, and
// the take's end (finish, rewrap, delete) is the recorder's, shared with the web backend.
import Foundation
import SZCore

public extension SZRuntime {
    /// Start a take to `url` (a .mov path — see SZLiveVideoRecorder). Throws `.alreadyRecording`,
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

    /// Stop and finalize the take: remove the tap, drain it, finish the writer, rewrap to .mp4.
    func stopRecording() async throws -> (url: URL, frames: Int, dropped: Int, duration: Double) {
        guard let recorder = removeRecorder() else { throw SZRecordError.notRecording }
        return try await recorder.stop()
    }

    /// Bounded synchronous finalize — the quit path. Returns the finished file's URL, nil when no
    /// take was rolling.
    @discardableResult
    func stopRecordingBlocking(timeout: TimeInterval) -> URL? {
        removeRecorder()?.stopBlocking(timeout: timeout)
    }

    /// Abandon the rolling take and delete its file. No-op when idle.
    func cancelRecording() {
        removeRecorder()?.cancelAndDelete()
    }
}
