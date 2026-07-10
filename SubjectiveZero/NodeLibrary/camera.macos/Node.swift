// camera.macos — the built-in "MacBook Camera" library node (NODE_LIBRARY.md). Self-contained
// AVFoundation: this node owns the whole capture pipeline (AVCaptureSession → CVPixelBuffer →
// CVMetalTextureCache → sample into its output texture). The runtime owns only the *permission* (granted
// before this node loads); it never sees a camera. `reuse: copy-as-is` — agents copy this file into the
// new node's folder and adapt as needed.
//
// Safe headless: it guards on `AVCaptureDevice.authorizationStatus` and outputs black until authorized,
// so it never prompts or crashes without a usage description. `teardown()` stops the session and drains
// the delegate queue BEFORE the loader dlcloses the dylib (the hot-reload hazard).
//
// The frame is drawn with a full-screen triangle + linear sampler so it **aspect-fills** the output
// (scales to cover the viewport, centered crop) regardless of camera vs. drawable resolution — a blit
// can't scale, which left the live frame in a corner of the Retina drawable.
//
// Live inputs: `mirror`/`aspectFit` (v3 floats), plus `camera` (a v4 string). The `camera`
// dropdown is a DYNAMIC enum — `dynamicOptions(for:)` enumerates attached devices at runtime (built-in,
// external/USB, and Continuity Camera) so the host shows them; the chosen value is the device's `uniqueID`
// (or the reserved "default" = let the node pick), so a selection saved on one machine degrades gracefully
// on another, and switches the live session without a reload. Camera capture logic inlined
// into the node.
@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
@preconcurrency import Metal

final class Node: SZNode {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sampleQueue = DispatchQueue(label: "studio.sxp.camera.macos")
    private var delegate: CameraSampleDelegate?
    private var textureCache: CVMetalTextureCache?
    private var pipeline: (any MTLRenderPipelineState)?
    private var running = false
    private var requestedCamera: String?    // last-applied `camera` selection value (raw, for change detection)
    private var activeDeviceID: String?     // uniqueID of the device currently fed into the session

    /// Dynamic enum options for the `camera` port: a reserved machine-independent "Default" plus one entry
    /// per attached device (label = friendly name, value = stable `uniqueID`). The host caches these for
    /// the editor dropdown + snapshot.
    func dynamicOptions(for port: String) -> [SZEnumOption] {
        guard port == "camera" else { return [] }
        var options = [SZEnumOption(label: "Default", value: "default")]
        for device in Self.discovery().devices {
            options.append(SZEnumOption(label: device.localizedName, value: device.uniqueID))
        }
        return options
    }

    func setup(_ ctx: SZSetupContext) {
        buildPipeline(ctx.device)

        // The runtime pre-grants permission; if it isn't authorized we stay dark (no prompt here).
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, ctx.device, nil, &cache)
        guard let cache, let camera = Self.selectCamera() else { return }
        textureCache = cache

        let delegate = CameraSampleDelegate()
        self.delegate = delegate

