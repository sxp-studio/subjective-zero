// Video File — plays a local video file as a live texture source. Adapts the camera.macos pipeline:
// an AVPlayer feeds an AVPlayerItemVideoOutput; each frame we poll the newest CVPixelBuffer, wrap it as
// an MTLTexture via a CVMetalTextureCache, and sample it into the output with a `fit` mode. The player
// is (re)built only when `path` changes; `rate`/`loop` are read live.
//
// The app is NOT sandboxed (no app-sandbox entitlement), so an absolute path from the `filePicker`
// input is read directly. Safe headless: outputs black until the first decoded frame arrives.
@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
import QuartzCore
@preconcurrency import Metal

final class Node: SZNode {
    private var pipeline: (any MTLRenderPipelineState)?
    private var textureCache: CVMetalTextureCache?
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var endObserver: (any NSObjectProtocol)?
    private var loadedPath: String?
    private var lastPixelBuffer: CVPixelBuffer?
    private var desiredRate: Float = 1
    private var loopEnabled = true

    func setup(_ ctx: SZSetupContext) {
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, ctx.device, nil, &textureCache)
        buildPipeline(ctx.device)
    }

    func update(_ ctx: SZFrameContext) {
        guard let out = ctx.outputTexture("output") else { return }

        loopEnabled = (ctx.inputFloat("loop") ?? 1) > 0.5
        reloadIfNeeded(path: ctx.inputString("path") ?? "")
        applyRate(ctx.inputFloat("rate") ?? 1)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }

        // Pull the newest decoded frame; fall back to the last one so playback holds between decodes.
        if let output = videoOutput {
            let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                lastPixelBuffer = pb
            }
        }
        guard let pipeline, let cache = textureCache, let pixelBuffer = lastPixelBuffer,
              let (frame, hold) = Self.texture(from: pixelBuffer, cache: cache) else { return }  // black until first frame
        // Pin this frame's buffer + Metal binding until the GPU finishes (the pool recycles otherwise).
        ctx.holdUntilFrameCompletes(pixelBuffer)
        ctx.holdUntilFrameCompletes(hold)

        var uvScale = fitScale(mode: ctx.inputString("fit") ?? "fill",
                               imageAspect: Float(frame.width) / Float(max(1, frame.height)),
                               outputAspect: Float(out.width) / Float(max(1, out.height)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(frame, index: 0)
        encoder.setFragmentBytes(&uvScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    func teardown() {
        player?.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player = nil
        videoOutput = nil
        lastPixelBuffer = nil
        textureCache = nil
    }

    /// (Re)build the AVPlayer when `path` changes. Empty/invalid path ⇒ no player ⇒ black output.
    private func reloadIfNeeded(path: String) {
        guard path != loadedPath else { return }
        loadedPath = path
        player?.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player = nil
        videoOutput = nil
        lastPixelBuffer = nil
        guard !path.isEmpty else { return }

        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)
        videoOutput = output

        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.actionAtItemEnd = .none   // we handle looping so a non-loop stop just holds the last frame
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self, self.loopEnabled else { return }
            self.player?.seek(to: .zero)
            self.player?.rate = self.desiredRate
        }
        player = newPlayer
        newPlayer.play()
        newPlayer.rate = desiredRate
    }

    /// Apply a live `rate` change (0 pauses). Tracked so looping restarts at the current rate.
    private func applyRate(_ rate: Float) {
        guard rate != desiredRate else { return }
        desiredRate = rate
        player?.rate = rate
    }

    /// The per-axis uv scale mapping output uv → frame uv for the fit mode (see image-file for the derivation).
    private func fitScale(mode: String, imageAspect: Float, outputAspect: Float) -> SIMD2<Float> {
        switch mode {
        case "stretch":
            return SIMD2<Float>(1, 1)
        case "fit":    // contain — whole frame visible, letterboxed
            return imageAspect > outputAspect
                ? SIMD2<Float>(1, imageAspect / outputAspect)
                : SIMD2<Float>(outputAspect / imageAspect, 1)
        default:       // "fill" — cover, overflow cropped (the natural video look)
            return imageAspect > outputAspect
                ? SIMD2<Float>(outputAspect / imageAspect, 1)
                : SIMD2<Float>(1, imageAspect / outputAspect)
        }
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
            o.uv = float2(o.pos.x * 0.5 + 0.5, 0.5 - o.pos.y * 0.5);
            return o;
        }
        fragment float4 f_main(VOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               constant float2 &uvScale [[buffer(0)]]) {
            constexpr sampler smp(filter::linear, address::clamp_to_zero);
            float2 uv = (in.uv - 0.5) * uvScale + 0.5;
            return tex.sample(smp, uv);
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil) else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "v_main")
        descriptor.fragmentFunction = library.makeFunction(name: "f_main")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func texture(from pixelBuffer: CVPixelBuffer,
                                cache: CVMetalTextureCache) -> (texture: any MTLTexture, hold: CVMetalTexture)? {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (texture, cvTexture)
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
