// Image File — loads a still image from a local path (via MTKTextureLoader) and draws it into the
// output texture, scaled to the viewport with a `fit` mode (letterbox / crop / stretch). The image is
// loaded once and cached; it only reloads when `path` changes. Render-pass template: a full-screen
// triangle samples the loaded texture through a uv transform computed CPU-side from the two aspect ratios.
//
// The app is NOT sandboxed (no app-sandbox entitlement), so an absolute path from the `filePicker`
// input is read directly — no security-scoped bookmark needed.
@preconcurrency import Metal
import MetalKit

final class Node: SZNode {
    private var pipeline: MTLRenderPipelineState?
    private var loaded: (any MTLTexture)?
    private var loadedPath: String?

    func setup(_ ctx: SZSetupContext) {
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
                               constant float2 &uvScale [[buffer(0)]],
                               constant int    &rot     [[buffer(1)]]) {
            constexpr sampler smp(filter::linear, address::clamp_to_zero);
            float2 c = (in.uv - 0.5) * uvScale;   // fit-scaled, centred (rotated-image space)
            float2 s = c;                          // rot == 0
            if      (rot == 1) s = float2( c.y, -c.x);   // 90° CW
            else if (rot == 2) s = float2(-c.x, -c.y);   // 180°
            else if (rot == 3) s = float2(-c.y,  c.x);   // 270° CW
            return tex.sample(smp, s + 0.5);
        }
        """
        guard let library = try? ctx.device.makeLibrary(source: source, options: nil) else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "v_main")
        descriptor.fragmentFunction = library.makeFunction(name: "f_main")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? ctx.device.makeRenderPipelineState(descriptor: descriptor)
    }

    func update(_ ctx: SZFrameContext) {
        guard let out = ctx.outputTexture("output"), let pipeline else { return }

        // (Re)load the image only when the path changes. Empty path ⇒ no image ⇒ clear to black.
        let path = ctx.inputString("path") ?? ""
        if path != loadedPath {
            loadedPath = path
            loaded = nil
            if !path.isEmpty {
                let loader = MTKTextureLoader(device: ctx.device)
                let options: [MTKTextureLoader.Option: Any] = [
                    .origin: MTKTextureLoader.Origin.topLeft,
                    .SRGB: false,
                    .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                ]
                loaded = try? loader.newTexture(URL: URL(fileURLWithPath: path), options: options)
            }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = out
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }
        guard let image = loaded else { return }  // clears to black when no image is loaded

        // A 90°/270° turn swaps the image's effective width/height, so the aspect fed to `fitScale`
        // (and thus the letterbox/crop math) must be inverted for those cases.
        var rot = rotationCode(ctx.inputString("rotation") ?? "0")
        let aspect = Float(image.width) / Float(max(1, image.height))
        let rotatedAspect = (rot == 1 || rot == 3) ? 1 / aspect : aspect
        var uvScale = fitScale(mode: ctx.inputString("fit") ?? "fit",
                               imageAspect: rotatedAspect,
                               outputAspect: Float(out.width) / Float(max(1, out.height)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(image, index: 0)
        encoder.setFragmentBytes(&uvScale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentBytes(&rot, length: MemoryLayout<Int32>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Maps the `rotation` enum ("0"/"90"/"180"/"270", clockwise) to a shader code 0–3.
    private func rotationCode(_ value: String) -> Int32 {
        switch value {
        case "90":  return 1
        case "180": return 2
        case "270": return 3
        default:    return 0
        }
    }

    /// The per-axis uv scale that maps output uv → image uv for the chosen fit mode. `>1` on an axis
    /// samples beyond [0,1] (letterbox, filled with the sampler's clamp_to_zero border); `<1` crops.
    private func fitScale(mode: String, imageAspect: Float, outputAspect: Float) -> SIMD2<Float> {
        switch mode {
        case "stretch":
            return SIMD2<Float>(1, 1)
        case "fill":   // cover — image fills the viewport, overflow cropped
            return imageAspect > outputAspect
                ? SIMD2<Float>(outputAspect / imageAspect, 1)
                : SIMD2<Float>(1, imageAspect / outputAspect)
        default:       // "fit" — contain, whole image visible, letterboxed
            return imageAspect > outputAspect
                ? SIMD2<Float>(1, imageAspect / outputAspect)
                : SIMD2<Float>(outputAspect / imageAspect, 1)
        }
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
