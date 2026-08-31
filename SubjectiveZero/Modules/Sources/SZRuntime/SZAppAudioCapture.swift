// SPDX-License-Identifier: AGPL-3.0-only
// The take's audio leg: an audio-only ScreenCaptureKit stream, filtered to this process (App) or
// to the whole display's output (System) — video nodes play device-direct, so SCK is the only
// place the program mix exists. Needs the Screen Recording permission — start() throws without it
// and the take stays video-only.
import CoreMedia
import ScreenCaptureKit
import SZCore

/// `@unchecked Sendable`: `stream` is written by start/stop only; samples arrive on the capture
/// queue and go straight to the recorder, which does its own serialization.
final class SZAppAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "SZAppAudioCapture.samples")
    private let source: SZRecordFraming.SoundSource
    private let onSample: (CMSampleBuffer) -> Void
    private var stream: SCStream?

    init(source: SZRecordFraming.SoundSource, onSample: @escaping (CMSampleBuffer) -> Void) {
        self.source = source
        self.onSample = onSample
    }

    func start() async throws {
        // `current` throws when Screen Recording permission is missing (and triggers the system
        // prompt on first ask) — the caller surfaces that and records without sound.
        let content = try await SCShareableContent.current
        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let display = content.displays.first else {
            throw SZRecordError.writerFailed("no capturable display for sound")
        }
        let filter: SCContentFilter
        if source == .app {
            guard let app = content.applications.first(where: { $0.processID == pid }) else {
                throw SZRecordError.writerFailed("this app is not capturable for sound")
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        } else {
            // system: everything the Mac is playing, this app included
            filter = SCContentFilter(display: display, excludingWindows: [])
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        // the stream's mandatory video leg, dialed to nothing (no .screen output is attached)
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        onSample(sampleBuffer)
    }
}
