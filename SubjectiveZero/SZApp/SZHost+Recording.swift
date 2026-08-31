// SPDX-License-Identifier: AGPL-3.0-only
// Recording, the host half: the HUD record dot's toggle, take placement in the project bundle
// (`recordings/`), and the elapsed readout. The engine work is SZRuntime.startRecording/
// stopRecording; wind-down hooks for project switch / Save As / quit live with the lifecycle
// code that calls them.
import AppKit
import AVFoundation
import Foundation
import SZCore
import SZRuntime

/// One finished take's toast (bottom-right of the workspace, auto-dismissing).
struct SZTakeToast: Equatable {
    let title: String
    let subtitle: String
    let url: URL
    var thumbnail: NSImage?
}

extension SZHost {
    /// The HUD record dot: one press starts a take with the saved settings, one press stops it.
    /// A press while the previous take is still finalizing waits it out rather than failing.
    func toggleRecording() {
        if isRecording {
            stopTake()
        } else if runtime?.isRecording == true {
            status = "still saving the last take"
        } else {
            startTake()
        }
    }

    private func startTake() {
        guard let runtime, let projectURL = loadedProjectURL else { return }
        // an open framing editor commits its crop and closes; the options sheet closes with it
        if framingEditorViewport != nil { closeFramingEditor() }
        recordSettingsPresented = false
        do {
            try FileManager.default.createDirectory(
                at: projectURL.appending(path: SZProjectMedia.recordingsDirectoryName),
                withIntermediateDirectories: true)
            let take = SZProjectMedia.nextRecording(in: projectURL, fileExtension: "mov")
            let settings = currentRecordSettings()
            try runtime.startRecording(to: take.url, settings: settings)
            currentTakeNumber = take.number
            isRecording = true
            startElapsedTicker()
            status = "Recording \(take.number)…"
            if settings.sound != .off {
                // async by nature (the permission check); a refusal leaves the take rolling
                // video-only and explains itself once. A take already stopped by the time the
                // attach fails is not a permission problem — no alert then.
                Task { [weak self] in
                    do {
                        try await runtime.startRecordingSound()
                    } catch {
                        if self?.isRecording == true { self?.presentSoundPermissionAlert() }
                    }
                }
            }
        } catch {
            status = "record failed: \(error)"
        }
    }

    /// The one flow macOS forces on audio capture: it counts as screen recording, and the grant
    /// only applies after a relaunch. Shown at source selection and again if a record press still
    /// finds no permission; never blocks a rolling recording.
    private func presentSoundPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Recording sound needs Screen Recording permission"
        alert.informativeText = "macOS treats capturing audio as screen recording. "
            + "Allow SubjectiveZero under Privacy & Security, then relaunch the app. "
            + "Until then, recordings capture no sound."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func stopTake() {
        guard let runtime else { return }
        isRecording = false
        recordingTicker?.cancel()
        recordingTicker = nil
        let number = currentTakeNumber
        let fps = recordFPS
        let projectURL = loadedProjectURL
        Task { [weak self] in
            let result: (url: URL, frames: Int, dropped: Int, duration: Double)
            do {
                result = try await runtime.stopRecording()
            } catch {
                self?.status = "recording failed: \(error)"
                self?.recordingElapsed = nil
                return
            }
            // the project may have moved on while the finalize ran; its toast and Reveal target
            // belong to the bundle the take was recorded into, not whatever is open now
            guard let self, self.loadedProjectURL == projectURL else { return }
            self.lastTakeURL = result.url
            self.status = "saved \(result.url.lastPathComponent)"
            self.recordingElapsed = nil
            await self.presentTakeToast(for: result, number: number, fps: fps)
        }
    }

    // MARK: - Wind-down (project switch, Save As, quit, discard)

    /// Finalize a rolling take synchronously, bounded — called before the bundle is copied,
    /// retired, or the process exits. No toast: the moment has nothing to show it on.
    /// The runtime is the truth here, not the host mirror: a just-pressed stop clears `isRecording`
    /// while its finalize still sits in a task, and this hook must not skip a live writer.
    func finalizeActiveTakeBlocking() {
        let rolling = runtime?.isRecording ?? false
        guard isRecording || rolling else { return }
        resetRecordingState()
        if rolling, let url = runtime?.stopRecordingBlocking(timeout: 2) {
            lastTakeURL = url
            status = "saved \(url.lastPathComponent)"
        }
    }

    /// Abandon a rolling take with its bundle — the discard-untitled path. Releases the writer's
    /// file before the project's home is deleted. Same runtime-is-the-truth guard as above.
    func cancelActiveTake() {
        let rolling = runtime?.isRecording ?? false
        guard isRecording || rolling else { return }
        resetRecordingState()
        if rolling { runtime?.cancelRecording() }
    }

    private func resetRecordingState() {
        isRecording = false
        recordingTicker?.cancel()
        recordingTicker = nil
        recordingElapsed = nil
    }

    // MARK: - Stop toast