        session.beginConfiguration()
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        if let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
            session.addInput(input)
            activeDeviceID = camera.uniqueID
        }
        requestedCamera = "default"
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: sampleQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        sampleQueue.async { [session] in session.startRunning() }
        running = true
    }

    func update(_ ctx: SZFrameContext) {
        guard let out = ctx.outputTexture("texture") else { return }

        // Live device selection (v4 string) — reconfigure the session only when it changes.
        applySelection(camera: ctx.inputString("camera") ?? "default")

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }

        guard running, let pipeline, let cache = textureCache, let pixelBuffer = delegate?.latest(),
              let (camera, hold) = Self.texture(from: pixelBuffer, cache: cache) else { return }  // black until a frame arrives
        // Pin this frame's sampled buffer + Metal binding until the frame's GPU work completes —
        // the pool recycles them the moment the last reference drops (torn feed otherwise).
        ctx.holdUntilFrameCompletes(pixelBuffer)
        ctx.holdUntilFrameCompletes(hold)

        // Live scalar inputs (v3 ABI): mirror flips horizontally; aspectFit=true fills the frame
        // edge-to-edge (crop, the default look), false fits the whole image (letterbox bars).
        let mirror = (ctx.inputFloat("mirror") ?? 1) > 0.5
        let fill = (ctx.inputFloat("aspectFit") ?? 1) > 0.5
        let outAspect = Double(out.width) / Double(max(1, out.height))
        let camAspect = Double(camera.width) / Double(max(1, camera.height))
        var scale = SIMD2<Float>(1, 1)
        if fill {
            if camAspect > outAspect { scale.x = Float(outAspect / camAspect) } else { scale.y = Float(camAspect / outAspect) }
        } else {
            if camAspect > outAspect { scale.y = Float(camAspect / outAspect) } else { scale.x = Float(outAspect / camAspect) }
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(camera, index: 0)
        var params = SIMD4<Float>(scale.x, scale.y, mirror ? 1 : 0, 0)   // xy = uv scale, z = mirror flag
        encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    func teardown() {
        guard running else { return }
        session.stopRunning()                          // synchronous: no more deliveries
        output.setSampleBufferDelegate(nil, queue: nil) // no new callbacks
        sampleQueue.sync {}                             // drain any in-flight callback before dlclose
        delegate = nil
        textureCache = nil
        running = false
    }

    private func buildPipeline(_ device: any MTLDevice) {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut v_main(uint vid [[vertex_id]]) {
            float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
            VOut o;
            o.pos = float4(p[vid], 0, 1);
            o.uv = float2(o.pos.x * 0.5 + 0.5, 0.5 - o.pos.y * 0.5);  // texture top-left origin
            return o;
        }
        fragment float4 f_main(VOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               constant float4 &p [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float2 uv = (in.uv - 0.5) * p.xy + 0.5;
            if (p.z > 0.5) { uv.x = 1.0 - uv.x; }                        // mirror
            if (any(uv < 0.0) || any(uv > 1.0)) { return float4(0, 0, 0, 1); }  // letterbox bars (fit)
            return tex.sample(s, uv);
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil) else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "v_main")
        descriptor.fragmentFunction = library.makeFunction(name: "f_main")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Switch the live session's input device to match the current `camera` selection. Early-outs on the
    /// raw requested value BEFORE any device enumeration, so the common "unchanged" path is free to call
    /// every frame (no per-frame `DiscoverySession`). `camera` is a device `uniqueID` or "default"; an
    /// unknown id (e.g. a selection saved on another machine) falls back to the default device.
    /// KNOWN HITCH: a real device switch reconfigures the AVCaptureSession synchronously here, on the
    /// render thread — a few dropped viewport frames. Deliberate (switches are rare user actions);
    /// the contract-clean form defers the session work to `sampleQueue` and flips when ready.
    private func applySelection(camera: String) {
        guard running, camera != requestedCamera else { return }
        requestedCamera = camera
        guard let device = resolveDevice(camera), device.uniqueID != activeDeviceID,
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        for existing in session.inputs { session.removeInput(existing) }
        if session.canAddInput(input) {
            session.addInput(input)
            activeDeviceID = device.uniqueID
        }
        session.commitConfiguration()
    }

    /// Resolve a `camera` selection value to a device: a matching `uniqueID`, else the default device
    /// (covers "default" and any id not present on this machine).
    private func resolveDevice(_ value: String) -> AVCaptureDevice? {
        if value != "default", let match = Self.discovery().devices.first(where: { $0.uniqueID == value }) {
            return match
        }
        return Self.selectCamera()
    }

    private static func discovery() -> AVCaptureDevice.DiscoverySession {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        if #available(macOS 14.0, *) { types.append(.continuityCamera) }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
    }

    private static func selectCamera() -> AVCaptureDevice? {
        discovery().devices.first ?? AVCaptureDevice.default(for: .video)
    }

    private static func texture(from pixelBuffer: CVPixelBuffer,
                                cache: CVMetalTextureCache) -> (texture: any MTLTexture, hold: CVMetalTexture)? {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        // Caller pins `hold` (and the pixel buffer) via ctx.holdUntilFrameCompletes — see update().
        return (texture, cvTexture)
    }
}

/// Captures the latest camera pixel buffer off the AVFoundation sample queue; the render thread reads it.
final class CameraSampleDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    func latest() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); buffer = pixelBuffer; lock.unlock()
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
