// microphone.macos — the built-in "Microphone" library node (NODE_LIBRARY.md). Self-contained
// AVFoundation: this node owns the whole capture pipeline (AVAudioEngine → input tap → a lock-guarded
// ring buffer). The runtime owns only the *permission* (granted before this node loads); it never sees a
// mic. `reuse: copy-as-is` — agents copy this file into the new node's folder and adapt as needed.
//
// It is the SOURCE of an audio pipeline: it emits a fixed 2048-sample mono PCM window on its `samples`
// output (a `floatArray`), which a downstream FFT / analysis node reads with `ctx.inputFloatArray`. It does
// NOT do any DSP itself — keeping it tiny and single-purpose so the heavy FFT/render work lives in its own
// nodes (each fits one coding turn).
//
// Live inputs: `gain` (input-gain multiplier) and `device` — a DYNAMIC enum (like camera.macos's `camera`)
// that lists the audio input devices (`dynamicOptions`) and live-switches the engine's input via CoreAudio.
// Safe headless: it guards on `AVCaptureDevice.authorizationStatus(for: .audio)` and, when the mic is not
// authorized (CI / no device / denied), emits a deterministic SYNTHETIC sine mix (80/220/880/3500/8000 Hz)
// so the whole pipeline still produces a non-zero spectrum without a real microphone. `teardown()` removes
// the observer + tap and stops the engine BEFORE the loader dlcloses the dylib (the hot-reload hazard).
//
// Sample rate is assumed ~48 kHz. Capture + device-switch logic adapted from the original subjective
// designer's SBMicInputNode / SBAudioManager, inlined and simplified into one node.
@preconcurrency import AVFoundation
import CoreAudio
import AudioToolbox

private let kFFTWindow = 2048          // samples emitted per frame (a power of two FFT window)
private let kSampleRate: Float = 48_000

final class Node: SZNode {
    private let engine = AVAudioEngine()
    private let ring = SampleRing(capacity: kFFTWindow * 2)
    private var running = false        // true once the real engine tap is live; false → synthetic fallback
    private var clock = 0              // running sample index for the synthetic generator

    private var requestedDevice = "default"          // last-applied `device` selection value
    private var activeDeviceID: AudioDeviceID = 0     // CoreAudio id currently feeding the engine
    /// Set by the config-change observer (arbitrary thread) and consumed by update() (the render
    /// thread) — cross-thread, so guarded by `reconfigureFlagLock` (a naked Bool here is a data race
    /// now that update() runs off-main; see the node ABI threading contract).
    private var needsReconfigure = false
    private let reconfigureFlagLock = NSLock()
    private var configObserver: NSObjectProtocol?

    /// Dynamic enum options for the `device` port: "Default" + one entry per audio input device (label =
    /// friendly name, value = stable `uniqueID`). The host re-queries this each time the dropdown opens, so
    /// plug/unplug is picked up automatically.
    func dynamicOptions(for port: String) -> [SZEnumOption] {
        guard port == "device" else { return [] }
        var options = [SZEnumOption(label: "Default", value: "default")]
        for device in Self.inputDevices() {
            options.append(SZEnumOption(label: device.localizedName, value: device.uniqueID))
        }
        return options
    }

