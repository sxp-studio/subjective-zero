// system-audio.macos — the "System Audio" library node (NODE_LIBRARY.md). Self-contained
// ScreenCaptureKit: captures what the Mac is playing (the whole output mix, or one running app picked
// on the `source` dropdown) and emits the same fixed 2048-sample mono PCM window as microphone.macos —
// so the downstream chain (audio-fft → audio-onset / audio-bands) is identical. `reuse: copy-as-is`.
//
// The clean way to drive visuals from music: no room reverb, no speaker-to-mic smear, and the user's
// track (a browser, a music app) just keeps playing on the speakers. The runtime pre-grants the
// `screenRecording` permission; macOS applies a first grant only after the app relaunches, so until
// then the node reports what to do and emits the deterministic synthetic sine mix (same tones as the
// mic node) — headless/CI runs stay deterministic the same way.
//
// SCK's start/stop are async while the node ABI is sync: setup() kicks a Task guarded by a generation
// counter (a stale start discards its own stream), update() reads a lock-guarded state, and teardown()
// joins the async stop with a bounded semaphore before the loader dlcloses the dylib. Sample buffers
// land in CaptureSink, which SCK retains itself, so no callback ever runs against freed node memory.
import AppKit
import CoreMedia
import ScreenCaptureKit

private let kFFTWindow = 2048          // samples emitted per frame (matches microphone.macos)
private let kSampleRate: Float = 48_000   // honored: SCStreamConfiguration.sampleRate resamples for us

final class Node: SZNode {
    private enum State { case idle, starting, live, failed }

    private let sink = CaptureSink()
    private let sampleQueue = DispatchQueue(label: "system-audio.samples")
    private var syntheticWindow = [Float]()   // frozen fallback window, built once

    /// stream + lifecycle, all guarded by `lock`: the start Task, update() (render thread) and
    /// setPaused/teardown all touch them.
    private let lock = NSLock()
    private var stream: SCStream?
    private var startTask: Task<Void, Never>?   // in-flight start; teardown joins it before dlclose
    private var state = State.idle
    private var generation = 0         // bumped on every (re)start/stop; a stale start discards itself
    private var paused = false
    private var pendingError: String?

    private var requestedSource = "system"   // last-applied `source` selection value
    private var authorized = false