    /// The stop toast: last-frame thumbnail, "Recording N saved", length · dimensions · fps, Reveal.
    private func presentTakeToast(for result: (url: URL, frames: Int, dropped: Int, duration: Double),
                                  number: Int?, fps: Int) async {
        let seconds = Int(result.duration.rounded())
        var parts = [String(format: "%d:%02d", seconds / 60, seconds % 60)]
        let asset = AVURLAsset(url: result.url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize) {
            parts.append("\(Int(size.width)) × \(Int(size.height))")
        }
        parts.append("\(fps) fps")

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        // the end of the take is what the user just saw
        let last = CMTime(seconds: max(result.duration - 0.1, 0), preferredTimescale: 600)
        let cgImage = try? await generator.image(at: last).image

        let title = number.map { "Recording \($0) saved" }
            ?? "\(result.url.deletingPathExtension().lastPathComponent) saved"
        takeToast = SZTakeToast(title: title, subtitle: parts.joined(separator: " · "),
                                url: result.url,
                                thumbnail: cgImage.map { NSImage(cgImage: $0, size: .zero) })
        takeToastDismiss?.cancel()
        takeToastDismiss = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.takeToast = nil
        }
    }

    /// The toast's Reveal button: show the take in Finder and put the toast away.
    func revealTake(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        takeToastDismiss?.cancel()
        takeToast = nil
    }

    /// Project ▸ Show Recordings in Finder — the way back once the toast is gone. Selects the
    /// newest recording so the folder opens with something useful highlighted.
    func revealTakes() {
        guard let projectURL = loadedProjectURL else { return }
        let dir = projectURL.appending(path: SZProjectMedia.recordingsDirectoryName)
        let newest = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
        NSWorkspace.shared.activateFileViewerSelecting([newest ?? dir])
    }

    /// Whether the project holds any takes (the menu item's enabled state).
    var hasTakes: Bool {
        guard let projectURL = loadedProjectURL else { return false }
        let dir = projectURL.appending(path: SZProjectMedia.recordingsDirectoryName)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty == false)
    }

    /// The take settings from the sticky record state.
    private func currentRecordSettings() -> SZRecordSettings {
        let output = recordOutputSize
        let render = SZRecordFraming.renderSize(output: output, crop: recordCrop)
        return SZRecordSettings(width: output.width, height: output.height, fps: recordFPS,
                                codec: SZVideoCodec(rawValue: recordCodec.rawValue) ?? .h264,
                                crop: recordCrop, renderSize: render, sound: recordSoundSource)
    }

    /// The output file dimensions the sticky settings currently yield.
    var recordOutputSize: (width: Int, height: Int) {
        SZRecordFraming.outputSize(ratio: recordRatio, tier: recordTier, crop: recordCrop,
                                   picture: runtime?.renderSize ?? (1280, 800))
    }

    /// The sheet's framing row, in words: ratio, whether a custom crop is set, output dims.
    var recordFramingSummary: String {
        let o = recordOutputSize
        let cropPart = recordCrop == .unit ? "Full frame" : "Custom crop"
        let ratioPart = recordRatio == .free ? "" : "\(recordRatio.label) · "
        return "\(ratioPart)\(cropPart) · \(o.width) × \(o.height)"
    }

    // MARK: - Sticky settings (one writer: persistAppState)

    func setRecordTier(_ tier: SZRecordFraming.Tier) {
        recordTier = tier
        persistAppState()
    }

    func setRecordFPS(_ fps: Int) {
        recordFPS = fps
        persistAppState()
    }

    func setRecordCodec(_ codec: SZRecordFraming.Codec) {
        recordCodec = codec
        persistAppState()
    }

    func setRecordSoundSource(_ source: SZRecordFraming.SoundSource) {
        recordSoundSource = source
        persistAppState()
        // settle the permission at selection time, not at the record press: macOS applies Screen
        // Recording only after a relaunch, so record-time discovery costs a soundless recording
        // AND a restart. First-ever pick fires the system prompt; already-denied gets our alert.
        guard source != .off, !CGPreflightScreenCaptureAccess() else { return }
        if !CGRequestScreenCaptureAccess() {
            presentSoundPermissionAlert()
        }
    }

    /// First-ever press of the record dot opened the settings sheet instead of rolling.
    func markRecordSettingsSeen() {
        recordSettingsSeen = true
        persistAppState()
    }

    // MARK: - Framing editor

    /// Open the framing editor on the largest visible viewport (editing comfort; the crop is global).
    func openFramingEditor() {
        framingEditorViewport = viewportSurfaces
            .max { Self.pixelArea($0.layer.drawableSize) < Self.pixelArea($1.layer.drawableSize) }?
            .id
    }

    func closeFramingEditor() {
        framingEditorViewport = nil
        persistAppState()   // the crop settles here (per-drag persists would thrash the file)
    }

    /// A ratio chip's press: switch the ratio and re-fit the crop to it (free keeps the crop).
    func pickFramingRatio(_ ratio: SZRecordFraming.Ratio) {
        recordRatio = ratio
        if let aspect = ratio.aspect {
            recordCrop = SZRecordFraming.fitted(recordCrop, toAspect: aspect,
                                                picture: runtime?.renderSize ?? (1280, 800))
        }
        persistAppState()
    }

    /// 2 Hz elapsed readout; accumulates only while playback runs, so the counter freezes with the
    /// clock (matching the file, where the paused span does not exist).
    private func startElapsedTicker() {
        recordingTicker?.cancel()
        recordingAccumulated = 0
        recordingLastTick = Date()
        recordingElapsed = "00:00"
        recordingTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isRecording else { break }
                let now = Date()
                if self.runtime?.isPaused != true {
                    self.recordingAccumulated += now.timeIntervalSince(self.recordingLastTick)
                }
                self.recordingLastTick = now
                let s = Int(self.recordingAccumulated)
                self.recordingElapsed = String(format: "%02d:%02d", s / 60, s % 60)
            }
        }
    }
}