    func setup(_ ctx: SZSetupContext) {
        // The runtime pre-grants permission; if it isn't authorized we never touch the engine and fall back
        // to synthetic audio (no prompt here, headless-safe).
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        // A device unplug / default-input change posts this; just flag it (arbitrary thread — never touch the
        // engine here) and reconfigure on the next update() so all engine mutation stays on one thread.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.flagNeedsReconfigure()
        }
        startCapture(deviceID: resolveDeviceID("default"))
    }

    func update(_ ctx: SZFrameContext) {
        // Live device selection: a UI change or a config-change both funnel through `reconfigure()`.
        let selection = ctx.inputString("device") ?? "default"
        if selection != requestedDevice { requestedDevice = selection; flagNeedsReconfigure() }
        reconfigureFlagLock.lock()
        let wantsReconfigure = needsReconfigure
        needsReconfigure = false
        reconfigureFlagLock.unlock()
        if wantsReconfigure { reconfigure() }

        // Emit the latest window every frame: real captured samples once the engine is live, else a
        // synthetic sine mix so the downstream FFT always has signal.
        var frame = running ? ring.latest(kFFTWindow) : synthesize(kFFTWindow)
        let gain = ctx.inputFloat("gain") ?? 1   // live input-gain knob (boost a quiet mic)
        if gain != 1 { for i in frame.indices { frame[i] *= gain } }
        ctx.setOutputFloats("samples", frame)
    }

    func teardown() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)   // no more callbacks scheduled
        // `engine.stop()` is synchronous and tears down AVAudioEngine's internal IO render thread (the one
        // that invokes the tap), so no tap callback can still be running when this returns — nothing left to
        // drain before the loader dlcloses this dylib. (camera.macos needs an explicit `sampleQueue.sync {}`
        // only because it owns the delegate's DispatchQueue, which `stopRunning()` does NOT join.)
        engine.stop()
        running = false
    }

    // MARK: capture + device switching

    private func flagNeedsReconfigure() {
        reconfigureFlagLock.lock()
        needsReconfigure = true
        reconfigureFlagLock.unlock()
    }

    /// Resolve/apply the requested input device, restarting the tap only when it actually changes (so a
    /// spurious config-change is a no-op and there's no per-frame churn / restart loop).
    ///
    /// KNOWN HITCH: `engine.stop()`/`start()` are synchronous and run here, on the render thread —
    /// a real device switch drops a few viewport frames. Deliberate for now (switches are rare user
    /// actions); the contract-clean form is deferring the engine work to the node's own queue and
    /// flipping to the new stream when ready.
    private func reconfigure() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { running = false; return }
        let target = resolveDeviceID(requestedDevice)
        // Same device as the last attempt → no-op, so a self-induced config-change (our own stop/start posts
        // one) and a repeatedly-failing start under a plug/unplug storm don't churn engine.stop()/start() on
        // the render thread. A genuine device change resolves to a different id and does re-attempt.
        if target == activeDeviceID { return }
        if running { engine.inputNode.removeTap(onBus: 0); engine.stop(); running = false }
        startCapture(deviceID: target)
    }

    /// Point the engine's input at `deviceID`, (re)install the mono tap for the (possibly new) format, and
    /// start. On any failure → `running = false` so `update()` falls back to synthetic audio.
    private func startCapture(deviceID: AudioDeviceID) {
        activeDeviceID = deviceID   // record the attempt (success OR fail) so reconfigure() dedups and won't churn
        let input = engine.inputNode
        Self.setInputDevice(input, deviceID)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { running = false; return }   // no input hardware → synthetic fallback
        let ring = self.ring
        // AUDIO THREAD: copy channel 0 (mono) into the ring; no locks beyond the ring's, no allocations.
        input.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData else { return }
            ring.write(channel[0], Int(buffer.frameLength))
        }
        do {
            try engine.start()
            running = true
        } catch {
            input.removeTap(onBus: 0)   // start failed → drop the tap, fall back to synthetic
            running = false
        }
    }

    /// A `device` value (`uniqueID` or "default") → CoreAudio id. Unknown id (e.g. unplugged, or a selection
    /// saved on another machine) falls back to the current system default input.
    private func resolveDeviceID(_ value: String) -> AudioDeviceID {
        if value != "default", let id = Self.deviceID(forUID: value) { return id }
        return Self.defaultInputDeviceID()
    }

    /// Deterministic fallback signal (mix of sines at musical-ish bands) so headless / unauthorized runs
    /// still drive a visible spectrum. Continuous across frames via `clock`.
    private func synthesize(_ n: Int) -> [Float] {
        let tones: [(hz: Float, amp: Float)] = [(80, 0.6), (220, 0.3), (880, 0.15), (3500, 0.08), (8000, 0.04)]
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(clock + i) / kSampleRate
            var s: Float = 0
            for tone in tones { s += tone.amp * sinf(2 * .pi * tone.hz * t) }
            out[i] = s
        }
        clock &+= n
        return out
    }

    // MARK: CoreAudio helpers

    private static func inputDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    private static func defaultInputDeviceID() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return nil
        }
        for id in ids {
            var uidRef: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uidRef) == noErr,
               let ref = uidRef?.takeRetainedValue(), (ref as String) == uid {
                return id
            }
        }
        return nil
    }

    private static func setInputDevice(_ input: AVAudioInputNode, _ deviceID: AudioDeviceID) {
        guard deviceID != 0, let au = input.audioUnit else { return }
        var dev = deviceID
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
    }
}

/// SPSC ring of `Float`: the audio thread bulk-writes tap callbacks; the render thread snapshots the most
/// recent N samples (oldest-first) each frame. `NSLock` is enough — writes are short bulk copies.
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