    /// Dynamic enum options for the `source` port: the whole mix + one entry per regular running app
    /// (label = app name, value = bundle id, stable across relaunches). Re-queried per dropdown open.
    func dynamicOptions(for port: String) -> [SZEnumOption] {
        guard port == "source" else { return [] }
        var options = [SZEnumOption(label: "Everything the Mac plays", value: "system")]
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        for app in apps.sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") }) {
            guard let name = app.localizedName, let bundleID = app.bundleIdentifier else { continue }
            options.append(SZEnumOption(label: name, value: bundleID))
        }
        return options
    }

    func setup(_ ctx: SZSetupContext) {
        // The runtime pre-grants the permission; unauthorized (first grant pre-relaunch, CI) → synthetic
        // fallback plus a message saying what to do. Never prompts here.
        guard CGPreflightScreenCaptureAccess() else {
            setError("System audio needs Screen Recording access. Turn it on in System Settings under Privacy and Security, then relaunch SubjectiveZero. Using a placeholder signal until then.")
            return
        }
        authorized = true
        startStream(source: requestedSource)
    }

    func update(_ ctx: SZFrameContext) {
        lock.lock()
        let error = pendingError
        let live = state == .live
        let isPaused = paused
        lock.unlock()
        if let error { ctx.reportError(error) }

        // live source switching funnels through here, like the mic node's device dropdown.
        let selection = ctx.inputString("source") ?? "system"
        if selection != requestedSource {
            requestedSource = selection
            if authorized && !isPaused {
                stopStream()
                startStream(source: selection)
            }
        }

        var frame = live ? sink.ring.latest(kFFTWindow) : synthesize(kFFTWindow)
        let gain = ctx.inputFloat("gain") ?? 1
        if gain != 1 { for i in frame.indices { frame[i] *= gain } }
        ctx.setOutputFloats("samples", frame)
    }

    /// A paused graph must not keep pulling the system mix. SCStream has no pause and restarting a
    /// stopped instance is unreliable, so pause mutes the sink at once and tears the stream down; resume
    /// rebuilds it from scratch. The unauthorized/synthetic mode stays untouched either way.
    func setPaused(_ paused: Bool) {
        lock.lock()
        let changed = self.paused != paused
        self.paused = paused
        lock.unlock()
        // the host fans redundant resumes to every loader (e.g. on project open); acting on one would
        // start a second stream alongside the live one.
        guard changed, authorized else { return }
        sink.setMuted(paused)
        if paused {
            stopStream()
        } else {
            startStream(source: requestedSource)
        }
    }

    /// Sync, pre-dlclose: joins the async stop with a bounded wait. SCK's own internal queues can't be
    /// joined from here — the reason CaptureSink (which SCK retains) owns everything a late callback
    /// touches, so nothing points back into this instance.
    func teardown() {
        lock.lock()
        generation += 1
        let s = stream
        let starting = startTask
        stream = nil
        startTask = nil
        state = .idle
        lock.unlock()
        sink.setMuted(true)
        guard s != nil || starting != nil else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            // join a mid-flight start first: the generation bump above makes it discard (and stop)
            // whatever stream it was creating, and its code must not outlive the dylib.
            await starting?.value
            if let s { try? await s.stopCapture() }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    // MARK: stream lifecycle

    private func startStream(source: String) {
        lock.lock()
        generation += 1
        let gen = generation
        state = .starting
        // stored under the same lock so teardown can never miss (and fail to join) a spawned start.
        startTask = Task { [weak self] in
            do {
                let content = try await SCShareableContent.current
                guard let display = content.displays.first else {
                    self?.fail(gen, "System audio found no display to capture from.")
                    return
                }
                let filter: SCContentFilter
                var notice: String?
                if source == "system" {
                    filter = SCContentFilter(display: display, excludingWindows: [])
                } else if let app = content.applications.first(where: { $0.bundleIdentifier == source }) {
                    filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
                } else {
                    // the picked app quit (or was picked on another machine) → whole mix, and say so.
                    filter = SCContentFilter(display: display, excludingWindows: [])
                    notice = "The app picked under Source is not running. Capturing everything the Mac plays instead."
                }
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.excludesCurrentProcessAudio = true   // never feed our own output back in
                configuration.sampleRate = Int(kSampleRate)
                configuration.channelCount = 2
                // SCK requires a video leg; dial it to nothing (2x2 at 1 fps, no .screen output added).
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                guard let self else { return }
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addStreamOutput(self.sink, type: .audio, sampleHandlerQueue: self.sampleQueue)
                try await stream.startCapture()
                if !self.publishStarted(gen, stream, notice: notice) {
                    try? await stream.stopCapture()   // a restart overtook this start; discard ours
                }
            } catch {
                self?.fail(gen, "System audio could not start capturing: \(error.localizedDescription)")
            }
        }
        lock.unlock()
    }

    private func stopStream() {
        lock.lock()
        generation += 1
        let s = stream
        stream = nil
        state = .idle
        lock.unlock()
        guard let s else { return }
        Task.detached { try? await s.stopCapture() }
    }

    /// Adopt a freshly started stream if this start is still the current one (sync so the lock never
    /// sits in an async context). false = a restart overtook it and the caller must discard the stream.
    private func publishStarted(_ gen: Int, _ started: SCStream, notice: String?) -> Bool {
        lock.lock()
        guard generation == gen else { lock.unlock(); return false }
        let replaced = stream   // paranoia: never orphan a live capture, whatever the call order was
        stream = started
        state = .live
        pendingError = notice   // nil clears any earlier failure
        lock.unlock()
        if let replaced { Task.detached { try? await replaced.stopCapture() } }
        return true
    }

    private func fail(_ gen: Int, _ message: String) {
        lock.lock()
        if generation == gen { state = .failed; pendingError = message }
        lock.unlock()
    }

    private func setError(_ message: String) {
        lock.lock()
        pendingError = message
        lock.unlock()
    }

    /// Deterministic fallback signal (same tones as microphone.macos) so headless / unauthorized runs
    /// still drive a visible spectrum. Frozen — the identical window every frame — because a moving
    /// phase makes low-bin FFT magnitudes wobble, which an onset detector reads as endless hits.
    private func synthesize(_ n: Int) -> [Float] {
        if syntheticWindow.count != n {
            let tones: [(hz: Float, amp: Float)] = [(80, 0.6), (220, 0.3), (880, 0.15), (3500, 0.08), (8000, 0.04)]
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Float(i) / kSampleRate
                var s: Float = 0
                for tone in tones { s += tone.amp * sinf(2 * .pi * tone.hz * t) }
                out[i] = s
            }
            syntheticWindow = out
        }
        return syntheticWindow
    }
}

