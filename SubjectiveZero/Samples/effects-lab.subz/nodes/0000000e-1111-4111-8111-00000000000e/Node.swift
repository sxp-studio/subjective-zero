// Gaussian Blur — a separable 9-tap Gaussian applied to the input texture in two render passes.
// SAMPLED render template: a full-screen triangle samples the source with a linear sampler. Pass 1 blurs
// horizontally (input → lazy intermediate), pass 2 blurs vertically (intermediate → output). `radius`
// scales the tap spacing and rides the value channel (live-tunable). Weights are a symmetric bell.
@preconcurrency import Metal

final class Node: SZNode {
    private var pipeline: MTLRenderPipelineState?
    private var temp: (any MTLTexture)?

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
                               texture2d<float> tex        [[texture(0)]],
                               constant float2 &direction  [[buffer(0)]],
                               constant float2 &texelSize  [[buffer(1)]],
                               constant float  &radius     [[buffer(2)]]) {
            constexpr sampler smp(filter::linear, address::clamp_to_edge);
            float weights[9] = { 0.01, 0.02, 0.06, 0.12, 0.18, 0.12, 0.06, 0.02, 0.01 };
            float sum = 0.0;
            for (int i = 0; i < 9; i++) { sum += weights[i]; }
            float4 acc = float4(0.0);
            for (int i = -4; i <= 4; i++) {
                float2 off = direction * texelSize * radius * float(i);
                acc += tex.sample(smp, in.uv + off) * (weights[i + 4] / sum);
            }
            return acc;
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
        guard let input = ctx.inputTexture("input"),
              let out = ctx.outputTexture("output") else { return }
        let radius = ctx.inputFloat("radius") ?? 3.0

        if temp == nil || temp?.width != out.width || temp?.height != out.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: out.width, height: out.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .shared
            temp = ctx.device.makeTexture(descriptor: d)
        }
        guard let temp else { return }

        let texel = SIMD2<Float>(1.0 / Float(out.width), 1.0 / Float(out.height))
        encodePass(ctx, source: input, target: temp, direction: SIMD2<Float>(1, 0), radius: radius, texel: texel)
        encodePass(ctx, source: temp, target: out, direction: SIMD2<Float>(0, 1), radius: radius, texel: texel)
    }

    private func encodePass(_ ctx: SZFrameContext,
                            source: any MTLTexture,
                            target: any MTLTexture,
                            direction: SIMD2<Float>,
                            radius: Float,
                            texel: SIMD2<Float>) {
        guard let pipeline else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = ctx.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        var dir = direction
        var tx = texel
        var r = radius
        encoder.setFragmentBytes(&dir, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentBytes(&tx, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setFragmentBytes(&r, length: MemoryLayout<Float>.size, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

enum SZNodeMain { static func make() -> SZNode { Node() } }