/// Receives SCK audio buffers and keeps the ring. SCK retains this object itself, so a callback that
/// fires during teardown touches only the sink — never the (possibly dlclosing) node.
private final class CaptureSink: NSObject, SCStreamOutput {
    let ring = SampleRing(capacity: kFFTWindow * 2)
    private let lock = NSLock()
    private var muted = false

    func setMuted(_ muted: Bool) {
        lock.lock()
        self.muted = muted
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        lock.lock()
        let skip = muted
        lock.unlock()
        if skip { return }
        guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }

        let frames = sampleBuffer.numSamples
        var mono = [Float](repeating: 0, count: frames)
        // SCK delivers Float32; non-interleaved (one buffer per channel) is the norm, interleaved is
        // handled defensively. downmix = average across channels. this queue is a normal dispatch
        // queue (not a realtime audio thread), so the small scratch allocation is fine.
        try? sampleBuffer.withAudioBufferList { list, _ in
            let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            if interleaved, let base = list[0].mData?.assumingMemoryBound(to: Float.self) {
                let channels = max(1, Int(asbd.mChannelsPerFrame))
                for i in 0..<frames {
                    var s: Float = 0
                    for c in 0..<channels { s += base[i * channels + c] }
                    mono[i] = s / Float(channels)
                }
            } else {
                var channels = 0
                for buffer in list {
                    guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let n = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                    for i in 0..<n { mono[i] += base[i] }
                    channels += 1
                }
                if channels > 1 {
                    let scale = 1 / Float(channels)
                    for i in 0..<frames { mono[i] *= scale }
                }
            }
        }
        mono.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            ring.write(base, frames)
        }
    }
}

/// SPSC ring of `Float`, same shape as microphone.macos: the capture queue bulk-writes, the render
/// thread snapshots the most recent N samples each frame.
final class SampleRing {
    private let lock = NSLock()
    private var buffer: [Float]
    private var writeIndex = 0

    init(capacity: Int) { buffer = [Float](repeating: 0, count: max(1, capacity)) }

    func write(_ samples: UnsafePointer<Float>, _ count: Int) {
        lock.lock(); defer { lock.unlock() }
        let cap = buffer.count
        for i in 0..<count {
            buffer[writeIndex] = samples[i]
            writeIndex = (writeIndex + 1) % cap
        }
    }

    /// The most recent `n` samples in chronological order (zero-padded before enough have arrived).
    func latest(_ n: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let cap = buffer.count
        let count = min(n, cap)
        var out = [Float](repeating: 0, count: n)
        let start = ((writeIndex - count) % cap + cap) % cap
        for i in 0..<count { out[n - count + i] = buffer[(start + i) % cap] }
        return out
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
